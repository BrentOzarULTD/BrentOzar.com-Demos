using System.Data.Common;
using PokerApi.Models;

namespace PokerApi.Services;

public static class PokerResultSetParser
{
    public static async Task<PokerSnapshot> ParseAsync(
        DbDataReader reader,
        DateTimeOffset generatedAt,
        CancellationToken cancellationToken)
    {
        var hand = await ReadHandAsync(reader, cancellationToken);

        await RequireNextResultAsync(reader, "Seat", cancellationToken);
        var seats = await ReadSeatsAsync(reader, cancellationToken);

        await RequireNextResultAsync(reader, "What Now", cancellationToken);
        var whatNow = await ReadStringListAsync(reader, "What Now", cancellationToken);

        await RequireNextResultAsync(reader, "What Happened", cancellationToken);
        var history = await ReadStringListAsync(reader, "What Happened", cancellationToken);

        if (await reader.NextResultAsync(cancellationToken))
        {
            throw new InvalidOperationException("The poker procedure returned more than four result sets.");
        }

        return new PokerSnapshot(generatedAt, false, hand, seats, whatNow, history);
    }

    private static async Task<HandSnapshot> ReadHandAsync(
        DbDataReader reader,
        CancellationToken cancellationToken)
    {
        RequireColumns(reader, "Hand #", "Stage", "Board", "Pot", "Your Cards", "Your Chips");
        if (!await reader.ReadAsync(cancellationToken))
        {
            throw new InvalidOperationException("The Hand result set was empty.");
        }

        var hand = new HandSnapshot(
            GetNullableInt32(reader, "Hand #"),
            GetString(reader, "Stage"),
            GetString(reader, "Board"),
            GetInt32(reader, "Pot"),
            GetString(reader, "Your Cards"),
            GetNullableInt32(reader, "Your Chips"));

        if (await reader.ReadAsync(cancellationToken))
        {
            throw new InvalidOperationException("The Hand result set returned more than one row.");
        }

        return hand;
    }

    private static async Task<IReadOnlyList<SeatSnapshot>> ReadSeatsAsync(
        DbDataReader reader,
        CancellationToken cancellationToken)
    {
        RequireColumns(reader, "Seat", "Player", "Position", "Chips", "This Round", "Cards", "Status");
        var seats = new List<SeatSnapshot>();

        while (await reader.ReadAsync(cancellationToken))
        {
            seats.Add(new SeatSnapshot(
                GetInt32(reader, "Seat"),
                GetString(reader, "Player"),
                GetString(reader, "Position"),
                GetInt32(reader, "Chips"),
                GetInt32(reader, "This Round"),
                GetString(reader, "Cards"),
                GetString(reader, "Status")));
        }

        return seats;
    }

    private static async Task<IReadOnlyList<string>> ReadStringListAsync(
        DbDataReader reader,
        string columnName,
        CancellationToken cancellationToken)
    {
        RequireColumns(reader, columnName);
        var lines = new List<string>();
        while (await reader.ReadAsync(cancellationToken))
        {
            lines.Add(GetString(reader, columnName));
        }

        return lines;
    }

    private static async Task RequireNextResultAsync(
        DbDataReader reader,
        string expectedName,
        CancellationToken cancellationToken)
    {
        if (!await reader.NextResultAsync(cancellationToken))
        {
            throw new InvalidOperationException($"The poker procedure did not return its {expectedName} result set.");
        }
    }

    private static void RequireColumns(DbDataReader reader, params string[] names)
    {
        var actual = Enumerable.Range(0, reader.FieldCount)
            .Select(reader.GetName)
            .ToHashSet(StringComparer.OrdinalIgnoreCase);

        var missing = names.Where(name => !actual.Contains(name)).ToArray();
        if (missing.Length > 0)
        {
            throw new InvalidOperationException(
                $"The poker procedure result shape changed. Missing column(s): {string.Join(", ", missing)}.");
        }
    }

    private static string GetString(DbDataReader reader, string name)
    {
        var ordinal = reader.GetOrdinal(name);
        return reader.IsDBNull(ordinal) ? string.Empty : Convert.ToString(reader.GetValue(ordinal)) ?? string.Empty;
    }

    private static int GetInt32(DbDataReader reader, string name)
    {
        var ordinal = reader.GetOrdinal(name);
        if (reader.IsDBNull(ordinal))
        {
            throw new InvalidOperationException($"The required {name} value was null.");
        }

        return Convert.ToInt32(reader.GetValue(ordinal));
    }

    private static int? GetNullableInt32(DbDataReader reader, string name)
    {
        var ordinal = reader.GetOrdinal(name);
        return reader.IsDBNull(ordinal) ? null : Convert.ToInt32(reader.GetValue(ordinal));
    }
}
