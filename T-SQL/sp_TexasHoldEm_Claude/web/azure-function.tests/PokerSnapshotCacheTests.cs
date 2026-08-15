using Microsoft.Extensions.Configuration;
using Microsoft.Extensions.Logging.Abstractions;
using PokerApi.Models;
using PokerApi.Services;

namespace PokerApi.Tests;

public sealed class PokerSnapshotCacheTests
{
    [Fact]
    public async Task GetAsync_CollapsesConcurrentRefreshesAndHonorsTheTtl()
    {
        var time = new ManualTimeProvider(new DateTimeOffset(2026, 8, 14, 12, 0, 0, TimeSpan.Zero));
        var source = new FakeSource(time, TimeSpan.FromMilliseconds(25));
        var cache = CreateCache(source, time, 10);

        var results = await Task.WhenAll(Enumerable.Range(0, 20)
            .Select(_ => cache.GetAsync(CancellationToken.None)));

        Assert.Equal(1, source.CallCount);
        Assert.All(results, result => Assert.Equal(results[0].GeneratedAt, result.GeneratedAt));

        time.Advance(TimeSpan.FromSeconds(9));
        await cache.GetAsync(CancellationToken.None);
        Assert.Equal(1, source.CallCount);

        time.Advance(TimeSpan.FromSeconds(1));
        await cache.GetAsync(CancellationToken.None);
        Assert.Equal(2, source.CallCount);
    }

    [Fact]
    public async Task GetAsync_ReturnsTheLastSnapshotAsStaleAfterARefreshFailure()
    {
        var time = new ManualTimeProvider(DateTimeOffset.UtcNow);
        var source = new FakeSource(time, TimeSpan.Zero);
        var cache = CreateCache(source, time, 10);

        var original = await cache.GetAsync(CancellationToken.None);
        time.Advance(TimeSpan.FromSeconds(10));
        source.Fail = true;

        var fallback = await cache.GetAsync(CancellationToken.None);

        Assert.True(fallback.Stale);
        Assert.Equal(original.GeneratedAt, fallback.GeneratedAt);
        Assert.Equal(2, source.CallCount);

        var repeatedFallback = await cache.GetAsync(CancellationToken.None);
        Assert.True(repeatedFallback.Stale);
        Assert.Equal(2, source.CallCount);
    }

    [Fact]
    public async Task GetAsync_PropagatesTheFirstRefreshFailure()
    {
        var time = new ManualTimeProvider(DateTimeOffset.UtcNow);
        var source = new FakeSource(time, TimeSpan.Zero) { Fail = true };
        var cache = CreateCache(source, time, 10);

        await Assert.ThrowsAsync<InvalidOperationException>(() =>
            cache.GetAsync(CancellationToken.None));
    }

    [Fact]
    public async Task GetAsync_CachesAColdFailureSoQueuedRequestsDoNotEachRetrySql()
    {
        var time = new ManualTimeProvider(DateTimeOffset.UtcNow);
        var source = new FakeSource(time, TimeSpan.FromMilliseconds(25)) { Fail = true };
        var cache = CreateCache(source, time, 10);

        var failures = await Task.WhenAll(Enumerable.Range(0, 20)
            .Select(_ => Record.ExceptionAsync(() => cache.GetAsync(CancellationToken.None))));

        Assert.All(failures, failure => Assert.IsType<InvalidOperationException>(failure));

        // The whole point: 20 callers, one SQL attempt. Without the negative cache each caller
        // takes _refreshLock in turn and pays a full command timeout of its own.
        Assert.Equal(1, source.CallCount);
    }

    [Fact]
    public async Task GetAsync_RetriesOnceTheCachedColdFailureExpires()
    {
        var time = new ManualTimeProvider(DateTimeOffset.UtcNow);
        var source = new FakeSource(time, TimeSpan.Zero) { Fail = true };
        var cache = CreateCache(source, time, 10);

        await Assert.ThrowsAsync<InvalidOperationException>(() => cache.GetAsync(CancellationToken.None));
        Assert.Equal(1, source.CallCount);

        time.Advance(TimeSpan.FromSeconds(9));
        await Assert.ThrowsAsync<InvalidOperationException>(() => cache.GetAsync(CancellationToken.None));
        Assert.Equal(1, source.CallCount);

        time.Advance(TimeSpan.FromSeconds(1));
        source.Fail = false;
        var recovered = await cache.GetAsync(CancellationToken.None);

        Assert.False(recovered.Stale);
        Assert.Equal(2, source.CallCount);
    }

    [Fact]
    public async Task GetAsync_HonorsCancellationRatherThanReplayingTheCachedFailure()
    {
        var time = new ManualTimeProvider(DateTimeOffset.UtcNow);
        var source = new FakeSource(time, TimeSpan.Zero) { Fail = true };
        var cache = CreateCache(source, time, 10);

        await Assert.ThrowsAsync<InvalidOperationException>(() => cache.GetAsync(CancellationToken.None));

        using var cancelled = new CancellationTokenSource();
        await cancelled.CancelAsync();

        // An abandoned request is not a database outage, and must not be logged as one.
        await Assert.ThrowsAnyAsync<OperationCanceledException>(() => cache.GetAsync(cancelled.Token));
        Assert.Equal(1, source.CallCount);
    }

    [Fact]
    public async Task GetAsync_ForgetsTheColdFailureAfterASuccessfulRefresh()
    {
        var time = new ManualTimeProvider(DateTimeOffset.UtcNow);
        var source = new FakeSource(time, TimeSpan.Zero) { Fail = true };
        var cache = CreateCache(source, time, 10);

        await Assert.ThrowsAsync<InvalidOperationException>(() => cache.GetAsync(CancellationToken.None));

        time.Advance(TimeSpan.FromSeconds(10));
        source.Fail = false;
        await cache.GetAsync(CancellationToken.None);

        // A later failure must now fall back to the stale snapshot, not to the stored exception.
        time.Advance(TimeSpan.FromSeconds(10));
        source.Fail = true;
        var fallback = await cache.GetAsync(CancellationToken.None);

        Assert.True(fallback.Stale);
    }

    [Fact]
    public async Task GetAsync_DoesNotPassARequestCancellationTokenToTheSharedRefresh()
    {
        var time = new ManualTimeProvider(DateTimeOffset.UtcNow);
        var source = new FakeSource(time, TimeSpan.Zero);
        var cache = CreateCache(source, time, 17);
        using var requestCancellation = new CancellationTokenSource();

        await cache.GetAsync(requestCancellation.Token);

        Assert.False(source.LastCancellationToken.CanBeCanceled);
        Assert.Equal(17, cache.CacheSeconds);
    }

    private static PokerSnapshotCache CreateCache(
        IPokerSnapshotSource source,
        TimeProvider timeProvider,
        int cacheSeconds)
    {
        var configuration = new ConfigurationBuilder()
            .AddInMemoryCollection(new Dictionary<string, string?>
            {
                ["PokerCacheSeconds"] = cacheSeconds.ToString()
            })
            .Build();

        return new PokerSnapshotCache(
            source,
            configuration,
            timeProvider,
            NullLogger<PokerSnapshotCache>.Instance);
    }

    private sealed class FakeSource : IPokerSnapshotSource
    {
        private readonly TimeProvider _timeProvider;
        private readonly TimeSpan _delay;
        private int _callCount;

        public FakeSource(TimeProvider timeProvider, TimeSpan delay)
        {
            _timeProvider = timeProvider;
            _delay = delay;
        }

        public int CallCount => Volatile.Read(ref _callCount);
        public bool Fail { get; set; }
        public CancellationToken LastCancellationToken { get; private set; }

        public async Task<PokerSnapshot> LoadAsync(CancellationToken cancellationToken)
        {
            Interlocked.Increment(ref _callCount);
            LastCancellationToken = cancellationToken;
            await Task.Delay(_delay, cancellationToken);
            if (Fail)
            {
                throw new InvalidOperationException("Simulated SQL failure.");
            }

            return new PokerSnapshot(
                _timeProvider.GetUtcNow(),
                false,
                new HandSnapshot(null, "Waiting", "", 0, "(observer)", null),
                Array.Empty<SeatSnapshot>(),
                Array.Empty<string>(),
                Array.Empty<string>());
        }
    }

    private sealed class ManualTimeProvider : TimeProvider
    {
        private DateTimeOffset _utcNow;

        public ManualTimeProvider(DateTimeOffset utcNow)
        {
            _utcNow = utcNow;
        }

        public override DateTimeOffset GetUtcNow() => _utcNow;

        public void Advance(TimeSpan amount)
        {
            _utcNow = _utcNow.Add(amount);
        }
    }
}
