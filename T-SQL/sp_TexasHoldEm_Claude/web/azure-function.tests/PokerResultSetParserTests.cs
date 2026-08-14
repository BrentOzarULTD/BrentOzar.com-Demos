using System.Data;
using PokerApi.Services;

namespace PokerApi.Tests;

public sealed class PokerResultSetParserTests
{
    [Fact]
    public async Task ParseAsync_MapsTheFourDocumentedResultSets()
    {
        var generatedAt = new DateTimeOffset(2026, 8, 14, 12, 0, 0, TimeSpan.Zero);
        using var reader = BuildValidDataSet().CreateDataReader();

        var result = await PokerResultSetParser.ParseAsync(reader, generatedAt, CancellationToken.None);

        Assert.Equal(generatedAt, result.GeneratedAt);
        Assert.False(result.Stale);
        Assert.Equal(7, result.Hand.HandNumber);
        Assert.Equal("Flop betting", result.Hand.Stage);
        Assert.Equal("A♠ K♥ Q♦", result.Hand.Board);
        Assert.Equal(180, result.Hand.Pot);
        Assert.Single(result.Seats);
        Assert.Equal("HAL [bot]", result.Seats[0].Player);
        Assert.Equal(new[] { "Watch the action." }, result.WhatNow);
        Assert.Equal(new[] { "HAL raises." }, result.History);
    }

    [Fact]
    public async Task ParseAsync_RejectsAChangedResultShape()
    {
        var dataSet = BuildValidDataSet();
        dataSet.Tables[1].Columns.Remove("Status");
        using var reader = dataSet.CreateDataReader();

        var exception = await Assert.ThrowsAsync<InvalidOperationException>(() =>
            PokerResultSetParser.ParseAsync(reader, DateTimeOffset.UtcNow, CancellationToken.None));

        Assert.Contains("Missing column(s): Status", exception.Message);
    }

    private static DataSet BuildValidDataSet()
    {
        var dataSet = new DataSet();

        var hand = dataSet.Tables.Add("Hand");
        hand.Columns.Add("Hand #", typeof(int));
        hand.Columns.Add("Stage", typeof(string));
        hand.Columns.Add("Board", typeof(string));
        hand.Columns.Add("Pot", typeof(int));
        hand.Columns.Add("Your Cards", typeof(string));
        hand.Columns.Add("Your Chips", typeof(int));
        hand.Rows.Add(7, "Flop betting", "A♠ K♥ Q♦", 180, "(observer)", DBNull.Value);

        var seats = dataSet.Tables.Add("Seats");
        seats.Columns.Add("Seat", typeof(byte));
        seats.Columns.Add("Player", typeof(string));
        seats.Columns.Add("Position", typeof(string));
        seats.Columns.Add("Chips", typeof(int));
        seats.Columns.Add("This Round", typeof(int));
        seats.Columns.Add("Cards", typeof(string));
        seats.Columns.Add("Status", typeof(string));
        seats.Rows.Add((byte)1, "HAL [bot]", "Dealer", 940, 40, "[hidden]", "<<< deciding");

        var whatNow = dataSet.Tables.Add("WhatNow");
        whatNow.Columns.Add("What Now", typeof(string));
        whatNow.Rows.Add("Watch the action.");

        var history = dataSet.Tables.Add("History");
        history.Columns.Add("What Happened", typeof(string));
        history.Rows.Add("HAL raises.");

        return dataSet;
    }
}
