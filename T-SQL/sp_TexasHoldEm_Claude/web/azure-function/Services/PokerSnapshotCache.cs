using System.Runtime.ExceptionServices;
using Microsoft.Extensions.Configuration;
using Microsoft.Extensions.Logging;
using PokerApi.Models;

namespace PokerApi.Services;

public sealed class PokerSnapshotCache
{
    private readonly IPokerSnapshotSource _source;
    private readonly TimeProvider _timeProvider;
    private readonly ILogger<PokerSnapshotCache> _logger;
    private readonly TimeSpan _ttl;
    private readonly SemaphoreSlim _refreshLock = new(1, 1);

    private CacheEntry? _entry;
    private FailureEntry? _failure;

    public PokerSnapshotCache(
        IPokerSnapshotSource source,
        IConfiguration configuration,
        TimeProvider timeProvider,
        ILogger<PokerSnapshotCache> logger)
    {
        _source = source;
        _timeProvider = timeProvider;
        _logger = logger;

        var cacheSeconds = configuration.GetValue("PokerCacheSeconds", 10);
        if (cacheSeconds is < 1 or > 300)
        {
            throw new InvalidOperationException("PokerCacheSeconds must be between 1 and 300.");
        }

        CacheSeconds = cacheSeconds;
        _ttl = TimeSpan.FromSeconds(cacheSeconds);
    }

    public int CacheSeconds { get; }

    public async Task<PokerSnapshot> GetAsync(CancellationToken cancellationToken)
    {
        var entry = Volatile.Read(ref _entry);
        if (entry is not null && _timeProvider.GetUtcNow() < entry.ExpiresAt)
        {
            return entry.Snapshot;
        }

        // Before the negative cache, not after: an already-cancelled request used to come out of
        // WaitAsync as an OperationCanceledException, and it still should. Handing it the stored
        // SQL failure instead would log an abandoned request as a database outage.
        cancellationToken.ThrowIfCancellationRequested();
        ThrowIfColdFailureIsCached();

        await _refreshLock.WaitAsync(cancellationToken);
        try
        {
            var now = _timeProvider.GetUtcNow();
            entry = Volatile.Read(ref _entry);
            if (entry is not null && now < entry.ExpiresAt)
            {
                return entry.Snapshot;
            }

            // Checked again inside the lock: the holder ahead of us may have just recorded the
            // failure, which is exactly the pile-up this guards against.
            ThrowIfColdFailureIsCached();

            try
            {
                // A disconnected HTTP client must not cancel a refresh shared by the whole Function instance.
                // SqlPokerSnapshotSource still bounds this work with PokerCommandTimeoutSeconds.
                var refreshed = await _source.LoadAsync(CancellationToken.None);
                var refreshedEntry = new CacheEntry(
                    refreshed with { Stale = false },
                    _timeProvider.GetUtcNow().Add(_ttl));
                Volatile.Write(ref _entry, refreshedEntry);
                Volatile.Write(ref _failure, null);
                return refreshedEntry.Snapshot;
            }
            catch (OperationCanceledException)
            {
                throw;
            }
            catch (Exception exception)
            {
                if (entry is null)
                {
                    // Nothing cached and nothing to fall back on. Remember the failure for one TTL
                    // so the requests queued on _refreshLock behind this one fail immediately
                    // instead of each paying its own PokerCommandTimeoutSeconds against a database
                    // we already know isn't answering.
                    _logger.LogError(
                        exception,
                        "Poker snapshot refresh failed with no snapshot to fall back on; failing fast for {CacheSeconds}s.",
                        CacheSeconds);
                    Volatile.Write(
                        ref _failure,
                        new FailureEntry(
                            ExceptionDispatchInfo.Capture(exception),
                            _timeProvider.GetUtcNow().Add(_ttl)));
                    throw;
                }

                _logger.LogWarning(exception, "Poker snapshot refresh failed; serving the last successful snapshot.");
                var staleEntry = new CacheEntry(
                    entry.Snapshot with { Stale = true },
                    _timeProvider.GetUtcNow().Add(_ttl));
                Volatile.Write(ref _entry, staleEntry);
                return staleEntry.Snapshot;
            }
        }
        finally
        {
            _refreshLock.Release();
        }
    }

    // Rethrows the cached cold-start failure, preserving the original stack trace, until the
    // negative-cache window expires. One SQL attempt per window, however many callers arrive.
    private void ThrowIfColdFailureIsCached()
    {
        var failure = Volatile.Read(ref _failure);
        if (failure is not null && _timeProvider.GetUtcNow() < failure.ExpiresAt)
        {
            failure.Exception.Throw();
        }
    }

    private sealed record CacheEntry(PokerSnapshot Snapshot, DateTimeOffset ExpiresAt);

    private sealed record FailureEntry(ExceptionDispatchInfo Exception, DateTimeOffset ExpiresAt);
}
