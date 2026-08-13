# sp_TexasHoldEm

Multiplayer fixed-limit Texas Hold 'Em, played entirely inside SQL Server
Management Studio. Each query window is a player. Yes, really.

## Quick start

1. Create [sp_TexasHoldEm.sql](sp_TexasHoldEm.sql) in any user database.
   Everyone must connect to that **same database** (the game state lives in
   global temp tables, which Azure SQL DB scopes per-database).
2. In one query window:

   ```sql
   EXEC sp_TexasHoldEm @PlayerName = 'Brent';
   ```

   That starts a game and waits up to 60 seconds for others to join.
3. In other windows (up to 4 seats total):

   ```sql
   EXEC sp_TexasHoldEm @PlayerName = 'Erika';
   ```

   If nobody joins within 60 seconds, three robots sit in: **Clippy**,
   **HAL**, and **Bender**. If the table is full, you become an observer and
   see everything the public would see standing at the table.
4. Your query keeps "running" while you wait — that's the design. Watch the
   **Messages** tab: the action streams in live (bets, folds, the flop, robot
   trash talk). The query finishes when *you* need to act, and the results
   tell you exactly what to run:

   ```sql
   EXEC sp_TexasHoldEm @Action = 'Call',  @PlayerName = 'Brent';
   EXEC sp_TexasHoldEm @Action = 'Raise', @PlayerName = 'Brent';
   EXEC sp_TexasHoldEm @Action = 'Fold',  @PlayerName = 'Brent';
   ```

   After each hand, run `EXEC sp_TexasHoldEm` again to keep playing.

## Actions

| Action | What it does |
| --- | --- |
| *(none)* / `Join` | Join or start a game; if seated, wait for your turn |
| `Check`, `Call`, `Bet`, `Raise`, `Fold` | Play poker (`Bet` and `Raise` are the same in fixed-limit) |
| `Leave` | Cash out (folds first if you're mid-hand) |
| `Watch` | Spectate without taking a seat |
| `Status` | Instant snapshot of the table — never blocks |
| `Help` | Cheat sheet |

## House rules

- Fixed-limit: blinds 10/20, bets of 20 pre-flop and on the flop, 40 on the
  turn and river, max one bet + three raises per betting round.
- Everyone starts with 1,000 chips. You're out when you're broke (though you
  can buy back in if a seat is open).
- 60-second shot clock per decision: dawdle and you auto-check or auto-fold.
  Three timeouts and your seat goes to someone with better attendance.
- No side pots: you can call all-in for less, and a short-stacked winner
  takes the whole pot. This is a demo, not the WSOP.
- `@PlayerName` is optional but recommended: it's the key that lets you
  reconnect from a new session and reclaim your seat (and your chips).

## Requirements & caveats

- SQL Server 2017+ or Azure SQL DB (uses `STRING_AGG` and `##` temp tables).
- All players connect to the same database on the same server. On boxed SQL
  Server there's **one game per instance**: the `##` tables are
  instance-global but applocks are database-scoped, so the game records its
  home database and refuses sessions connected anywhere else rather than
  risk two databases mutating one game under different locks.
- No permanent objects outside the proc itself: game state lives in
  `##TexasHoldEm_Game`, `##TexasHoldEm_Players`, and `##TexasHoldEm_Log`,
  created by whoever runs the proc first. **If that first session
  disconnects, SQL Server drops the tables and the game evaporates** —
  everyone else gets a polite message about the house burning down.
- Concurrency is serialized through `sp_getapplock`, so simultaneous
  sessions can't corrupt the game; a stalled player just gets folded by the
  shot clock (the clock is enforced whenever *any* session's query is
  running — in a solo game against the robots, nothing moves while your
  query isn't running, so take your time).

## How it works, briefly

Every session runs the same loop: grab an applock, advance everything that's
ready to advance (robot decisions, shot-clock folds, street deals, showdowns,
the next hand), snapshot the world, release the lock, stream new log rows to
the client with `RAISERROR ... WITH NOWAIT`, and `WAITFOR DELAY` two seconds.
Whichever session happens to hold the lock does the dealing — the "dealer" is
distributed. The 7-card hand evaluator scores each showdown hand into a
single `bigint` (category + tiebreakers), so winners compare with `MAX()`.
