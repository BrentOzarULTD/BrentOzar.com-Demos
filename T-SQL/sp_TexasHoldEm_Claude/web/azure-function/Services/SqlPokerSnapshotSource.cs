using System.Data;
using Microsoft.Data.SqlClient;
using Microsoft.Extensions.Configuration;
using PokerApi.Models;

namespace PokerApi.Services;

public sealed class SqlPokerSnapshotSource : IPokerSnapshotSource
{
    private readonly string _connectionString;
    private readonly int _commandTimeoutSeconds;
    private readonly TimeProvider _timeProvider;

    public SqlPokerSnapshotSource(IConfiguration configuration, TimeProvider timeProvider)
    {
        var configuredConnectionString = configuration["PokerSqlConnectionString"]
            ?? throw new InvalidOperationException("PokerSqlConnectionString is not configured.");
        var connectionStringBuilder = new SqlConnectionStringBuilder(configuredConnectionString);
        if (string.IsNullOrWhiteSpace(connectionStringBuilder.ApplicationName))
        {
            connectionStringBuilder.ApplicationName = "TexasHoldEmPokerApi";
        }

        _connectionString = connectionStringBuilder.ConnectionString;
        _timeProvider = timeProvider;

        _commandTimeoutSeconds = configuration.GetValue("PokerCommandTimeoutSeconds", 20);
        if (_commandTimeoutSeconds is < 1 or > 120)
        {
            throw new InvalidOperationException("PokerCommandTimeoutSeconds must be between 1 and 120.");
        }
    }

    public async Task<PokerSnapshot> LoadAsync(CancellationToken cancellationToken)
    {
        await using var connection = new SqlConnection(_connectionString);
        await connection.OpenAsync(cancellationToken);

        await using var command = connection.CreateCommand();
        command.CommandType = CommandType.Text;
        command.CommandTimeout = _commandTimeoutSeconds;
        command.CommandText = """
            EXEC dbo.sp_TexasHoldEm_Public
                @Action = @Action,
                @ShowWhatHappened = @ShowWhatHappened,
                @WaitForTurn = @WaitForTurn;
            """;
        command.Parameters.Add("@Action", SqlDbType.NVarChar, 20).Value = "Status";
        command.Parameters.Add("@ShowWhatHappened", SqlDbType.NVarChar, 20).Value = "ThisGame";
        command.Parameters.Add("@WaitForTurn", SqlDbType.Bit).Value = false;

        await using var reader = await command.ExecuteReaderAsync(CommandBehavior.SequentialAccess, cancellationToken);
        return await PokerResultSetParser.ParseAsync(reader, _timeProvider.GetUtcNow(), cancellationToken);
    }
}
