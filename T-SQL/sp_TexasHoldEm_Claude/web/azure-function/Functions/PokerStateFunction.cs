using System.Net;
using Microsoft.Azure.Functions.Worker;
using Microsoft.Azure.Functions.Worker.Http;
using Microsoft.Extensions.Logging;
using PokerApi.Models;
using PokerApi.Services;

namespace PokerApi.Functions;

public sealed class PokerStateFunction
{
    private readonly PokerSnapshotCache _cache;
    private readonly ILogger<PokerStateFunction> _logger;

    public PokerStateFunction(PokerSnapshotCache cache, ILogger<PokerStateFunction> logger)
    {
        _cache = cache;
        _logger = logger;
    }

    [Function("PokerState")]
    public async Task<HttpResponseData> RunAsync(
        [HttpTrigger(AuthorizationLevel.Anonymous, "get", Route = "poker/state")] HttpRequestData request,
        CancellationToken cancellationToken)
    {
        try
        {
            var snapshot = await _cache.GetAsync(cancellationToken);
            var etag = $"\"{snapshot.GeneratedAt.ToUnixTimeMilliseconds()}-{(snapshot.Stale ? 1 : 0)}\"";

            if (request.Headers.TryGetValues("If-None-Match", out var values)
                && MatchesIfNoneMatch(values, etag))
            {
                var notModified = request.CreateResponse(HttpStatusCode.NotModified);
                AddCacheHeaders(notModified, etag, _cache.CacheSeconds);
                return notModified;
            }

            var response = request.CreateResponse(HttpStatusCode.OK);
            AddCacheHeaders(response, etag, _cache.CacheSeconds);
            await response.WriteAsJsonAsync(snapshot, cancellationToken);
            return response;
        }
        catch (OperationCanceledException) when (cancellationToken.IsCancellationRequested)
        {
            throw;
        }
        catch (Exception exception)
        {
            _logger.LogError(exception, "No poker snapshot is available.");
            var response = request.CreateResponse(HttpStatusCode.ServiceUnavailable);
            response.Headers.Add("Cache-Control", "no-store");
            await response.WriteAsJsonAsync(
                new ApiError("The poker table is temporarily unavailable."),
                cancellationToken);
            return response;
        }
    }

    internal static bool MatchesIfNoneMatch(IEnumerable<string> headerValues, string currentEtag)
    {
        foreach (var headerValue in headerValues)
        {
            foreach (var rawCandidate in headerValue.Split(','))
            {
                var candidate = rawCandidate.Trim();
                if (candidate == "*")
                {
                    return true;
                }

                if (candidate.StartsWith("W/", StringComparison.OrdinalIgnoreCase))
                {
                    candidate = candidate[2..].TrimStart();
                }

                if (string.Equals(candidate, currentEtag, StringComparison.Ordinal))
                {
                    return true;
                }
            }
        }

        return false;
    }

    private static void AddCacheHeaders(HttpResponseData response, string etag, int cacheSeconds)
    {
        response.Headers.Add(
            "Cache-Control",
            FormattableString.Invariant(
                $"public, max-age={cacheSeconds}, stale-while-revalidate={cacheSeconds * 3}"));
        response.Headers.Add("Access-Control-Expose-Headers", "ETag");
        response.Headers.Add("ETag", etag);
    }
}
