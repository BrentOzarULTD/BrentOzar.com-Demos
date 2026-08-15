using Microsoft.Extensions.Configuration;
using PokerApi.Services;

namespace PokerApi.Tests;

public sealed class SqlPokerSnapshotSourceTests
{
    private const string ConnectionString = "Server=tcp:example.database.windows.net;Database=poker;User ID=x;Password=y;";

    [Fact]
    public void ShowWhatHappened_DefaultsToTheSmallestPayloadTheViewerNeeds()
    {
        var source = Create();

        Assert.Equal("ThisTurn", source.ShowWhatHappened);
    }

    [Theory]
    [InlineData("ThisTurn")]
    [InlineData("ThisGame")]
    [InlineData("AllHistory")]
    [InlineData("thisgame")]
    public void ShowWhatHappened_AcceptsEveryOptionTheProcedureUnderstands(string configured)
    {
        var source = Create(("PokerShowWhatHappened", configured));

        Assert.Equal(configured, source.ShowWhatHappened);
    }

    [Theory]
    [InlineData("ThisGame ")]
    [InlineData("  AllHistory")]
    [InlineData("\tThisTurn\n")]
    public void ShowWhatHappened_TrimsTheConfiguredValue(string configured)
    {
        // An app setting that picked up a stray space is something the procedure accepts without
        // complaint, so the Function shouldn't refuse to start on it. Trimming here is broader
        // than T-SQL's LTRIM/RTRIM - tabs and newlines too - which is safe because SQL only ever
        // receives the normalized option.
        var source = Create(("PokerShowWhatHappened", configured));

        Assert.Equal(configured.Trim(), source.ShowWhatHappened);
    }

    [Theory]
    [InlineData("")]
    [InlineData("   ")]
    [InlineData("\t\n")]
    public void ShowWhatHappened_FallsBackToThisTurnWhenBlank(string configured)
    {
        // Matches sp_TexasHoldEm_Public.sql:607 —
        //   SET @ShowWhatHappened = ISNULL(NULLIF(LTRIM(RTRIM(@ShowWhatHappened)), N''), N'ThisTurn');
        // A blank setting defaults there rather than erroring, so it must default here too.
        var source = Create(("PokerShowWhatHappened", configured));

        Assert.Equal("ThisTurn", source.ShowWhatHappened);
    }

    [Fact]
    public void ShowWhatHappened_RejectsAValueTheProcedureWouldReject()
    {
        // The procedure answers an unknown option with a single "Say What?" result set, which the
        // parser can only report as a shape error. Fail at startup with a usable message instead.
        var exception = Assert.Throws<InvalidOperationException>(
            () => Create(("PokerShowWhatHappened", "Everything")));

        Assert.Contains("ThisTurn, ThisGame, AllHistory", exception.Message);
    }

    [Fact]
    public void Constructor_RequiresAConnectionString()
    {
        var configuration = new ConfigurationBuilder().Build();

        var exception = Assert.Throws<InvalidOperationException>(
            () => new SqlPokerSnapshotSource(configuration, TimeProvider.System));

        Assert.Contains("PokerSqlConnectionString", exception.Message);
    }

    [Theory]
    [InlineData("0")]
    [InlineData("121")]
    public void Constructor_RejectsACommandTimeoutOutsideTheSupportedRange(string configured)
    {
        var exception = Assert.Throws<InvalidOperationException>(
            () => Create(("PokerCommandTimeoutSeconds", configured)));

        Assert.Contains("between 1 and 120", exception.Message);
    }

    private static SqlPokerSnapshotSource Create(params (string Key, string Value)[] settings)
    {
        var values = new Dictionary<string, string?> { ["PokerSqlConnectionString"] = ConnectionString };
        foreach (var (key, value) in settings)
        {
            values[key] = value;
        }

        var configuration = new ConfigurationBuilder()
            .AddInMemoryCollection(values)
            .Build();

        return new SqlPokerSnapshotSource(configuration, TimeProvider.System);
    }
}
