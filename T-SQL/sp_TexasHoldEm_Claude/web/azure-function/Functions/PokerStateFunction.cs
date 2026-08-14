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
                && values.Any(value => string.Equals(value, etag, StringComparison.Ordinal)))
            {
                var notModified = request.CreateResponse(HttpStatusCode.NotModified);
                AddCacheHeaders(notModified, etag);
                return notModified;
            }

            var response = request.CreateResponse(HttpStatusCode.OK);
            AddCacheHeaders(response, etag);
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

    private static void AddCacheHeaders(HttpResponseData response, string etag)
    {
        response.Headers.Add("Cache-Control", "public, max-age=10, stale-while-revalidate=30");
        response.Headers.Add("ETag", etag);
    }
}
