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

    private PokerSnapshot? _snapshot;
    private DateTimeOffset _expiresAt;

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
        await _refreshLock.WaitAsync(cancellationToken);
        try
        {
            var now = _timeProvider.GetUtcNow();
            if (_snapshot is not null && now < _expiresAt)
            {
                return _snapshot;
            }

            try
            {
                // A disconnected HTTP client must not cancel a refresh shared by the whole Function instance.
                // SqlPokerSnapshotSource still bounds this work with PokerCommandTimeoutSeconds.
                var refreshed = await _source.LoadAsync(CancellationToken.None);
                _snapshot = refreshed with { Stale = false };
                _expiresAt = _timeProvider.GetUtcNow().Add(_ttl);
                return _snapshot;
            }
            catch (Exception exception) when (_snapshot is not null && exception is not OperationCanceledException)
            {
                _logger.LogWarning(exception, "Poker snapshot refresh failed; serving the last successful snapshot.");
                _snapshot = _snapshot with { Stale = true };
                _expiresAt = _timeProvider.GetUtcNow().Add(_ttl);
                return _snapshot;
            }
        }
        finally
        {
            _refreshLock.Release();
        }
    }
}
