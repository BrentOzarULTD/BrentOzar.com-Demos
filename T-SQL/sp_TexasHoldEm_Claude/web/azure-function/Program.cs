using System.Text.Json;
using Microsoft.Azure.Functions.Worker.Builder;
using Microsoft.Extensions.DependencyInjection;
using Microsoft.Extensions.Hosting;
using PokerApi.Services;

var builder = FunctionsApplication.CreateBuilder(args);

builder.Services.AddSingleton(TimeProvider.System);
builder.Services.AddSingleton<IPokerSnapshotSource, SqlPokerSnapshotSource>();
builder.Services.AddSingleton<PokerSnapshotCache>();
builder.Services.Configure<JsonSerializerOptions>(options =>
{
    options.PropertyNamingPolicy = JsonNamingPolicy.CamelCase;
    options.DictionaryKeyPolicy = JsonNamingPolicy.CamelCase;
});

builder.Build().Run();
