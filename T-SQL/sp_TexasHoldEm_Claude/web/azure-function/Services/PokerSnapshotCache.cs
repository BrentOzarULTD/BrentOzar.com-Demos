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

        await _refreshLock.WaitAsync(cancellationToken);
        try
        {
            var now = _timeProvider.GetUtcNow();
            entry = Volatile.Read(ref _entry);
            if (entry is not null && now < entry.ExpiresAt)
            {
                return entry.Snapshot;
            }

            try
            {
                // A disconnected HTTP client must not cancel a refresh shared by the whole Function instance.
                // SqlPokerSnapshotSource still bounds this work with PokerCommandTimeoutSeconds.
                var refreshed = await _source.LoadAsync(CancellationToken.None);
                var refreshedEntry = new CacheEntry(
                    refreshed with { Stale = false },
                    _timeProvider.GetUtcNow().Add(_ttl));
                Volatile.Write(ref _entry, refreshedEntry);
                return refreshedEntry.Snapshot;
            }
            catch (Exception exception) when (entry is not null && exception is not OperationCanceledException)
            {
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

    private sealed record CacheEntry(PokerSnapshot Snapshot, DateTimeOffset ExpiresAt);
}
