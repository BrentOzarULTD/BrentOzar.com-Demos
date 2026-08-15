using System.Data;
using Microsoft.Data.SqlClient;
using Microsoft.Extensions.Configuration;
using PokerApi.Models;

namespace PokerApi.Services;

public sealed class SqlPokerSnapshotSource : IPokerSnapshotSource
{
    private static readonly string[] ShowWhatHappenedOptions = ["ThisTurn", "ThisGame", "AllHistory"];

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

        // The viewer renders neither WhatNow nor History, so the default asks the procedure for
        // the least it will give us. ThisGame pulls every log row since the game started, which
        // on a long table is hundreds of strings that every polling browser downloads every ten
        // seconds and throws away. Set PokerShowWhatHappened=ThisGame (this game) or AllHistory
        // (everything retained) to put the play-by-play back for a viewer that renders it.
        //
        // Trimmed before validating: SQL Server ignores trailing spaces when comparing strings,
        // so the procedure would happily accept "ThisGame " from an app setting that picked up a
        // stray space. Refusing to start on a value the database would have taken is the wrong
        // kind of strict.
        ShowWhatHappened = (configuration.GetValue("PokerShowWhatHappened", "ThisTurn") ?? "ThisTurn").Trim();
        if (!ShowWhatHappenedOptions.Contains(ShowWhatHappened, StringComparer.OrdinalIgnoreCase))
        {
            throw new InvalidOperationException(
                $"PokerShowWhatHappened must be one of {string.Join(", ", ShowWhatHappenedOptions)}.");
        }
    }

    internal string ShowWhatHappened { get; }

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
        command.Parameters.Add("@ShowWhatHappened", SqlDbType.NVarChar, 20).Value = ShowWhatHappened;
        command.Parameters.Add("@WaitForTurn", SqlDbType.Bit).Value = false;

        // Deliberately NOT SequentialAccess. PokerResultSetParser reads columns by name, and
        // its column check is order-insensitive, so a reordered result set would pass validation
        // and then fail inside the driver with "Invalid attempt to read from column ordinal N".
        // These four result sets are one hand row, at most eight seats, and a short log, so
        // sequential access buys nothing worth that footgun.
        await using var reader = await command.ExecuteReaderAsync(CommandBehavior.Default, cancellationToken);
        return await PokerResultSetParser.ParseAsync(reader, _timeProvider.GetUtcNow(), cancellationToken);
    }
}
