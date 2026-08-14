namespace PokerApi.Models;

public sealed record PokerSnapshot(
    DateTimeOffset GeneratedAt,
    bool Stale,
    HandSnapshot Hand,
    IReadOnlyList<SeatSnapshot> Seats,
    IReadOnlyList<string> WhatNow,
    IReadOnlyList<string> History);

public sealed record HandSnapshot(
    int? HandNumber,
    string Stage,
    string Board,
    int Pot,
    string YourCards,
    int? YourChips);

public sealed record SeatSnapshot(
    int Seat,
    string Player,
    string Position,
    int Chips,
    int ThisRound,
    string Cards,
    string Status);

public sealed record ApiError(string Error);
