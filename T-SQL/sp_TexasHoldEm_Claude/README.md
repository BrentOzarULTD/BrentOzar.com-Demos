# sp_TexasHoldEm

Multiplayer fixed-limit Texas Hold 'Em, played entirely inside SQL Server
Management Studio. Each query window is a player. Yes, really.

Two builds live in this folder:

- **[sp_TexasHoldEm.sql](sp_TexasHoldEm.sql)** — the original. Game state
  lives in global temp tables, zero permanent objects, perfect for playing
  with people you trust. Anyone connected can also `SELECT` everyone's hole
  cards, `UPDATE` their own chips, or `DROP` the casino, so only run it with
  people you trust. Preserved here for historical purposes.
- **[sp_TexasHoldEm_Public.sql](sp_TexasHoldEm_Public.sql)** — the hardened
  build for hosting a game on the open internet, where the players are
  hostile strangers who know T-SQL. See
  [Hosting for the public](#hosting-for-the-public-sp_texasholdem_public)
  below.

A plumbing-first Azure Function and WordPress live viewer proof of concept is
in **[web/](web/README.md)**. It calls the public procedure in non-blocking
spectator mode and refreshes a WordPress page without a full-page reload.

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
   EXEC sp_TexasHoldEm @PlayerName = 'Claude';
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

The public procedure also supports polling clients. Pass `@WaitForTurn = 0`
to process all currently ready transitions and return immediately, or use
`@Action = 'Status'`, which is always non-blocking. Poll about every two
seconds during a hand and less often in the lobby. A 30-second client command
timeout leaves room for the procedure's 15-second busy-table lock timeout.
The four result sets keep the same order and shape in both modes.

## Actions

| Action | What it does |
| --- | --- |
| *(none)* / `Join` | Join or start a game; if seated, wait for your turn |
| `Check`, `Call`, `Bet`, `Raise`, `Fold` | Play poker (`Bet` and `Raise` are the same in fixed-limit) |
| `Leave` | Cash out (folds first if you're mid-hand) |
| `Watch` | Spectate without taking a seat |
| `Status` | Instant snapshot of the table — never blocks |
| `NewGame` | Open a fresh lobby after `GAME OVER` |
| `Reset` | Atomically abandon any table and open a fresh lobby (database administrators only) |
| `Help` | Cheat sheet |

Actions are case-insensitive. A normal join after `GAME OVER` still starts a
new game for backward compatibility; `NewGame` makes that lifecycle choice
explicit. Both lifecycle commands clear seats, waitlist reservations, retained
identities, cards, bets, pot, and prior game log state under the game lock,
then record the initiating database identity in the new log without including
credentials.

## House rules

- Fixed-limit: blinds 10/20, bets of 20 pre-flop and on the flop, 40 on the
  turn and river, max one bet + three raises per betting round.
- A genuinely new identity starts with 1,000 chips. When that identity busts,
  it stays `OUT` for 60 minutes and cannot immediately collect another free
  stack. A new game or administrator `Reset` starts a fresh roster.
- Bust every robot at the table and you keep your stack — that isn't a win
  condition, it's just a big pot. On the next hand, queued humans take open
  seats first, then fresh robots buy in for 1,000 each wherever chairs remain.
  The game only ends when no humans are left, so there's no "winning" it and a
  human on a heater can grow without bound. Every robot refill mints new chips;
  this is a public demo table, not a tournament.
- 60-second shot clock per decision: dawdle and you auto-check or auto-fold.
  Three timeouts cost your seat, but your actual remaining stack is retained
  as a `SPECTATOR` for 10 minutes so you can reconnect and request a seat.
- Retained human identities are capped at 64. Admission evicts the oldest
  `OUT` rows first, then stale spectators, and never an active seat.
- After a hand, the final table and transcript remain available until every
  participating human checks in or a 60-second acknowledgement deadline
  expires. A seated player who misses that deadline is moved to `SPECTATOR`
  with their remaining stack retained and must explicitly request a seat when
  they return. Disconnected, departed, and busted identities cannot hold the
  next hand indefinitely.
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

## Hosting for the public (sp_TexasHoldEm_Public)

The original trusts every session in the database, because global temp
tables have no permissions: any player can read hole cards, forge chips, or
drop the game. The public build assumes the opposite — every player is
hostile and fluent in T-SQL — and changes the design accordingly:

- **Protected, encrypted state.** Game state moves to five tables in the
  `TexasHoldEm_Public` schema, created by an admin. Hole-card identifiers are
  encrypted at rest and decrypted only in authorized paths inside the
  certificate-signed procedure. The dedicated player role can execute the
  procedure, is explicitly denied direct access to the schema, and receives
  no certificate permissions. No card peeking, chip forging, or dropping the
  casino — and the game survives disconnects, so nobody's session is
  load-bearing anymore.
- **Seat passwords.** Reclaiming a seat by `@PlayerName` from a new session
  now requires the optional `@SeatPassword` you joined with (salted SHA-256
  in the table). No password, no reclaim, no hijacking someone's stack.
- **Real session identity.** SQL Server recycles `session_id`s, so seats are
  bound to `session_id` + `login_time` — a recycled id can't inherit a seat.
- **No take-backs.** The proc refuses to run inside a caller's transaction
  (goodbye, `ROLLBACK`-your-losing-bet trick) and resets hostile session
  settings like `SET ROWCOUNT 1` that would quietly maim the engine.
- **Un-jammable lock.** The `sp_getapplock` resource name is a random GUID
  stored where players can't read it, so nobody can grab the lock outside
  the proc and hold the game hostage.
- **Boring names.** Player names are limited to letters, digits, single
  spaces, dots, dashes, and underscores — no control characters, quotes, or
  Unicode homoglyphs for forging log lines or impersonating players.
- **Janitorial service.** Abandoned tables get swept after 30 minutes, the
  log is trimmed so it doesn't grow forever, and waiting queries give up
  after 30 minutes to hand their worker threads back.

Setup (as an admin, in the database that hosts the game): run the whole
script — it creates the protected schema, five tables, certificate, player
role, and signed procedure. Re-running it won't wipe a game in progress;
upgrading an older installation transfers its tables into the protected
schema and encrypts any active hole cards before removing the plaintext
columns. Then create a login for the public and add its user to exactly one
role:

```sql
-- In master:
CREATE LOGIN PokerPublic WITH PASSWORD = N'something long and weird';
-- In the game database:
CREATE USER PokerPublic FOR LOGIN PokerPublic;
ALTER ROLE TexasHoldEm_Public_Players ADD MEMBER PokerPublic;
```

Don't add that user to any other database roles, don't grant `VIEW DATABASE
STATE`, and don't add `EXECUTE AS` to the proc (it would break the
session-identity check). Database owners, server administrators, and
principals allowed to alter the procedure, protected schema, tables, or
certificate remain outside this security boundary. What hostile players can
still do: play badly, stall (the shot clock folds them), and open lots of
connections — so host it in a small, cheap database that shares hardware
with nothing you love.

## How it works, briefly

Every session runs the same loop: grab an applock, advance everything that's
ready to advance (robot decisions, shot-clock folds, street deals, showdowns,
the next hand), snapshot the world, release the lock, stream new log rows to
the client with `RAISERROR ... WITH NOWAIT`, and `WAITFOR DELAY` two seconds.
Whichever session happens to hold the lock does the dealing — the "dealer" is
distributed. The 7-card hand evaluator scores each showdown hand into a
single `bigint` (category + tiebreakers), so winners compare with `MAX()`.
