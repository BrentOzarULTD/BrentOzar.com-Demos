using PokerApi.Functions;

namespace PokerApi.Tests;

public sealed class PokerStateFunctionTests
{
    private const string CurrentEtag = "\"1723644000000-0\"";

    [Theory]
    [InlineData("\"1723644000000-0\"")]
    [InlineData("W/\"1723644000000-0\"")]
    [InlineData("\"older\", W/\"1723644000000-0\", \"newer\"")]
    [InlineData("*")]
    public void MatchesIfNoneMatch_AcceptsEquivalentValidators(string headerValue)
    {
        Assert.True(PokerStateFunction.MatchesIfNoneMatch([headerValue], CurrentEtag));
    }

    [Theory]
    [InlineData("\"older\"")]
    [InlineData("W/\"older\", \"newer\"")]
    [InlineData("")]
    public void MatchesIfNoneMatch_RejectsDifferentOrEmptyValidators(string headerValue)
    {
        Assert.False(PokerStateFunction.MatchesIfNoneMatch([headerValue], CurrentEtag));
    }
}
