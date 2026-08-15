/* sp_TexasHoldEm_Public - multiplayer Texas Hold 'Em for the open internet,
   played entirely in SSMS, hardened for hostile players who know T-SQL.

This is the public-casino build of sp_TexasHoldEm. Same game, same robots,
same questionable life choices - but the game state lives in real tables the
players can't touch, so the only way to interact with the game is through
this stored procedure. The original global-temp-table version lives next to
this file for historical purposes: run THAT one with friends you trust, and
this one with everybody else.

=====================================================================
HOW TO HOST A PUBLIC GAME (do this part as an admin)
=====================================================================

  1. Run this WHOLE script in the database that will host the game. It
     creates protected game tables in the TexasHoldEm_Public schema, a
     certificate-signed procedure, and a least-privilege player role.
     Re-running the script is safe - it won't wipe a game in progress.

  2. Create a login for the rabble and grant it exactly ONE thing:

        -- In master:
        CREATE LOGIN PokerPublic WITH PASSWORD = N'something long and weird';
        -- In the game database:
        CREATE USER PokerPublic FOR LOGIN PokerPublic;
        ALTER ROLE TexasHoldEm_Public_Players ADD MEMBER PokerPublic;

     Do NOT add that user to any other database roles, do NOT grant VIEW
     DATABASE STATE, and do NOT add EXECUTE AS to the proc (it would break
     the session-identity check that stops seat hijacking). The player role
     can execute only this procedure and is explicitly denied direct access
     to the protected schema. Hole cards are encrypted at rest and decrypted
     only inside the signed procedure. db_owner, server administrators, and
     principals that can alter the procedure, schema, tables, or certificate
     remain outside this security boundary.

  3. Publish the server name, the database name, and the PokerPublic
     password on your blog, then watch the Messages tab fill with regret.

What hostile players CAN'T do here (all of which work on the original):
  - Read everyone's hole cards by SELECTing the game tables.
  - UPDATE their chip count, the pot, or the deck.
  - DROP the game, or evaporate it by disconnecting (state is durable now).
  - Wrap the proc in their own transaction and ROLLBACK their losing bets:
    the proc refuses to start inside a user transaction.
  - Sneak in a SET ROWCOUNT 1 before calling so the engine's multi-row
    UPDATEs quietly stop after one row.
  - Grab the applock and hold it forever to jam the game: the lock's
    resource name is a random GUID stored where players can't read it.
  - Take over another player's seat: reclaiming a seat by name requires the
    seat's @SeatPassword, and same-session identity is checked with
    session_id + login_time so a recycled session id can't inherit a seat.
  - Register names with control characters, Unicode homoglyphs, quotes, or
    embedded fake log lines: names are up to 30 chars of boring
    letters/digits/spaces/dots/dashes/underscores.

What they still CAN do, because a stored procedure is not a bouncer:
  - Occupy seats and play terribly. Working as intended.
  - Stall. The shot clock auto-folds them; three strikes and the seat opens.
  - Walk away mid-game. An abandoned table gets swept after 30 minutes.
  - Open piles of connections and burn worker threads. That's a resource
    governance problem, not a poker problem: host this in a small, cheap
    database that shares hardware with nothing you love. Waiting queries
    give up after 30 minutes on their own to hand workers back.
  - Type their @SeatPassword into their own query window, where their own
    monitoring tools (or a conference projector) can see it. Passwords are
    salted and hashed in the table, but tell people not to reuse anything
    they care about. This is a poker demo, not a bank.

=====================================================================
HOW TO PLAY
=====================================================================

  1. Everyone connects to the SAME database and runs, in one query window:
        EXEC sp_TexasHoldEm_Public @PlayerName = 'Brent', @SeatPassword = 'hunter2';
     That starts a game and waits up to 60 seconds for others to join.
     Both parameters are optional - you'll get a name like "Player 57" -
     but @SeatPassword is the ONLY way to reconnect from a new session and
     reclaim your seat, so set one if you like your chips.

  2. In other windows/sessions:   EXEC sp_TexasHoldEm_Public @PlayerName = 'Claude';
     4 physical seats, up to 8 humans total. Any chair still empty when the
     join window closes gets a robot in it - Clippy, HAL, and Bender - so the
     table always plays full. The next human to walk up takes a robot's
     chair rather than going to the rail (mid-hand, the robot cashes out at
     the end of the hand first). Once all 4 seats are humans, the next
     arrivals - up to 4 more - queue on a waitlist and get seated the moment
     a chair opens, in line order. Only 8 humans deep (4 seated + 4 waiting)
     actually puts you on the rail as an observer, seeing what the public
     sees. Already at the table and want a different name? Just pass a new
     @PlayerName - it takes effect immediately if nobody else has it.

  3. Your query "runs" while you wait - that's the design. Watch the Messages
     tab: the action streams in live. The query finishes when YOU need to do
     something, and the results tell you exactly what to run, like:
        EXEC sp_TexasHoldEm_Public @Action = 'Call',  @PlayerName = 'Brent';
        EXEC sp_TexasHoldEm_Public @Action = 'Raise', @PlayerName = 'Brent';
        EXEC sp_TexasHoldEm_Public @Action = 'AllIn', @PlayerName = 'Brent';
        EXEC sp_TexasHoldEm_Public @Action = 'Fold',  @PlayerName = 'Brent';
     After a hand ends, run EXEC sp_TexasHoldEm_Public again to keep playing.

     Applications and scripts can opt out of the streaming wait:
        EXEC sp_TexasHoldEm_Public @PlayerName = 'Brent', @WaitForTurn = 0;
        EXEC sp_TexasHoldEm_Public @Action = 'Status';
     A non-blocking call advances every transition that is ready, returns the
     same four result sets, and stops when the engine reaches a human decision
     or future deadline. Poll Status about every 2 seconds while active and
     less often in the lobby. Use a client command timeout of at least 30
     seconds so a busy table's 15-second applock timeout can be reported.
     Status is always non-blocking regardless of @WaitForTurn.

  4. Every call hands back four result sets, in this order: Hand (the table
     at a glance), Seat (who's sitting where), What Now (the exact commands
     to run next), and What Happened (the play-by-play). By default, What
     Happened only covers this turn - the action since you last ran a
     query. To see more, pass @ShowWhatHappened:
        'ThisTurn'   - the default: just what you missed since last time.
        'ThisGame'   - every hand of the game currently being played.
        'AllHistory' - all retained log rows since the last RESET or explicit
                       NEWGAME. Bring popcorn.

Actions: Join (default), Check, Call, Bet, Raise, AllIn, Fold, Leave, Watch,
         Status (instant snapshot, never blocks), NewGame (after GAME OVER),
         Reset (database administrators only), Help. Actions are case-insensitive.

House rules:
  - Fixed-limit Hold 'Em: blinds 10/20, bets 20 pre-flop & flop, 40 on the
    turn & river, max one bet + three raises per round. Everybody starts
    with 1,000 chips. When you're broke, that identity stays OUT for 60
    minutes instead of receiving another free stack.
  - 60-second shot clock per decision. Take too long and you auto-check or
    auto-fold; three strikes cost your seat, but your remaining stack is
    retained for a 10-minute reconnect window.
  - AllIn is the one move the limit doesn't limit: shove your whole stack any
    time it's your turn, even when the raise cap is maxed out. The robots will
    do it to you too, but only when they're short-stacked.
  - No side pots: you can call all-in for less, and if you win you take the
    whole pot. Vegas would not approve. Vegas also isn't a stored procedure.
    The only mercy is that an uncalled bet comes back to you - shove 500 into
    a player who only had 200 and you get the extra 300 returned.

Requirements & caveats:
  - SQL Server 2017+ or Azure SQL DB (uses STRING_AGG).
  - All players must be in the same database. The game state lives in real
    TexasHoldEm_Public.* tables, one game per database, and it survives
    disconnects: nobody's session is load-bearing anymore.
  - The whole game serializes on sp_getapplock, so a hung session can't
    corrupt the table state - it just gets folded by the shot clock.

License and info: see the bottom of this file.
*/
SET ANSI_NULLS ON;
GO
SET QUOTED_IDENTIFIER ON;
GO
/* =====================================================================
   ONE-TIME SETUP: certificate, protected schema, and game tables. Run as
   an admin (someone with dbo rights). Idempotent - re-running won't wipe a
   game in progress. Existing dbo.TexasHoldEm_* tables are transferred into
   the protected schema without changing their data.
   ===================================================================== */
IF CERT_ID(N'sp_TexasHoldEm_CardProtection_Claude') IS NULL
BEGIN
    CREATE CERTIFICATE sp_TexasHoldEm_CardProtection_Claude
        ENCRYPTION BY PASSWORD = 'Cl@udeTexasH0ldEm_2026!Cards'
        WITH SUBJECT = 'Encrypt sp_TexasHoldEm_Public hole cards',
             EXPIRY_DATE = '20991231';
END;
GO

IF DATABASE_PRINCIPAL_ID(N'sp_TexasHoldEm_CardProtection_Claude_User') IS NULL
    CREATE USER sp_TexasHoldEm_CardProtection_Claude_User
        FROM CERTIFICATE sp_TexasHoldEm_CardProtection_Claude;
GO

GRANT CONTROL ON CERTIFICATE::sp_TexasHoldEm_CardProtection_Claude
    TO sp_TexasHoldEm_CardProtection_Claude_User;
GO

REVOKE CONTROL ON CERTIFICATE::sp_TexasHoldEm_CardProtection_Claude FROM public;
GO

IF SCHEMA_ID(N'TexasHoldEm_Public') IS NULL
    EXEC(N'CREATE SCHEMA TexasHoldEm_Public AUTHORIZATION dbo;');
GO

/* Preserve installations made by earlier versions. A conflicting pair of
   old and new tables requires an administrator to reconcile the data rather
   than letting the installer guess which active game should survive. */
IF OBJECT_ID(N'dbo.TexasHoldEm_Game', N'U') IS NOT NULL
BEGIN
    IF OBJECT_ID(N'TexasHoldEm_Public.TexasHoldEm_Game', N'U') IS NOT NULL
        THROW 50020, 'Both legacy and protected TexasHoldEm_Game tables exist. Reconcile them before rerunning the installer.', 1;
    ALTER SCHEMA TexasHoldEm_Public TRANSFER dbo.TexasHoldEm_Game;
END;
IF OBJECT_ID(N'dbo.TexasHoldEm_Players', N'U') IS NOT NULL
BEGIN
    IF OBJECT_ID(N'TexasHoldEm_Public.TexasHoldEm_Players', N'U') IS NOT NULL
        THROW 50021, 'Both legacy and protected TexasHoldEm_Players tables exist. Reconcile them before rerunning the installer.', 1;
    ALTER SCHEMA TexasHoldEm_Public TRANSFER dbo.TexasHoldEm_Players;
END;
IF OBJECT_ID(N'dbo.TexasHoldEm_Waitlist', N'U') IS NOT NULL
BEGIN
    IF OBJECT_ID(N'TexasHoldEm_Public.TexasHoldEm_Waitlist', N'U') IS NOT NULL
        THROW 50022, 'Both legacy and protected TexasHoldEm_Waitlist tables exist. Reconcile them before rerunning the installer.', 1;
    ALTER SCHEMA TexasHoldEm_Public TRANSFER dbo.TexasHoldEm_Waitlist;
END;
IF OBJECT_ID(N'dbo.TexasHoldEm_Log', N'U') IS NOT NULL
BEGIN
    IF OBJECT_ID(N'TexasHoldEm_Public.TexasHoldEm_Log', N'U') IS NOT NULL
        THROW 50023, 'Both legacy and protected TexasHoldEm_Log tables exist. Reconcile them before rerunning the installer.', 1;
    ALTER SCHEMA TexasHoldEm_Public TRANSFER dbo.TexasHoldEm_Log;
END;
IF OBJECT_ID(N'dbo.TexasHoldEm_Identities', N'U') IS NOT NULL
BEGIN
    IF OBJECT_ID(N'TexasHoldEm_Public.TexasHoldEm_Identities', N'U') IS NOT NULL
        THROW 50025, 'Both legacy and protected TexasHoldEm_Identities tables exist. Reconcile them before rerunning the installer.', 1;
    ALTER SCHEMA TexasHoldEm_Public TRANSFER dbo.TexasHoldEm_Identities;
END;
GO

IF OBJECT_ID(N'TexasHoldEm_Public.TexasHoldEm_Game', N'U') IS NULL
CREATE TABLE TexasHoldEm_Public.TexasHoldEm_Game (
    GameState varchar(20) NOT NULL,
    HandNumber int NOT NULL,
    DealerSeat tinyint NULL,
    SmallBlindSeat tinyint NULL,
    BigBlindSeat tinyint NULL,
    BettingRound tinyint NULL,      /* 0 pre-flop, 1 flop, 2 turn, 3 river */
    BoardShown tinyint NOT NULL DEFAULT 0,
    ShowdownShown bit NOT NULL DEFAULT 0,
    Board1 tinyint NULL, Board2 tinyint NULL, Board3 tinyint NULL,
    Board4 tinyint NULL, Board5 tinyint NULL,
    Pot int NOT NULL DEFAULT 0,
    BetToCall int NOT NULL DEFAULT 0,
    RaiseCount int NOT NULL DEFAULT 0,
    TurnSeat tinyint NULL,
    TurnStartedAt datetime2 NULL,
    JoinWindowEndsAt datetime2 NULL,
    NextHandStartsAt datetime2 NULL,
    /* The applock's resource name. Random, and unreadable by players, so
       nobody can sp_getapplock it themselves and hold the game hostage. */
    ApplockResource nvarchar(60) NOT NULL);

IF OBJECT_ID(N'TexasHoldEm_Public.TexasHoldEm_Players', N'U') IS NULL
CREATE TABLE TexasHoldEm_Public.TexasHoldEm_Players (
    SeatNum tinyint PRIMARY KEY,
    /* Explicit CI collation + UNIQUE: a name is a player's identity, so it
       must not depend on the host database's collation. On a case-sensitive
       database, "Alice" and "alice" would otherwise be two different seats,
       and the reconnect/impersonation checks would quietly change behavior.
       The UNIQUE constraint keeps the invariant with the data, not just in
       procedural checks. */
    PlayerName nvarchar(30) COLLATE Latin1_General_100_CI_AS NOT NULL UNIQUE,
    SessionId int NOT NULL,
    /* session_id gets recycled when sessions disconnect, so a seat is only
       "yours" if BOTH the session id and its login_time match. */
    SessionLoginTime datetime2 NULL,
    /* Salted hash of the seat's reconnect password. NULL = no password =
       the seat can't be reclaimed from another session. */
    PasswordSalt varbinary(16) NULL,
    PasswordHash varbinary(32) NULL,
    IsBot bit NOT NULL,
    Chips int NOT NULL,
    HoleCardsEncrypted varbinary(8000) NULL,
    InHand bit NOT NULL DEFAULT 0,
    Folded bit NOT NULL DEFAULT 0,
    AllIn bit NOT NULL DEFAULT 0,
    BetThisRound int NOT NULL DEFAULT 0,
    NeedsToAct bit NOT NULL DEFAULT 0,
    TimeoutStrikes tinyint NOT NULL DEFAULT 0,
    WantsToLeave bit NOT NULL DEFAULT 0,
    LastPlayedHand int NOT NULL
        CONSTRAINT DF_TexasHoldEm_Players_LastPlayedHand DEFAULT (0),
    LastViewedHand int NOT NULL
        CONSTRAINT DF_TexasHoldEm_Players_LastViewedHand DEFAULT (0),
    /* The hand number this seat last won a pot in. The seat grid compares it
       to the game's current hand number, so it clears itself the moment the
       next hand is dealt - no cleanup pass required. 0 = never won one. */
    LastWonHand int NOT NULL
        CONSTRAINT DF_TexasHoldEm_Players_LastWonHand DEFAULT (0));

/* Upgrade installations created before per-player showdown acknowledgement. */
IF COL_LENGTH(N'TexasHoldEm_Public.TexasHoldEm_Players', N'LastPlayedHand') IS NULL
    ALTER TABLE TexasHoldEm_Public.TexasHoldEm_Players
        ADD LastPlayedHand int NOT NULL
            CONSTRAINT DF_TexasHoldEm_Players_LastPlayedHand DEFAULT (0) WITH VALUES;

IF COL_LENGTH(N'TexasHoldEm_Public.TexasHoldEm_Players', N'LastViewedHand') IS NULL
    ALTER TABLE TexasHoldEm_Public.TexasHoldEm_Players
        ADD LastViewedHand int NOT NULL
            CONSTRAINT DF_TexasHoldEm_Players_LastViewedHand DEFAULT (0) WITH VALUES;

/* Upgrade installations created before the seat grid called out the winner. */
IF COL_LENGTH(N'TexasHoldEm_Public.TexasHoldEm_Players', N'LastWonHand') IS NULL
    ALTER TABLE TexasHoldEm_Public.TexasHoldEm_Players
        ADD LastWonHand int NOT NULL
            CONSTRAINT DF_TexasHoldEm_Players_LastWonHand DEFAULT (0) WITH VALUES;

/* Whoever ran out of chips in the hand that just ended. The seat table has
   to let them go the instant the hand is over - the chair belongs to the
   next player, and a stack of zero can't be dealt in - but the results grid
   that comes back with that showdown still owes an explanation. Without
   this, calling an all-in and busting two opponents makes those opponents
   vanish from the Seat result set while the play-by-play is still talking
   about them. One row per busted seat, replaced at the end of every hand
   and rendered only while HandNumber still matches. */
IF OBJECT_ID(N'TexasHoldEm_Public.TexasHoldEm_HandBusts', N'U') IS NULL
CREATE TABLE TexasHoldEm_Public.TexasHoldEm_HandBusts (
    SeatNum tinyint NOT NULL
        CONSTRAINT PK_TexasHoldEm_HandBusts PRIMARY KEY,
    PlayerName nvarchar(30) COLLATE Latin1_General_100_CI_AS NOT NULL,
    IsBot bit NOT NULL,
    HandNumber int NOT NULL,
    /* Filled in only when the hand reached a showdown and these two cards
       were already public in the play-by-play. Empty for anyone who folded
       their way to zero: busting out is not a reason to expose a hand. */
    Cards nvarchar(12) NOT NULL
        CONSTRAINT DF_TexasHoldEm_HandBusts_Cards DEFAULT (N''));

/* Humans who showed up after all 4 physical seats (and every robot) were
   already spoken for. First in line gets the next chair that opens - see
   @MaxHumans / @MaxWaitlist below for the caps. */
IF OBJECT_ID(N'TexasHoldEm_Public.TexasHoldEm_Waitlist', N'U') IS NULL
CREATE TABLE TexasHoldEm_Public.TexasHoldEm_Waitlist (
    WaitId int IDENTITY(1,1) PRIMARY KEY,
    PlayerName nvarchar(30) COLLATE Latin1_General_100_CI_AS NOT NULL UNIQUE,
    SessionId int NOT NULL,
    SessionLoginTime datetime2 NULL,
    PasswordSalt varbinary(16) NULL,
    PasswordHash varbinary(32) NULL,
    /* NULL = ordinary FIFO waiter. Non-NULL = this specific seat was
       promised to this human when a robot got bumped mid-hand - see the
       mid-hand bump branch below. Reserved entries skip the FIFO line. */
    ReservedSeat tinyint NULL,
    JoinedAt datetime2 NOT NULL DEFAULT SYSDATETIME());

/* Human identity and bankroll outlive a physical chair. This is deliberately
   separate from TexasHoldEm_Players so the hot-path seat engine can keep its
   compact, non-null SeatNum key while busted and timed-out humans remain
   recognizable for a bounded grace period. */
IF OBJECT_ID(N'TexasHoldEm_Public.TexasHoldEm_Identities', N'U') IS NULL
BEGIN
    CREATE TABLE TexasHoldEm_Public.TexasHoldEm_Identities
    (
        IdentityId bigint IDENTITY(1,1) NOT NULL
            CONSTRAINT PK_TexasHoldEm_Identities PRIMARY KEY,
        PlayerName nvarchar(30) COLLATE Latin1_General_100_CI_AS NOT NULL
            CONSTRAINT UQ_TexasHoldEm_Identities_PlayerName UNIQUE,
        SessionId int NOT NULL,
        SessionLoginTime datetime2 NULL,
        PasswordSalt varbinary(16) NULL,
        PasswordHash varbinary(32) NULL,
        Chips int NOT NULL,
        PlayerRole varchar(12) NOT NULL,
        WantsSeat bit NOT NULL
            CONSTRAINT DF_TexasHoldEm_Identities_WantsSeat DEFAULT (0),
        TimedOut bit NOT NULL
            CONSTRAINT DF_TexasHoldEm_Identities_TimedOut DEFAULT (0),
        JoinedAt datetime2 NOT NULL
            CONSTRAINT DF_TexasHoldEm_Identities_JoinedAt DEFAULT SYSDATETIME(),
        LastSeenAt datetime2 NOT NULL
            CONSTRAINT DF_TexasHoldEm_Identities_LastSeenAt DEFAULT SYSDATETIME(),
        LastPlayedHand int NOT NULL
            CONSTRAINT DF_TexasHoldEm_Identities_LastPlayedHand DEFAULT (0),
        LastViewedHand int NOT NULL
            CONSTRAINT DF_TexasHoldEm_Identities_LastViewedHand DEFAULT (0),
        CONSTRAINT CK_TexasHoldEm_Identities_Role
            CHECK (PlayerRole IN ('PLAYER', 'SPECTATOR', 'OUT')),
        CONSTRAINT CK_TexasHoldEm_Identities_Amounts
            CHECK (Chips >= 0 AND LastPlayedHand >= 0 AND LastViewedHand >= 0)
    );

    CREATE INDEX IX_TexasHoldEm_Identities_Retention
        ON TexasHoldEm_Public.TexasHoldEm_Identities
           (PlayerRole, LastSeenAt, JoinedAt);
END;

/* Adopt live pre-identity seats and waiters without resetting their stacks or
   reconnect credentials. Re-running the installer refreshes active rows but
   never overwrites a retained spectator/OUT bankroll with 1,000. */
UPDATE i
   SET SessionId = p.SessionId, SessionLoginTime = p.SessionLoginTime,
       PasswordSalt = p.PasswordSalt, PasswordHash = p.PasswordHash,
       Chips = p.Chips, PlayerRole = 'PLAYER', WantsSeat = 0,
       TimedOut = 0, LastPlayedHand = p.LastPlayedHand,
       LastViewedHand = p.LastViewedHand
FROM TexasHoldEm_Public.TexasHoldEm_Identities AS i
JOIN TexasHoldEm_Public.TexasHoldEm_Players AS p
  ON p.PlayerName = i.PlayerName
WHERE p.IsBot = 0;

INSERT TexasHoldEm_Public.TexasHoldEm_Identities
    (PlayerName, SessionId, SessionLoginTime, PasswordSalt, PasswordHash,
     Chips, PlayerRole, WantsSeat, TimedOut, LastPlayedHand, LastViewedHand)
SELECT p.PlayerName, p.SessionId, p.SessionLoginTime, p.PasswordSalt, p.PasswordHash,
       p.Chips, 'PLAYER', 0, 0, p.LastPlayedHand, p.LastViewedHand
FROM TexasHoldEm_Public.TexasHoldEm_Players AS p
WHERE p.IsBot = 0
  AND NOT EXISTS
      (SELECT 1 FROM TexasHoldEm_Public.TexasHoldEm_Identities AS i
       WHERE i.PlayerName = p.PlayerName);

UPDATE i
   SET SessionId = w.SessionId, SessionLoginTime = w.SessionLoginTime,
       PasswordSalt = w.PasswordSalt, PasswordHash = w.PasswordHash,
       WantsSeat = 1
FROM TexasHoldEm_Public.TexasHoldEm_Identities AS i
JOIN TexasHoldEm_Public.TexasHoldEm_Waitlist AS w
  ON w.PlayerName = i.PlayerName
WHERE i.PlayerRole = 'SPECTATOR';

INSERT TexasHoldEm_Public.TexasHoldEm_Identities
    (PlayerName, SessionId, SessionLoginTime, PasswordSalt, PasswordHash,
     Chips, PlayerRole, WantsSeat, TimedOut, JoinedAt)
SELECT w.PlayerName, w.SessionId, w.SessionLoginTime, w.PasswordSalt, w.PasswordHash,
       1000, 'SPECTATOR', 1, 0, w.JoinedAt
FROM TexasHoldEm_Public.TexasHoldEm_Waitlist AS w
WHERE NOT EXISTS
      (SELECT 1 FROM TexasHoldEm_Public.TexasHoldEm_Identities AS i
       WHERE i.PlayerName = w.PlayerName);

IF OBJECT_ID(N'TexasHoldEm_Public.TexasHoldEm_Log', N'U') IS NULL
CREATE TABLE TexasHoldEm_Public.TexasHoldEm_Log (
    LogId int IDENTITY(1,1) PRIMARY KEY,
    HandNumber int NOT NULL,
    EventTime datetime2 NOT NULL DEFAULT SYSDATETIME(),
    Message nvarchar(500) NOT NULL);

/* Encrypt any in-progress hole cards from the legacy table before removing
   the plaintext columns. A half-populated legacy pair is incompatible and
   is left untouched with a clear recovery instruction. */
IF COL_LENGTH(N'TexasHoldEm_Public.TexasHoldEm_Players', N'HoleCardsEncrypted') IS NULL
    ALTER TABLE TexasHoldEm_Public.TexasHoldEm_Players
        ADD HoleCardsEncrypted varbinary(8000) NULL;
GO

IF COL_LENGTH(N'TexasHoldEm_Public.TexasHoldEm_Players', N'Card1') IS NOT NULL
BEGIN
    EXEC(N'
        IF EXISTS
        (
            SELECT 1
            FROM TexasHoldEm_Public.TexasHoldEm_Players
            WHERE (Card1 IS NULL AND Card2 IS NOT NULL)
               OR (Card1 IS NOT NULL AND Card2 IS NULL)
               OR (HoleCardsEncrypted IS NOT NULL AND (Card1 IS NOT NULL OR Card2 IS NOT NULL))
        )
            THROW 50024, ''Incompatible live hole-card state found. Repair the player row pairs before rerunning the installer.'', 1;

        UPDATE TexasHoldEm_Public.TexasHoldEm_Players
        SET HoleCardsEncrypted = EncryptByCert
        (
            CERT_ID(N''sp_TexasHoldEm_CardProtection_Claude''),
            CONVERT(varbinary(1), Card1) + CONVERT(varbinary(1), Card2)
        )
        WHERE Card1 IS NOT NULL
          AND Card2 IS NOT NULL
          AND HoleCardsEncrypted IS NULL;

        ALTER TABLE TexasHoldEm_Public.TexasHoldEm_Players DROP COLUMN Card1, Card2;
    ');
END;
GO

IF NOT EXISTS (SELECT 1 FROM TexasHoldEm_Public.TexasHoldEm_Game)
INSERT TexasHoldEm_Public.TexasHoldEm_Game (GameState, HandNumber, ApplockResource)
VALUES ('GameOver', 0, CONCAT(N'TexasHoldEm_', NEWID()));
GO

IF DATABASE_PRINCIPAL_ID(N'TexasHoldEm_Public_Players') IS NULL
    CREATE ROLE TexasHoldEm_Public_Players AUTHORIZATION dbo;
GO

DENY SELECT, INSERT, UPDATE, DELETE, ALTER, CONTROL, TAKE OWNERSHIP, VIEW DEFINITION
    ON SCHEMA::TexasHoldEm_Public TO TexasHoldEm_Public_Players;
GO
CREATE OR ALTER PROCEDURE dbo.sp_TexasHoldEm_Public
    @Action nvarchar(20) = NULL,
    @PlayerName nvarchar(30) = NULL,
    @SeatPassword nvarchar(50) = NULL,
    /* 1 preserves the SSMS streaming wait. 0 processes ready work once and
       returns for polling clients without executing WAITFOR. */
    @WaitForTurn bit = 1,
    /* How much of the play-by-play to show in the What Happened result set:
       ThisTurn (default), ThisGame, or AllHistory. */
    @ShowWhatHappened nvarchar(20) = N'ThisTurn'
AS
BEGIN
SET NOCOUNT ON;
/* Hostile callers get to pick their session settings, so pick them back:
   SET ROWCOUNT 1 before EXEC would quietly maim every multi-row UPDATE in
   the engine, and a weaponized lock timeout or isolation level is just as
   rude. All of these revert automatically when the proc returns. */
SET ROWCOUNT 0;
SET XACT_ABORT ON;
SET LOCK_TIMEOUT -1;
SET TRANSACTION ISOLATION LEVEL READ COMMITTED;

/* House rules - tweak to taste: */
DECLARE @SmallBlind int = 10,
        @BigBlind int = 20,
        @SmallBet int = 20,          /* bet size pre-flop and on the flop */
        @BigBet int = 40,            /* bet size on the turn and river */
        @MaxRaises int = 4,          /* one bet + three raises per round */
        @StartingChips int = 1000,
        @MaxSeats int = 4,           /* physical chairs at the table */
        @MaxHumans int = 8,          /* total humans allowed in the game: seated + waitlisted */
        @JoinWindowSeconds int = 60,
        @TurnSeconds int = 60,       /* the shot clock */
        @MaxTimeoutStrikes int = 3,
        @BetweenHandsSeconds int = 60, /* acknowledgement deadline */
        @MaxWaitMinutes int = 30,    /* give up blocking after this long - waiting queries hold worker threads */
        @AbandonedAfterMinutes int = 30,  /* sweep a table nobody's touched in this long */
        @SpectatorRetentionMinutes int = 10,
        @OutRetentionMinutes int = 60,
        @MaxRetainedIdentities int = 64;
DECLARE @MaxWaitlist int = @MaxHumans - @MaxSeats;

DECLARE @rc int,
        @Msg nvarchar(2047),
        @Notice nvarchar(500),
        @LockResource nvarchar(60),
        @GameRows int,
        @MyLoginTime datetime2,
        @MySeat tinyint,
        @MyInHand bit,
        @IsObserver bit = 0,
        @ReturnNow bit = 0,
        @SkipEngine bit = 0,
        @FirstPass bit = 1,
        @ToldWaiting bit = 0,
        @LeftTable bit = 0,
        @SeatStolen bit = 0,
        @GaveUp bit = 0,
        @GameGone bit = 0,
        @TargetHand int = 0,
        @WaitStart datetime2 = SYSDATETIME(),
        @LastLogId int = 0,
        @LastNotice nvarchar(500),
        /* Where "this turn" starts in the log: whatever was already on the
           board when this call picked the game up. */
        @TurnStartLogId int = 0,
        @GameStartLogId int = 0,
        @ResponseLogUpper int = 0,
        @CardsShownForHand int = -1,
        /* game snapshot */
        @GState varchar(20), @GHand int, @Dealer tinyint, @SBSeat tinyint, @BBSeat tinyint,
        @Round tinyint, @BoardShown tinyint, @ShowdownShown bit, @Pot int, @PotDisp int,
        @BetToCall int, @RaiseCount int, @TurnSeat tinyint, @TurnStartedAt datetime2,
        @JoinEnds datetime2, @NextHandAt datetime2,
        @B1 tinyint, @B2 tinyint, @B3 tinyint, @B4 tinyint, @B5 tinyint,
        @BoardDisp nvarchar(30),
        @TurnPlayerName nvarchar(30), @SnapshotAt datetime2,
        /* my seat snapshot */
        @SeatExists bit, @CurOwner int, @CurLoginTime datetime2,
        @SeatSalt varbinary(16), @SeatHash varbinary(32),
        @FoundBySession bit = 0, @WaitId int, @WaitPos int, @MyReservedSeat tinyint,
        @MyNeedsToAct bit, @MyFolded bit, @MissedAction nvarchar(20),
        @MyChips int, @MyBet int, @MyC1 tinyint, @MyC2 tinyint, @MyCards nvarchar(12),
        /* engine workspace */
        @Spins int, @StartHandNow bit, @HandDone bit,
        @NumPlayers int, @HumansLeft int, @ReturningHumans int, @NumInHand int, @Unfolded int, @ActiveBettors int,
        @UnviewedHumans int, @BustedHumans int,
        @PrevDealer tinyint, @ActorSeat tinyint, @ActorBot bit, @ActorName nvarchar(30),
        @ActorChips int, @ActorBet int, @ActorStrikes tinyint,
        @ActorRank1 int, @ActorRank2 int, @CanRaise bit, @Shove bit,
        @Owed int, @Unit int, @NewBet int, @Pay int, @AllInTo int, @NextSeat tinyint, @r int,
        @TopBet int, @NextBet int, @RefundSeat tinyint, @Refund int,
        @BumpSeat tinyint, @BumpName nvarchar(30),
        @BotsAdded int,
        @BotMove varchar(10), @RoundBets int, @WinSeat tinyint, @WinName nvarchar(30),
        /* showdown & hand evaluation */
        @cSeat tinyint, @cName nvarchar(30), @cC1 tinyint, @cC2 tinyint,
        @FlushSuit tinyint, @StraightHigh int, @SFHigh int,
        @Quad int, @Trip int, @Pair1 int, @Pair2 int, @FHPair int,
        @Cat bigint, @T1 int, @T2 int, @T3 int, @T4 int, @T5 int,
        @Score bigint, @HandName nvarchar(60),
        @BestScore bigint, @NumWinners int, @Share int, @Rem int,
        @NameArg nvarchar(80), @SecondsLeft int,
        @LifecycleActor nvarchar(128);

DECLARE @IdentityFound bit = 0,
        @IdentityRole varchar(12),
        @IdentityTimedOut bit = 0,
        @IdentityChips int,
        @JoinChips int = @StartingChips,
        @IdentityName nvarchar(30),
        @IdentityId bigint,
        @IdentitySession int,
        @IdentityLoginTime datetime2,
        @IdentitiesToEvict int;

DECLARE @NewLog TABLE (LogId int, Message nvarchar(500));
DECLARE @Shuffled TABLE (Pos int, CardId tinyint);
DECLARE @Seven TABLE (CardRank int, CardSuit tinyint);
DECLARE @RanksT TABLE (CardRank int);
DECLARE @FRanks TABLE (CardRank int);
DECLARE @ShowResults TABLE (SeatNum tinyint, PlayerName nvarchar(30), Score bigint, HandName nvarchar(60));
DECLARE @Prompt TABLE (LineId int IDENTITY(1,1), Line nvarchar(300));
DECLARE @Happened TABLE (LogId int, Message nvarchar(500));
DECLARE @PlayerSnapshot TABLE
(
    SeatNum tinyint PRIMARY KEY,
    PlayerName nvarchar(30) NOT NULL,
    IsBot bit NOT NULL,
    Chips int NOT NULL,
    BetThisRound int NOT NULL,
    InHand bit NOT NULL,
    Folded bit NOT NULL,
    AllIn bit NOT NULL,
    Cards nvarchar(12) NOT NULL,
    LastWonHand int NOT NULL,
    /* 1 = this seat is only here to be explained: they lost their last chip
       in the hand that just ended and the seat table has already let go. */
    Busted bit NOT NULL DEFAULT 0
);
DECLARE @Promoted TABLE (WaitId int, SeatNum tinyint, PlayerName nvarchar(30) COLLATE Latin1_General_100_CI_AS,
    SessionId int, SessionLoginTime datetime2, PasswordSalt varbinary(16), PasswordHash varbinary(32), Chips int);
DECLARE @EvictedIdentities TABLE
    (PlayerName nvarchar(30) COLLATE Latin1_General_100_CI_AS PRIMARY KEY);

/* A deck of cards. CardId 0-51: rank = CardId / 4 + 2 (2..14), suit = CardId % 4. */
CREATE TABLE #Poker_Cards (CardId tinyint PRIMARY KEY, CardRank int, CardSuit tinyint, Display nvarchar(3));
;WITH n AS (SELECT TOP (52) ROW_NUMBER() OVER (ORDER BY (SELECT NULL)) - 1 AS CardId FROM sys.all_objects)
INSERT #Poker_Cards (CardId, CardRank, CardSuit, Display)
SELECT CardId, CardId / 4 + 2, CardId % 4,
       CASE CardId / 4 + 2 WHEN 14 THEN N'A' WHEN 13 THEN N'K' WHEN 12 THEN N'Q' WHEN 11 THEN N'J'
            ELSE CAST(CardId / 4 + 2 AS nvarchar(2)) END
       + SUBSTRING(N'♠♥♦♣', CardId % 4 + 1, 1)
FROM n;

CREATE TABLE #Poker_RankNames (RankValue int PRIMARY KEY, RankName nvarchar(6), RankPlural nvarchar(7));
INSERT #Poker_RankNames (RankValue, RankName, RankPlural) VALUES
 (2,N'Two',N'Twos'),(3,N'Three',N'Threes'),(4,N'Four',N'Fours'),(5,N'Five',N'Fives'),
 (6,N'Six',N'Sixes'),(7,N'Seven',N'Sevens'),(8,N'Eight',N'Eights'),(9,N'Nine',N'Nines'),
 (10,N'Ten',N'Tens'),(11,N'Jack',N'Jacks'),(12,N'Queen',N'Queens'),(13,N'King',N'Kings'),(14,N'Ace',N'Aces');

SET @Action = NULLIF(LTRIM(RTRIM(@Action)), N'');
SET @PlayerName = NULLIF(LTRIM(RTRIM(@PlayerName)), N'');
SET @SeatPassword = NULLIF(@SeatPassword, N'');
SET @WaitForTurn = ISNULL(@WaitForTurn, 1);
SET @ShowWhatHappened = ISNULL(NULLIF(LTRIM(RTRIM(@ShowWhatHappened)), N''), N'ThisTurn');
/* Canonical action casing keeps behavior stable on case-sensitive databases.
   Nobody types ALL IN the same way twice under pressure, so take the common
   spellings too. */
SET @Action = CASE
    WHEN @Action COLLATE Latin1_General_100_CI_AS = N'Join' THEN NULL
    WHEN @Action COLLATE Latin1_General_100_CI_AS = N'Check' THEN N'Check'
    WHEN @Action COLLATE Latin1_General_100_CI_AS = N'Call' THEN N'Call'
    WHEN @Action COLLATE Latin1_General_100_CI_AS = N'Bet' THEN N'Bet'
    WHEN @Action COLLATE Latin1_General_100_CI_AS = N'Raise' THEN N'Raise'
    WHEN @Action COLLATE Latin1_General_100_CI_AS IN (N'AllIn', N'All In', N'All-In', N'All_In', N'Shove', N'Jam') THEN N'AllIn'
    WHEN @Action COLLATE Latin1_General_100_CI_AS = N'Fold' THEN N'Fold'
    WHEN @Action COLLATE Latin1_General_100_CI_AS = N'Leave' THEN N'Leave'
    WHEN @Action COLLATE Latin1_General_100_CI_AS = N'Watch' THEN N'Watch'
    WHEN @Action COLLATE Latin1_General_100_CI_AS = N'Status' THEN N'Status'
    WHEN @Action COLLATE Latin1_General_100_CI_AS = N'NewGame' THEN N'NewGame'
    WHEN @Action COLLATE Latin1_General_100_CI_AS = N'Reset' THEN N'Reset'
    WHEN @Action COLLATE Latin1_General_100_CI_AS = N'Help' THEN N'Help'
    ELSE @Action END;

IF @Action = N'Status'
BEGIN
    SET @WaitForTurn = 0;
END

/* Explicit CI collation so this behaves the same on a case-sensitive
   database - the value picks a code path, so it can't drift with collation. */
IF @ShowWhatHappened COLLATE Latin1_General_100_CI_AS
   NOT IN (N'ThisTurn', N'ThisGame', N'AllHistory')
BEGIN
    SELECT [Say What?] = CONCAT(N'I don''t know the @ShowWhatHappened option ''', @ShowWhatHappened,
        N'''. Try: ThisTurn (the default), ThisGame, or AllHistory.');
    RETURN;
END
/* Snap it to canonical casing so the checks further down don't have to keep
   spelling out the collation. */
SET @ShowWhatHappened = CASE
    WHEN @ShowWhatHappened COLLATE Latin1_General_100_CI_AS = N'ThisGame' THEN N'ThisGame'
    WHEN @ShowWhatHappened COLLATE Latin1_General_100_CI_AS = N'AllHistory' THEN N'AllHistory'
    ELSE N'ThisTurn' END;

IF @Action IS NOT NULL
   AND @Action NOT IN (N'Check', N'Call', N'Bet', N'Raise', N'AllIn', N'Fold', N'Leave', N'Watch', N'Status', N'NewGame', N'Reset', N'Help')
BEGIN
    SELECT [Say What?] = CONCAT(N'I don''t know the action ''', @Action,
        N'''. Try: Join, Check, Call, Bet, Raise, AllIn, Fold, Leave, Watch, Status, NewGame, Reset, or Help.');
    RETURN;
END

IF @Action = N'Help'
BEGIN
    SELECT [sp_TexasHoldEm_Public Help] = v.Line
    FROM (VALUES
        (1, N'EXEC sp_TexasHoldEm_Public @PlayerName = ''YourName'', @SeatPassword = ''secret'';  -- join (or start) a game'),
        (2, N'   (@SeatPassword is optional, but it''s the ONLY way to reconnect from a new session.)'),
        (3, N'EXEC sp_TexasHoldEm_Public @Action = ''Check'',  @PlayerName = ''YourName'';'),
        (4, N'EXEC sp_TexasHoldEm_Public @Action = ''Call'',   @PlayerName = ''YourName'';'),
        (5, N'EXEC sp_TexasHoldEm_Public @Action = ''Raise'',  @PlayerName = ''YourName'';  -- ''Bet'' works too'),
        (6, N'EXEC sp_TexasHoldEm_Public @Action = ''AllIn'',  @PlayerName = ''YourName'';  -- shove the whole stack'),
        (7, N'EXEC sp_TexasHoldEm_Public @Action = ''Fold'',   @PlayerName = ''YourName'';'),
        (8, N'EXEC sp_TexasHoldEm_Public @Action = ''Leave'',  @PlayerName = ''YourName'';  -- cash out'),
        (9, N'EXEC sp_TexasHoldEm_Public @Action = ''Watch'';                              -- spectate, never sits you down'),
        (10,N'EXEC sp_TexasHoldEm_Public @Action = ''Status'';                             -- instant snapshot, never blocks'),
        (11,N'From your original session, actions just work. From a NEW session, add your @SeatPassword.'),
        (12,N'Already seated and pass a different @PlayerName? That''s a rename - takes effect right away.'),
        (13,N'Table''s full (4 seats)? Up to 4 more humans can wait on a queue and get seated in line order.'),
        (14,N'While your query runs, watch the Messages tab - the action streams in live.'),
        (15,N'The query finishes when it''s your turn, and tells you exactly what to run next.'),
        (16,N'Results come back as: Hand, Seat, What Now, What Happened.'),
        (17,N'What Happened shows just this turn by default. Add @ShowWhatHappened = ''ThisGame'''),
        (18,N'for the whole game, or @ShowWhatHappened = ''AllHistory'' for all retained rows since RESET or explicit NEWGAME.'),
        (19,N'EXEC sp_TexasHoldEm_Public @Action = ''NewGame'';  -- start fresh after GAME OVER'),
        (20,N'EXEC sp_TexasHoldEm_Public @Action = ''Reset'';    -- database administrators only; abandon any table'),
        (21,N'Busted identities stay OUT for 60 minutes; they cannot immediately collect another free stack.'),
        (22,N'Timed-out players keep their chips off-table for 10 minutes and may reconnect to request a seat.')
        ) v(LineId, Line)
    ORDER BY v.LineId;
    RETURN;
END

IF @Action = N'Reset'
   AND ISNULL(HAS_PERMS_BY_NAME(DB_NAME(), N'DATABASE', N'CONTROL'), 0) <> 1
    THROW 50006, 'RESET is restricted to database administrators.', 1;

/* Names for the public: short and boring, on purpose. No quotes to escape,
   no control characters to forge log lines with, no Unicode homoglyphs to
   impersonate other players with, no consecutive spaces to fake a lookalike. */
/* Every literal leads this bracket list on purpose, dash included. Under a
   binary collation, SQL Server's LIKE drops a literal underscore or dash
   from a character class when it trails adjacent A-Z/a-z/0-9 ranges
   (reproduced directly against the engine), so the old
   '[^A-Za-z0-9 ._-]' ordering rejected every legitimate name containing
   either character - exactly the names the message below promises are
   fine. A '-' immediately after the '^' can't be read as a range
   boundary, so it is unambiguously literal. This is not cosmetic
   reordering. */
IF @PlayerName IS NOT NULL
   AND (@PlayerName LIKE N'%[^-_ .A-Za-z0-9]%' COLLATE Latin1_General_100_BIN2
        OR @PlayerName LIKE N'%  %')
BEGIN
    SELECT [Say What?] = N'Player names here are boring on purpose: up to 30 characters of letters, numbers, single spaces, dots, dashes, and underscores. No emoji, no zero-width shenanigans, no pretending to be somebody else.';
    RETURN;
END

/* Explicit CI collation: under a Turkish database collation, UPPER('clippy')
   yields CLİPPY (dotted İ), which would sneak past a default-collation check. */
IF @PlayerName COLLATE Latin1_General_100_CI_AS IN (N'Clippy', N'HAL', N'Bender')
BEGIN
    SELECT [Nice Try] = CONCAT(@PlayerName, N' is one of the house robots. Pick a different name.');
    RETURN;
END

/* Refuse to deal inside a caller's transaction: commit-then-ROLLBACK would
   let a player watch a bet play out and then rewind it. Casinos don't do
   take-backs, and neither does this one. */
IF @@TRANCOUNT > 0
BEGIN
    SELECT [Nice Try] = N'You''re inside your own transaction, which would let you ROLLBACK your losing bets. The house has seen that movie. COMMIT or ROLLBACK first, then come play.';
    RETURN;
END

/* Is the casino built? OBJECT_ID would lie here: a player with only
   EXECUTE on this proc has no metadata visibility on the tables, so
   OBJECT_ID returns NULL for them even when everything is deployed
   correctly. Probe with dynamic SQL instead - it runs as the caller, with
   no ownership chaining, so a locked-down player gets error 229
   (permission denied - the healthy state, carry on), while a missing
   table raises error 208 from a lower execution level, which - unlike a
   same-scope compile error - this proc CAN catch and translate. */
DECLARE @ProbeDummy int;
BEGIN TRY
    /* Assign into a variable rather than running a bare SELECT: a bare
       SELECT here hands the caller a phantom empty result set on EVERY
       call, ahead of the four documented ones (Hand, Seat, What Now, What
       Happened), which silently breaks any client that reads result sets
       by position. TOP (1) keeps the probe from enumerating a five-way
       unfiltered cross join; the existence and permission checks that make
       this probe worthwhile still happen regardless of how many rows come
       back. */
    EXEC sp_executesql N'SELECT TOP (1) @ProbeDummy = 1 FROM TexasHoldEm_Public.TexasHoldEm_Game, TexasHoldEm_Public.TexasHoldEm_Players, TexasHoldEm_Public.TexasHoldEm_Log, TexasHoldEm_Public.TexasHoldEm_Waitlist, TexasHoldEm_Public.TexasHoldEm_Identities;',
        N'@ProbeDummy int OUTPUT', @ProbeDummy OUTPUT;
END TRY
BEGIN CATCH
    IF ERROR_NUMBER() = 208
    BEGIN
        SELECT [Not Deployed] = N'The casino hasn''t been built: the TexasHoldEm_Public.TexasHoldEm_* tables are missing. An admin needs to run the full setup script from the top of this proc''s source file.';
        RETURN;
    END
END CATCH

/* The applock's name is random and stored where players can't read it, so
   nobody can grab the lock outside this proc and jam the game. The whole
   proc assumes TexasHoldEm_Public.TexasHoldEm_Game holds exactly ONE row; if an admin's
   been improvising in there, fail fast instead of playing nondeterministic
   poker with whichever row each session happens to read. */
SELECT @GameRows = COUNT(*), @LockResource = MAX(ApplockResource) FROM TexasHoldEm_Public.TexasHoldEm_Game;
IF @GameRows <> 1 OR @LockResource IS NULL
BEGIN
    SELECT [Not Deployed] = CASE WHEN @GameRows > 1
        THEN N'The TexasHoldEm_Public.TexasHoldEm_Game table has more than one row, and this casino only knows how to run one game. An admin needs to delete the extras (keep the row whose ApplockResource everyone should share).'
        ELSE N'The TexasHoldEm_Public.TexasHoldEm_Game table has no game row. An admin needs to re-run the full setup script to finish building the casino.' END;
    RETURN;
END

/* Who am I? session_id alone isn't identity - SQL Server recycles them -
   so a seat is only "yours" if the login_time matches too. Users can always
   see their own row in sys.dm_exec_sessions, no extra permissions needed. */
SELECT @MyLoginTime = login_time FROM sys.dm_exec_sessions WHERE session_id = @@SPID;
SET @MyLoginTime = ISNULL(@MyLoginTime, '19000101');

BEGIN TRY

WHILE 1 = 1
BEGIN
    /* The tables are permanent now, so the game only vanishes if an admin
       drops it out from under us. Notice, and bow out gracefully. */
    IF @FirstPass = 0 AND NOT EXISTS (SELECT 1 FROM TexasHoldEm_Public.TexasHoldEm_Game)
    BEGIN
        SET @GameGone = 1;
        BREAK;
    END

    BEGIN TRAN;
    EXEC @rc = sp_getapplock @Resource = @LockResource, @LockMode = 'Exclusive',
                             @LockOwner = 'Transaction', @LockTimeout = 15000;
    IF @rc < 0
    BEGIN
        ROLLBACK;
        RAISERROR(N'Couldn''t get the table lock - the game is jammed up. Try again in a few seconds.', 16, 1);
        RETURN;
    END

    /* ================================================================
       FIRST PASS ONLY: sweep dead games, take a seat, apply your action.
       ================================================================ */
    IF @FirstPass = 1
    BEGIN
        SET @FirstPass = 0;

        /* The Messages tab still gets a short backlog for context, because
           scrolling into a hand cold is confusing. */
        SET @LastLogId = ISNULL((SELECT MAX(LogId) FROM TexasHoldEm_Public.TexasHoldEm_Log), 0) - 12;
        IF @LastLogId < 0 SET @LastLogId = 0;
        /* ...but the What Happened grid starts HERE, at the log's actual high
           water mark, so it holds this turn and nothing else. The log outlives
           games in the public build, so anchoring the grid to the backlog
           instead meant a fresh session opened on the tail of somebody else's
           finished hand. Pass @ShowWhatHappened = 'ThisGame' to see more. */
        SET @TurnStartLogId = ISNULL((SELECT MAX(LogId) FROM TexasHoldEm_Public.TexasHoldEm_Log), 0);

        /* Explicit lifecycle controls run under the same transaction-owned
           applock as joins and engine work, so reset/join races serialize.
           Preserve the random applock resource itself; changing it while the
           old resource is held would split the serialization boundary. */
        IF @Action = N'NewGame'
           AND (SELECT GameState FROM TexasHoldEm_Public.TexasHoldEm_Game) <> 'GameOver'
        BEGIN
            SET @Notice = N'NEWGAME is available only after GAME OVER. A database administrator can use RESET to abandon the running game.';
            SET @ReturnNow = 1;
            SET @SkipEngine = 1;
        END
        ELSE IF @Action IN (N'Reset', N'NewGame')
        BEGIN
            SET @LifecycleActor = COALESCE(ORIGINAL_LOGIN(), SUSER_SNAME(), USER_NAME(), N'unknown administrator');

            DELETE TexasHoldEm_Public.TexasHoldEm_Waitlist;
            DELETE TexasHoldEm_Public.TexasHoldEm_Players;
            DELETE TexasHoldEm_Public.TexasHoldEm_HandBusts;
            DELETE TexasHoldEm_Public.TexasHoldEm_Identities;
            DELETE TexasHoldEm_Public.TexasHoldEm_Log;

            UPDATE TexasHoldEm_Public.TexasHoldEm_Game
               SET GameState = 'WaitingForPlayers', HandNumber = 0, DealerSeat = NULL,
                   SmallBlindSeat = NULL, BigBlindSeat = NULL, BettingRound = NULL,
                   BoardShown = 0, ShowdownShown = 0,
                   Board1 = NULL, Board2 = NULL, Board3 = NULL, Board4 = NULL, Board5 = NULL,
                   Pot = 0, BetToCall = 0, RaiseCount = 0, TurnSeat = NULL, TurnStartedAt = NULL,
                   JoinWindowEndsAt = DATEADD(second, @JoinWindowSeconds, SYSDATETIME()),
                   NextHandStartsAt = NULL;

            INSERT TexasHoldEm_Public.TexasHoldEm_Log (HandNumber, Message)
            VALUES (0, CONCAT(CASE WHEN @Action = N'Reset' THEN N'Table RESET by ' ELSE N'NEWGAME started by ' END,
                              @LifecycleActor, N'. A fresh join window is open.'));

            IF @Action = N'Reset'
            BEGIN
                SET @Notice = N'The table was reset atomically. A fresh join window is open.';
                SET @ReturnNow = 1;
            END
            ELSE
            BEGIN
                /* NEWGAME is also a seat request, matching the legacy
                   post-game join behavior: the caller enters with a clean
                   starting stack and receives the lobby response now. */
                SET @Notice = N'A fresh 1,000-chip game and join window are open.';
                SET @Action = NULL;
                SET @WaitForTurn = 0;
            END
            SET @SkipEngine = 1;
        END

        /* On a public server, tables get abandoned mid-hand. If nothing has
           happened for a while, sweep the chips and reset rather than making
           the next visitor sit through a parade of shot-clock timeouts. */
        IF (SELECT GameState FROM TexasHoldEm_Public.TexasHoldEm_Game) IN ('InHand', 'BetweenHands')
           AND ISNULL((SELECT MAX(EventTime) FROM TexasHoldEm_Public.TexasHoldEm_Log), SYSDATETIME())
               < DATEADD(minute, -@AbandonedAfterMinutes, SYSDATETIME())
        BEGIN
            DELETE TexasHoldEm_Public.TexasHoldEm_Players;
            DELETE TexasHoldEm_Public.TexasHoldEm_HandBusts;
            DELETE TexasHoldEm_Public.TexasHoldEm_Waitlist;
            UPDATE TexasHoldEm_Public.TexasHoldEm_Game
               SET GameState = 'GameOver', TurnSeat = NULL, NextHandStartsAt = NULL;
            INSERT TexasHoldEm_Public.TexasHoldEm_Log (HandNumber, Message)
            SELECT HandNumber, CONCAT(N'The table sat abandoned for ', @AbandonedAfterMinutes,
                   N' minutes, so the house swept the chips and reset the game.')
            FROM TexasHoldEm_Public.TexasHoldEm_Game;
        END

        /* Last game ended? Joining sweeps up the confetti and starts fresh. */
        IF (SELECT GameState FROM TexasHoldEm_Public.TexasHoldEm_Game) = 'GameOver' AND @Action IS NULL
        BEGIN
            DELETE TexasHoldEm_Public.TexasHoldEm_Players;
            DELETE TexasHoldEm_Public.TexasHoldEm_HandBusts;
            DELETE TexasHoldEm_Public.TexasHoldEm_Waitlist;
            DELETE TexasHoldEm_Public.TexasHoldEm_Identities;
            UPDATE TexasHoldEm_Public.TexasHoldEm_Game
               SET GameState = 'WaitingForPlayers', HandNumber = 0, DealerSeat = NULL,
                   SmallBlindSeat = NULL, BigBlindSeat = NULL, BettingRound = NULL,
                   BoardShown = 0, ShowdownShown = 0,
                   Board1 = NULL, Board2 = NULL, Board3 = NULL, Board4 = NULL, Board5 = NULL,
                   Pot = 0, BetToCall = 0, RaiseCount = 0, TurnSeat = NULL, TurnStartedAt = NULL,
                   JoinWindowEndsAt = DATEADD(second, @JoinWindowSeconds, SYSDATETIME()),
                   NextHandStartsAt = NULL;
            INSERT TexasHoldEm_Public.TexasHoldEm_Log (HandNumber, Message)
            VALUES (0, CONCAT(N'A new game is starting! Waiting up to ', @JoinWindowSeconds,
                    N' seconds for players to join.'));
        END

        /* Keep the durable human record synchronized with active seats and
           waiters. Bets still mutate the compact seat table; the identity
           copy is refreshed under this same lock on every call and again at
           hand end before any seat is removed. */
        UPDATE i
           SET SessionId = p.SessionId, SessionLoginTime = p.SessionLoginTime,
               PasswordSalt = p.PasswordSalt, PasswordHash = p.PasswordHash,
               Chips = p.Chips, PlayerRole = 'PLAYER', WantsSeat = 0,
               TimedOut = 0, LastPlayedHand = p.LastPlayedHand,
               LastViewedHand = p.LastViewedHand
        FROM TexasHoldEm_Public.TexasHoldEm_Identities AS i
        JOIN TexasHoldEm_Public.TexasHoldEm_Players AS p
          ON p.PlayerName = i.PlayerName
        WHERE p.IsBot = 0;

        UPDATE i
           SET SessionId = w.SessionId, SessionLoginTime = w.SessionLoginTime,
               PasswordSalt = w.PasswordSalt, PasswordHash = w.PasswordHash,
               WantsSeat = 1
        FROM TexasHoldEm_Public.TexasHoldEm_Identities AS i
        JOIN TexasHoldEm_Public.TexasHoldEm_Waitlist AS w
          ON w.PlayerName = i.PlayerName
        WHERE i.PlayerRole = 'SPECTATOR';

        /* The connection that owns an identity keeps it alive even if its
           name was omitted on this invocation. */
        UPDATE TexasHoldEm_Public.TexasHoldEm_Identities
           SET LastSeenAt = SYSDATETIME()
         WHERE SessionId = @@SPID AND SessionLoginTime = @MyLoginTime;

        /* Expire abandoned, unseated identities so names and storage do not
           stay reserved forever. Waitlist rows are removed with their stale
           identity; active physical seats are never candidates. */
        DELETE @EvictedIdentities;
        INSERT @EvictedIdentities (PlayerName)
        SELECT i.PlayerName
        FROM TexasHoldEm_Public.TexasHoldEm_Identities AS i
        WHERE NOT EXISTS
              (SELECT 1 FROM TexasHoldEm_Public.TexasHoldEm_Players AS p
               WHERE p.IsBot = 0 AND p.PlayerName = i.PlayerName)
          AND NOT (i.SessionId = @@SPID AND i.SessionLoginTime = @MyLoginTime)
          AND
          (
              (i.PlayerRole = 'SPECTATOR'
               AND i.LastSeenAt < DATEADD(minute, -@SpectatorRetentionMinutes, SYSDATETIME()))
              OR
              (i.PlayerRole = 'OUT'
               AND i.LastSeenAt < DATEADD(minute, -@OutRetentionMinutes, SYSDATETIME()))
          );

        DELETE w
        FROM TexasHoldEm_Public.TexasHoldEm_Waitlist AS w
        JOIN @EvictedIdentities AS e ON e.PlayerName = w.PlayerName;
        DELETE i
        FROM TexasHoldEm_Public.TexasHoldEm_Identities AS i
        JOIN @EvictedIdentities AS e ON e.PlayerName = i.PlayerName;

        /* Resolve retained identity by the non-recycled session pair first.
           A different connection may take control only with the password and
           only on the same actions that already reclaim a live seat. */
        SET @IdentityFound = 0; SET @IdentityId = NULL; SET @IdentityName = NULL;
        SET @IdentityRole = NULL; SET @IdentityChips = NULL; SET @IdentityTimedOut = 0;
        SELECT @IdentityFound = 1, @IdentityId = IdentityId,
               @IdentityName = PlayerName, @IdentityRole = PlayerRole,
               @IdentityChips = Chips, @IdentityTimedOut = TimedOut,
               @IdentitySession = SessionId, @IdentityLoginTime = SessionLoginTime,
               @SeatSalt = PasswordSalt, @SeatHash = PasswordHash
        FROM TexasHoldEm_Public.TexasHoldEm_Identities
        WHERE SessionId = @@SPID AND SessionLoginTime = @MyLoginTime;

        IF @IdentityFound = 0 AND @PlayerName IS NOT NULL
           AND (@Action IS NULL OR @Action IN (N'Check', N'Call', N'Bet', N'Raise', N'AllIn', N'Fold', N'Leave'))
        BEGIN
            SET @IdentityId = NULL; SET @SeatSalt = NULL; SET @SeatHash = NULL;
            SELECT @IdentityId = IdentityId, @IdentityName = PlayerName,
                   @IdentityRole = PlayerRole, @IdentityChips = Chips,
                   @IdentityTimedOut = TimedOut,
                   @IdentitySession = SessionId, @IdentityLoginTime = SessionLoginTime,
                   @SeatSalt = PasswordSalt, @SeatHash = PasswordHash
            FROM TexasHoldEm_Public.TexasHoldEm_Identities
            WHERE PlayerName = @PlayerName;

            IF @IdentityId IS NOT NULL
            BEGIN
                IF @SeatHash IS NOT NULL AND @SeatPassword IS NOT NULL
                   AND @SeatHash = HASHBYTES('SHA2_256', @SeatSalt + CONVERT(varbinary(100), @SeatPassword))
                BEGIN
                    SET @IdentityFound = 1;
                    UPDATE TexasHoldEm_Public.TexasHoldEm_Identities
                       SET SessionId = @@SPID, SessionLoginTime = @MyLoginTime,
                           LastSeenAt = SYSDATETIME()
                     WHERE IdentityId = @IdentityId;
                    UPDATE TexasHoldEm_Public.TexasHoldEm_Players
                       SET SessionId = @@SPID, SessionLoginTime = @MyLoginTime
                     WHERE IsBot = 0 AND PlayerName = @IdentityName;
                    UPDATE TexasHoldEm_Public.TexasHoldEm_Waitlist
                       SET SessionId = @@SPID, SessionLoginTime = @MyLoginTime
                     WHERE PlayerName = @IdentityName;
                END
                ELSE
                BEGIN
                    SET @Notice = CASE WHEN @SeatHash IS NULL
                        THEN N'That retained identity has no @SeatPassword, so another session cannot reclaim it yet.'
                        ELSE N'That retained identity belongs to another session. Pass the right @SeatPassword to reconnect.' END;
                    SET @ReturnNow = 1;
                END
            END
        END

        IF @IdentityFound = 1
        BEGIN
            /* Preserve an active same-session rename request; retained
               unseated identities always use their canonical saved name. */
            IF @PlayerName IS NULL OR @IdentityRole <> 'PLAYER'
                SET @PlayerName = @IdentityName;
            SET @JoinChips = @IdentityChips;
            IF @IdentityRole = 'OUT'
               AND (@Action IS NULL OR @Action IN (N'Check', N'Call', N'Bet', N'Raise', N'AllIn', N'Fold', N'Leave'))
            BEGIN
                SET @Notice = CONCAT(N'You are OUT with 0 chips. That identity stays busted for ',
                    @OutRetentionMinutes, N' minutes; RESET or a new game clears the tournament roster.');
                SET @ReturnNow = 1;
            END
        END

        /* Bound all retained humans at 64. A genuinely new join evicts the
           oldest OUT identity first, then the stalest spectator, and never an
           active seat. */
        IF @IdentityFound = 0 AND @ReturnNow = 0 AND @Action IS NULL
           AND (SELECT COUNT(*) FROM TexasHoldEm_Public.TexasHoldEm_Identities) >= @MaxRetainedIdentities
        BEGIN
            SELECT @IdentitiesToEvict = COUNT(*) - (@MaxRetainedIdentities - 1)
            FROM TexasHoldEm_Public.TexasHoldEm_Identities;

            DELETE @EvictedIdentities;
            INSERT @EvictedIdentities (PlayerName)
            SELECT TOP (@IdentitiesToEvict) i.PlayerName
            FROM TexasHoldEm_Public.TexasHoldEm_Identities AS i
            WHERE i.PlayerRole IN ('OUT', 'SPECTATOR')
              AND NOT EXISTS
                  (SELECT 1 FROM TexasHoldEm_Public.TexasHoldEm_Players AS p
                   WHERE p.IsBot = 0 AND p.PlayerName = i.PlayerName)
            ORDER BY CASE WHEN i.PlayerRole = 'OUT' THEN 0 ELSE 1 END,
                     i.LastSeenAt, i.JoinedAt, i.IdentityId;

            DELETE w
            FROM TexasHoldEm_Public.TexasHoldEm_Waitlist AS w
            JOIN @EvictedIdentities AS e ON e.PlayerName = w.PlayerName;
            DELETE i
            FROM TexasHoldEm_Public.TexasHoldEm_Identities AS i
            JOIN @EvictedIdentities AS e ON e.PlayerName = i.PlayerName;

            IF (SELECT COUNT(*) FROM TexasHoldEm_Public.TexasHoldEm_Identities) >= @MaxRetainedIdentities
            BEGIN
                SET @Notice = N'The retained-identity roster is full of active players. You can watch, but a new player cannot join yet.';
                SET @ReturnNow = 1;
                SET @IsObserver = 1;
            END
        END

        /* Find my seat: by session identity first (session_id + login_time),
           then by name - but reclaiming a seat by name from a different
           session requires the seat's password. That's the whole point. */
        SET @MySeat = NULL; SET @FoundBySession = 0;
        SELECT @MySeat = SeatNum FROM TexasHoldEm_Public.TexasHoldEm_Players
         WHERE SessionId = @@SPID AND SessionLoginTime = @MyLoginTime AND IsBot = 0;
        IF @MySeat IS NOT NULL SET @FoundBySession = 1;
        /* Only actions that actually take control of the seat may reclaim it -
           a Status or Watch peek must never hijack a live player's session. */
        IF @MySeat IS NULL AND @PlayerName IS NOT NULL
           AND (@Action IS NULL OR @Action IN (N'Check', N'Call', N'Bet', N'Raise', N'AllIn', N'Fold', N'Leave'))
        BEGIN
            SET @CurOwner = NULL; SET @SeatSalt = NULL; SET @SeatHash = NULL;
            SELECT @MySeat = SeatNum, @CurOwner = SessionId,
                   @SeatSalt = PasswordSalt, @SeatHash = PasswordHash
              FROM TexasHoldEm_Public.TexasHoldEm_Players WHERE PlayerName = @PlayerName AND IsBot = 0;
            IF @MySeat IS NOT NULL
            BEGIN
                IF @SeatHash IS NOT NULL AND @SeatPassword IS NOT NULL
                   AND @SeatHash = HASHBYTES('SHA2_256', @SeatSalt + CONVERT(varbinary(100), @SeatPassword))
                BEGIN
                    UPDATE TexasHoldEm_Public.TexasHoldEm_Players
                       SET SessionId = @@SPID, SessionLoginTime = @MyLoginTime
                     WHERE SeatNum = @MySeat;
                    INSERT TexasHoldEm_Public.TexasHoldEm_Log (HandNumber, Message)
                    SELECT HandNumber, CONCAT(@PlayerName, N' reconnected and reclaimed their seat.')
                    FROM TexasHoldEm_Public.TexasHoldEm_Game;
                END
                ELSE
                BEGIN
                    SET @Notice = CASE
                        WHEN @Action IS NOT NULL THEN
                             N'That seat belongs to another session, and the @SeatPassword doesn''t check out. No.'
                        WHEN @SeatHash IS NULL THEN
                             N'That name''s already at the table, and that seat has no @SeatPassword, so it can''t be reclaimed. Pick a different name.'
                        ELSE N'That name''s already at the table. If it''s you, pass the right @SeatPassword to reconnect; if it isn''t, pick a different name.'
                        END;
                    SET @MySeat = NULL;
                    SET @ReturnNow = 1;
                END
            END
        END
        /* Renaming: this is YOUR live session (not a reclaim - reclaiming a
           seat by name is how a dead session gets back in, so that path can't
           also mean "rename me") and you passed a name that isn't what's on
           your seat. Take it, as long as nobody else at the table or on the
           waitlist already has it. */
        IF @FoundBySession = 1 AND @PlayerName IS NOT NULL
           AND @PlayerName <> (SELECT PlayerName FROM TexasHoldEm_Public.TexasHoldEm_Players WHERE SeatNum = @MySeat)
               COLLATE Latin1_General_100_CI_AS
        BEGIN
            IF EXISTS (SELECT 1 FROM TexasHoldEm_Public.TexasHoldEm_Players WHERE PlayerName = @PlayerName AND SeatNum <> @MySeat)
               OR EXISTS (SELECT 1 FROM TexasHoldEm_Public.TexasHoldEm_Waitlist WHERE PlayerName = @PlayerName)
               OR EXISTS (SELECT 1 FROM TexasHoldEm_Public.TexasHoldEm_Identities
                           WHERE PlayerName = @PlayerName AND IdentityId <> ISNULL(@IdentityId, -1))
                SET @Notice = N'That name''s already taken, so your name is unchanged.';
            ELSE
            BEGIN
                INSERT TexasHoldEm_Public.TexasHoldEm_Log (HandNumber, Message)
                SELECT g.HandNumber, CONCAT(p.PlayerName, N' is now known as ', @PlayerName, N'.')
                FROM TexasHoldEm_Public.TexasHoldEm_Game g CROSS JOIN TexasHoldEm_Public.TexasHoldEm_Players p WHERE p.SeatNum = @MySeat;
                UPDATE TexasHoldEm_Public.TexasHoldEm_Identities
                   SET PlayerName = @PlayerName, LastSeenAt = SYSDATETIME()
                 WHERE IdentityId = @IdentityId;
                UPDATE TexasHoldEm_Public.TexasHoldEm_Players SET PlayerName = @PlayerName WHERE SeatNum = @MySeat;
                SET @IdentityName = @PlayerName;
            END
        END

        /* Once the seat is resolved, the seat's name is THE name - always.
           Otherwise a seated player could pass somebody else's @PlayerName
           and have the log narrate their bets under the victim's name. This
           also re-syncs @PlayerName after a rename above (or reverts it if
           the rename was rejected). */
        IF @MySeat IS NOT NULL
            SELECT @PlayerName = PlayerName FROM TexasHoldEm_Public.TexasHoldEm_Players WHERE SeatNum = @MySeat;

        /* Checking in while queued? Recognize a repeat call the same way a
           seated player is recognized: by session first, then by name+password
           if the original session died. Otherwise re-running the same command
           to check status would just keep adding duplicate waitlist entries. */
        SET @WaitId = NULL; SET @MyReservedSeat = NULL;
        IF @MySeat IS NULL
        BEGIN
            SELECT @WaitId = WaitId, @MyReservedSeat = ReservedSeat FROM TexasHoldEm_Public.TexasHoldEm_Waitlist
             WHERE SessionId = @@SPID AND SessionLoginTime = @MyLoginTime;
            IF @WaitId IS NULL AND @PlayerName IS NOT NULL
               AND (@Action IS NULL OR @Action IN (N'Check', N'Call', N'Bet', N'Raise', N'AllIn', N'Fold', N'Leave'))
            BEGIN
                SET @CurOwner = NULL; SET @SeatSalt = NULL; SET @SeatHash = NULL;
                SELECT @WaitId = WaitId, @CurOwner = SessionId, @MyReservedSeat = ReservedSeat,
                       @SeatSalt = PasswordSalt, @SeatHash = PasswordHash
                  FROM TexasHoldEm_Public.TexasHoldEm_Waitlist WHERE PlayerName = @PlayerName;
                IF @WaitId IS NOT NULL
                BEGIN
                    IF @SeatHash IS NOT NULL AND @SeatPassword IS NOT NULL
                       AND @SeatHash = HASHBYTES('SHA2_256', @SeatSalt + CONVERT(varbinary(100), @SeatPassword))
                    BEGIN
                        UPDATE TexasHoldEm_Public.TexasHoldEm_Waitlist
                           SET SessionId = @@SPID, SessionLoginTime = @MyLoginTime
                         WHERE WaitId = @WaitId;
                        UPDATE TexasHoldEm_Public.TexasHoldEm_Identities
                           SET SessionId = @@SPID, SessionLoginTime = @MyLoginTime,
                               LastSeenAt = SYSDATETIME()
                         WHERE PlayerName = @PlayerName;
                    END
                    ELSE
                    BEGIN
                        SET @Notice = CASE
                            WHEN @SeatHash IS NULL THEN
                                 N'That name''s already on the waitlist, and it has no @SeatPassword, so it can''t be reclaimed. Pick a different name.'
                            ELSE N'That name''s already on the waitlist. If it''s you, pass the right @SeatPassword; if it isn''t, pick a different name.'
                            END;
                        SET @WaitId = NULL;
                        SET @ReturnNow = 1;
                    END
                END
            END
            IF @WaitId IS NOT NULL AND @ReturnNow = 0 AND @Action = N'Leave'
            BEGIN
                /* A queued human can bail too - otherwise an abandoned entry
                   sits on one of the four waitlist slots until it's promoted
                   or the whole table gets swept. */
                DELETE TexasHoldEm_Public.TexasHoldEm_Waitlist WHERE WaitId = @WaitId;
                UPDATE TexasHoldEm_Public.TexasHoldEm_Identities
                   SET PlayerRole = 'SPECTATOR', WantsSeat = 0,
                       LastSeenAt = SYSDATETIME()
                 WHERE PlayerName = @PlayerName;
                SET @IdentityRole = 'SPECTATOR';
                SET @Notice = N'You''re off the waitlist. Thanks for your patience!';
                SET @LeftTable = 1;
                SET @ReturnNow = 1;
            END
            ELSE IF @WaitId IS NOT NULL AND @ReturnNow = 0 AND @MyReservedSeat IS NOT NULL
            BEGIN
                SET @Notice = N'Your seat is reserved - a robot is giving it up at the end of the current hand. Run EXEC sp_TexasHoldEm_Public again in a bit to sit down.';
                SET @ReturnNow = 1;
            END
            ELSE IF @WaitId IS NOT NULL AND @ReturnNow = 0
            BEGIN
                SELECT @WaitPos = COUNT(*) FROM TexasHoldEm_Public.TexasHoldEm_Waitlist WHERE WaitId <= @WaitId AND ReservedSeat IS NULL;
                SET @Notice = CONCAT(N'Still on the waitlist, #', @WaitPos,
                    N' in line for a seat. Run EXEC sp_TexasHoldEm_Public again in a bit',
                    N', or EXEC sp_TexasHoldEm_Public @Action = ''Leave'' to give up your spot.');
                SET @ReturnNow = 1;
            END
        END

        IF @Action = N'Watch' AND @MySeat IS NULL SET @IsObserver = 1;
        IF @Action = N'Status' SET @ReturnNow = 1;

        /* Take a seat if there's room; otherwise queue up or watch from the rail. */
        IF @MySeat IS NULL AND @IsObserver = 0 AND @ReturnNow = 0
        BEGIN
            /* The legacy seat/waitlist probes clear these workspace values
               when no physical row exists. Reload durable credentials before
               a retained spectator is reseated or requeued. */
            IF @IdentityFound = 1
                SELECT @SeatSalt = PasswordSalt, @SeatHash = PasswordHash
                FROM TexasHoldEm_Public.TexasHoldEm_Identities
                WHERE IdentityId = @IdentityId;

            IF @Action IN (N'Check', N'Call', N'Bet', N'Raise', N'AllIn', N'Fold', N'Leave')
            BEGIN
                SET @Notice = N'You''re not seated at this table, so you can''t do that. Run EXEC sp_TexasHoldEm_Public to join.';
                SET @ReturnNow = 1;
            END
            ELSE
            BEGIN
                /* Before deciding whether there's room for ME, give any
                   reserved-or-queued human first crack at a seat that's
                   already sitting empty - a chair emptying out between
                   hands doesn't wait for the next deal to be claimed, and
                   it never goes to a brand-new arrival ahead of someone
                   already promised it or already in line. Bots are NOT
                   added here - that stays a hand-boundary thing, so a plain
                   join attempt can't spawn a robot early. */
                DELETE @Promoted;
                INSERT @Promoted (WaitId, SeatNum, PlayerName, SessionId, SessionLoginTime, PasswordSalt, PasswordHash, Chips)
                SELECT w.WaitId, w.ReservedSeat, w.PlayerName, w.SessionId, w.SessionLoginTime,
                       w.PasswordSalt, w.PasswordHash, ISNULL(i.Chips, @StartingChips)
                FROM TexasHoldEm_Public.TexasHoldEm_Waitlist w
                LEFT JOIN TexasHoldEm_Public.TexasHoldEm_Identities i ON i.PlayerName = w.PlayerName
                WHERE w.ReservedSeat IS NOT NULL
                  AND NOT EXISTS (SELECT 1 FROM TexasHoldEm_Public.TexasHoldEm_Players p WHERE p.SeatNum = w.ReservedSeat);

                ;WITH freeseats AS (
                    SELECT v.SeatNum, rn = ROW_NUMBER() OVER (ORDER BY v.SeatNum)
                    FROM (VALUES (1),(2),(3),(4)) v(SeatNum)
                    WHERE NOT EXISTS (SELECT 1 FROM TexasHoldEm_Public.TexasHoldEm_Players p WHERE p.SeatNum = v.SeatNum)
                      AND NOT EXISTS (SELECT 1 FROM @Promoted pr WHERE pr.SeatNum = v.SeatNum)),
                waiters AS (
                    SELECT w.WaitId, w.PlayerName, w.SessionId, w.SessionLoginTime, w.PasswordSalt, w.PasswordHash,
                           Chips = ISNULL(i.Chips, @StartingChips),
                           rn = ROW_NUMBER() OVER (ORDER BY w.WaitId)
                    FROM TexasHoldEm_Public.TexasHoldEm_Waitlist w
                    LEFT JOIN TexasHoldEm_Public.TexasHoldEm_Identities i ON i.PlayerName = w.PlayerName
                    WHERE w.ReservedSeat IS NULL)
                INSERT @Promoted (WaitId, SeatNum, PlayerName, SessionId, SessionLoginTime, PasswordSalt, PasswordHash, Chips)
                SELECT w.WaitId, f.SeatNum, w.PlayerName, w.SessionId, w.SessionLoginTime,
                       w.PasswordSalt, w.PasswordHash, w.Chips
                FROM freeseats f JOIN waiters w ON w.rn = f.rn;

                IF EXISTS (SELECT 1 FROM @Promoted)
                BEGIN
                    INSERT TexasHoldEm_Public.TexasHoldEm_Players (SeatNum, PlayerName, SessionId, SessionLoginTime,
                                                    PasswordSalt, PasswordHash, IsBot, Chips)
                    SELECT SeatNum, PlayerName, SessionId, SessionLoginTime, PasswordSalt, PasswordHash, 0, Chips
                    FROM @Promoted;

                    UPDATE i
                       SET PlayerRole = 'PLAYER', WantsSeat = 0, TimedOut = 0,
                           SessionId = p.SessionId, SessionLoginTime = p.SessionLoginTime,
                           Chips = p.Chips, LastSeenAt = SYSDATETIME()
                    FROM TexasHoldEm_Public.TexasHoldEm_Identities AS i
                    JOIN @Promoted AS p ON p.PlayerName = i.PlayerName;

                    DELETE TexasHoldEm_Public.TexasHoldEm_Waitlist WHERE WaitId IN (SELECT WaitId FROM @Promoted);

                    INSERT TexasHoldEm_Public.TexasHoldEm_Log (HandNumber, Message)
                    SELECT g.HandNumber, CONCAT(pr.PlayerName, N' is off the waitlist and sits down with ', pr.Chips, N' chips.')
                    FROM @Promoted pr CROSS JOIN TexasHoldEm_Public.TexasHoldEm_Game g;
                END

                IF (SELECT COUNT(*) FROM TexasHoldEm_Public.TexasHoldEm_Players) >= @MaxSeats
                BEGIN
                    /* Full table, but robots don't get to keep a human out. Bump
                       one. Mid-hand a robot has chips in the pot and a row the
                       engine is still reading, so we never delete it out from
                       under a live hand - we flag it to cash out at the end and
                       put the human on the rail for one hand. Between hands
                       there's nothing at stake, so the seat changes hands right
                       now, and execution falls through to the ordinary
                       seat-assignment block below (a chair just opened). */
                    SET @BumpSeat = NULL; SET @BumpName = NULL;
                    SELECT TOP (1) @BumpSeat = SeatNum, @BumpName = PlayerName
                    FROM TexasHoldEm_Public.TexasHoldEm_Players
                    WHERE IsBot = 1 AND WantsToLeave = 0
                    ORDER BY Chips, SeatNum;      /* the shortest stack goes first */

                    IF @BumpSeat IS NOT NULL AND (SELECT GameState FROM TexasHoldEm_Public.TexasHoldEm_Game) = 'InHand'
                    BEGIN
                        UPDATE TexasHoldEm_Public.TexasHoldEm_Players SET WantsToLeave = 1 WHERE SeatNum = @BumpSeat;
                        INSERT TexasHoldEm_Public.TexasHoldEm_Log (HandNumber, Message)
                        SELECT HandNumber, CONCAT(@BumpName, N' is cashing out after this hand to free up a seat for a human.')
                        FROM TexasHoldEm_Public.TexasHoldEm_Game;

                        /* Reserve that exact seat right now - a promise with
                           nothing behind it is just a race. Without this, a
                           different arrival (or an already-waitlisted human)
                           could claim the seat the moment it actually frees. */
                        IF @PlayerName IS NULL
                        BEGIN
                            SET @PlayerName = CONCAT(N'Player ', @@SPID);
                            IF EXISTS (SELECT 1 FROM TexasHoldEm_Public.TexasHoldEm_Players WHERE PlayerName = @PlayerName)
                               OR EXISTS (SELECT 1 FROM TexasHoldEm_Public.TexasHoldEm_Waitlist WHERE PlayerName = @PlayerName)
                               OR EXISTS (SELECT 1 FROM TexasHoldEm_Public.TexasHoldEm_Identities WHERE PlayerName = @PlayerName)
                                SET @PlayerName = CONCAT(N'Player ', @@SPID, N'-',
                                    100 + ABS(CONVERT(bigint, CHECKSUM(NEWID()))) % 900);
                        END
                        ELSE IF EXISTS (SELECT 1 FROM TexasHoldEm_Public.TexasHoldEm_Waitlist WHERE PlayerName = @PlayerName)
                        BEGIN
                            SET @Notice = N'That name''s already on the waitlist. Pick a different one.';
                            SET @ReturnNow = 1;
                        END

                        IF @ReturnNow = 0
                        BEGIN
                            IF @IdentityFound = 0
                            BEGIN
                                SET @SeatSalt = CASE WHEN @SeatPassword IS NOT NULL THEN CONVERT(varbinary(16), NEWID()) END;
                                SET @SeatHash = CASE WHEN @SeatPassword IS NOT NULL
                                     THEN HASHBYTES('SHA2_256', @SeatSalt + CONVERT(varbinary(100), @SeatPassword)) END;
                                SET @JoinChips = @StartingChips;
                            END

                            INSERT TexasHoldEm_Public.TexasHoldEm_Waitlist (PlayerName, SessionId, SessionLoginTime,
                                                             PasswordSalt, PasswordHash, ReservedSeat)
                            VALUES (@PlayerName, @@SPID, @MyLoginTime, @SeatSalt, @SeatHash, @BumpSeat);

                            IF @IdentityFound = 1
                                UPDATE TexasHoldEm_Public.TexasHoldEm_Identities
                                   SET SessionId = @@SPID, SessionLoginTime = @MyLoginTime,
                                       PlayerRole = 'SPECTATOR', WantsSeat = 1,
                                       LastSeenAt = SYSDATETIME()
                                 WHERE IdentityId = @IdentityId;
                            ELSE
                            BEGIN
                                INSERT TexasHoldEm_Public.TexasHoldEm_Identities
                                    (PlayerName, SessionId, SessionLoginTime, PasswordSalt, PasswordHash,
                                     Chips, PlayerRole, WantsSeat, TimedOut)
                                VALUES (@PlayerName, @@SPID, @MyLoginTime, @SeatSalt, @SeatHash,
                                        @JoinChips, 'SPECTATOR', 1, 0);
                                SET @IdentityId = SCOPE_IDENTITY(); SET @IdentityFound = 1;
                            END
                            SET @IdentityRole = 'SPECTATOR'; SET @IdentityChips = @JoinChips;

                            SET @IsObserver = 1;
                            SET @Notice = CONCAT(@BumpName, N' is giving up their seat for you at the end of this hand - it''s reserved. Watching from the rail until then - run EXEC sp_TexasHoldEm_Public again to sit down.');
                        END
                    END
                    ELSE IF @BumpSeat IS NOT NULL
                    BEGIN
                        INSERT TexasHoldEm_Public.TexasHoldEm_Log (HandNumber, Message)
                        SELECT HandNumber, CONCAT(@BumpName, N' gives up a seat to a human and heads for the bar.')
                        FROM TexasHoldEm_Public.TexasHoldEm_Game;
                        DELETE TexasHoldEm_Public.TexasHoldEm_Players WHERE SeatNum = @BumpSeat;
                    END
                    ELSE
                    BEGIN
                        /* No robot to bump: the table's full of humans. Queue up
                           instead of turning you away outright - up to
                           @MaxWaitlist more humans can wait for the next chair. */
                        SELECT @WaitPos = COUNT(*) FROM TexasHoldEm_Public.TexasHoldEm_Waitlist;
                        IF @WaitPos >= @MaxWaitlist
                        BEGIN
                            SET @IsObserver = 1;
                            SET @Notice = CONCAT(N'The table (', @MaxSeats, N' seats) and the waitlist (', @MaxWaitlist,
                                N' spots) are both full - ', @MaxHumans, N' humans are already in this game. Watching from the rail.');
                        END
                        ELSE
                        BEGIN
                            IF @PlayerName IS NULL
                            BEGIN
                                SET @PlayerName = CONCAT(N'Player ', @@SPID);
                                IF EXISTS (SELECT 1 FROM TexasHoldEm_Public.TexasHoldEm_Players WHERE PlayerName = @PlayerName)
                                   OR EXISTS (SELECT 1 FROM TexasHoldEm_Public.TexasHoldEm_Waitlist WHERE PlayerName = @PlayerName)
                                   OR EXISTS (SELECT 1 FROM TexasHoldEm_Public.TexasHoldEm_Identities WHERE PlayerName = @PlayerName)
                                    SET @PlayerName = CONCAT(N'Player ', @@SPID, N'-',
                                        100 + ABS(CONVERT(bigint, CHECKSUM(NEWID()))) % 900);
                            END
                            ELSE IF EXISTS (SELECT 1 FROM TexasHoldEm_Public.TexasHoldEm_Waitlist WHERE PlayerName = @PlayerName)
                            BEGIN
                                SET @Notice = N'That name''s already on the waitlist. Pick a different one.';
                                SET @ReturnNow = 1;
                            END

                            IF @ReturnNow = 0
                            BEGIN
                                IF @IdentityFound = 0
                                BEGIN
                                    SET @SeatSalt = CASE WHEN @SeatPassword IS NOT NULL THEN CONVERT(varbinary(16), NEWID()) END;
                                    SET @SeatHash = CASE WHEN @SeatPassword IS NOT NULL
                                         THEN HASHBYTES('SHA2_256', @SeatSalt + CONVERT(varbinary(100), @SeatPassword)) END;
                                    SET @JoinChips = @StartingChips;
                                END

                                INSERT TexasHoldEm_Public.TexasHoldEm_Waitlist (PlayerName, SessionId, SessionLoginTime, PasswordSalt, PasswordHash)
                                VALUES (@PlayerName, @@SPID, @MyLoginTime, @SeatSalt, @SeatHash);
                                SET @WaitId = SCOPE_IDENTITY();

                                IF @IdentityFound = 1
                                    UPDATE TexasHoldEm_Public.TexasHoldEm_Identities
                                       SET SessionId = @@SPID, SessionLoginTime = @MyLoginTime,
                                           PlayerRole = 'SPECTATOR', WantsSeat = 1,
                                           LastSeenAt = SYSDATETIME()
                                     WHERE IdentityId = @IdentityId;
                                ELSE
                                BEGIN
                                    INSERT TexasHoldEm_Public.TexasHoldEm_Identities
                                        (PlayerName, SessionId, SessionLoginTime, PasswordSalt, PasswordHash,
                                         Chips, PlayerRole, WantsSeat, TimedOut)
                                    VALUES (@PlayerName, @@SPID, @MyLoginTime, @SeatSalt, @SeatHash,
                                            @JoinChips, 'SPECTATOR', 1, 0);
                                    SET @IdentityId = SCOPE_IDENTITY(); SET @IdentityFound = 1;
                                END
                                SET @IdentityRole = 'SPECTATOR'; SET @IdentityChips = @JoinChips;

                                SELECT @WaitPos = COUNT(*) FROM TexasHoldEm_Public.TexasHoldEm_Waitlist WHERE WaitId <= @WaitId;
                                SET @Notice = CONCAT(N'The table''s full. You''re #', @WaitPos, N' on the waitlist',
                                    CASE WHEN @SeatHash IS NOT NULL THEN N' (protected with your @SeatPassword). ' ELSE N'. ' END,
                                    N'Run EXEC sp_TexasHoldEm_Public again in a bit to check for an open seat.');
                                SET @ReturnNow = 1;
                            END
                        END
                    END
                END

                IF @MySeat IS NULL AND @IsObserver = 0 AND @ReturnNow = 0
                BEGIN
                    /* A chair's actually open right now - either it always was,
                       or a robot just gave one up above. */
                    IF @PlayerName IS NULL
                    BEGIN
                        SET @PlayerName = CONCAT(N'Player ', @@SPID);
                        /* Session ids recycle, so "Player 57" may already be
                           seated or waiting. Don't collide with them. */
                        IF EXISTS (SELECT 1 FROM TexasHoldEm_Public.TexasHoldEm_Players WHERE PlayerName = @PlayerName)
                           OR EXISTS (SELECT 1 FROM TexasHoldEm_Public.TexasHoldEm_Waitlist WHERE PlayerName = @PlayerName)
                           OR EXISTS (SELECT 1 FROM TexasHoldEm_Public.TexasHoldEm_Identities WHERE PlayerName = @PlayerName)
                            SET @PlayerName = CONCAT(N'Player ', @@SPID, N'-',
                                100 + ABS(CONVERT(bigint, CHECKSUM(NEWID()))) % 900);
                    END
                    ELSE IF EXISTS (SELECT 1 FROM TexasHoldEm_Public.TexasHoldEm_Waitlist WHERE PlayerName = @PlayerName)
                    BEGIN
                        SET @Notice = N'That name''s on the waitlist. Pick a different one, or wait your turn.';
                        SET @ReturnNow = 1;
                    END

                    IF @ReturnNow = 0
                    BEGIN
                        SELECT TOP (1) @MySeat = v.SeatNum
                        FROM (VALUES (1),(2),(3),(4)) v(SeatNum)
                        WHERE NOT EXISTS (SELECT 1 FROM TexasHoldEm_Public.TexasHoldEm_Players p WHERE p.SeatNum = v.SeatNum)
                        ORDER BY v.SeatNum;

                        IF @IdentityFound = 0
                        BEGIN
                            SET @SeatSalt = CASE WHEN @SeatPassword IS NOT NULL THEN CONVERT(varbinary(16), NEWID()) END;
                            SET @SeatHash = CASE WHEN @SeatPassword IS NOT NULL
                                 THEN HASHBYTES('SHA2_256', @SeatSalt + CONVERT(varbinary(100), @SeatPassword)) END;
                            SET @JoinChips = @StartingChips;
                        END

                        INSERT TexasHoldEm_Public.TexasHoldEm_Players (SeatNum, PlayerName, SessionId, SessionLoginTime,
                                                        PasswordSalt, PasswordHash, IsBot, Chips)
                        VALUES (@MySeat, @PlayerName, @@SPID, @MyLoginTime, @SeatSalt, @SeatHash, 0, @JoinChips);

                        IF @IdentityFound = 1
                            UPDATE TexasHoldEm_Public.TexasHoldEm_Identities
                               SET SessionId = @@SPID, SessionLoginTime = @MyLoginTime,
                                   PlayerRole = 'PLAYER', WantsSeat = 0, TimedOut = 0,
                                   Chips = @JoinChips, LastSeenAt = SYSDATETIME()
                             WHERE IdentityId = @IdentityId;
                        ELSE
                        BEGIN
                            INSERT TexasHoldEm_Public.TexasHoldEm_Identities
                                (PlayerName, SessionId, SessionLoginTime, PasswordSalt, PasswordHash,
                                 Chips, PlayerRole, WantsSeat, TimedOut)
                            VALUES (@PlayerName, @@SPID, @MyLoginTime, @SeatSalt, @SeatHash,
                                    @JoinChips, 'PLAYER', 0, 0);
                            SET @IdentityId = SCOPE_IDENTITY(); SET @IdentityFound = 1;
                        END
                        SET @IdentityRole = 'PLAYER'; SET @IdentityChips = @JoinChips;

                        /* If the waiting table had emptied out, this player is
                           opening a fresh lobby and should get the full join
                           window. */
                        IF (SELECT COUNT(*) FROM TexasHoldEm_Public.TexasHoldEm_Players) = 1
                           AND (SELECT GameState FROM TexasHoldEm_Public.TexasHoldEm_Game) = 'WaitingForPlayers'
                            UPDATE TexasHoldEm_Public.TexasHoldEm_Game
                               SET JoinWindowEndsAt = DATEADD(second, @JoinWindowSeconds, SYSDATETIME());

                        INSERT TexasHoldEm_Public.TexasHoldEm_Log (HandNumber, Message)
                        SELECT HandNumber,
                               CASE WHEN GameState = 'WaitingForPlayers'
                                    THEN CONCAT(@PlayerName, N' joins the game with ', @JoinChips, N' chips.')
                                    ELSE CONCAT(@PlayerName, N' sits down with ', @JoinChips,
                                         N' chips and will be dealt into the next hand.') END
                        FROM TexasHoldEm_Public.TexasHoldEm_Game;

                        SET @Notice = CASE WHEN @SeatHash IS NOT NULL
                             THEN N'Seat protected. If you lose this session, reconnect from any window with your @PlayerName and @SeatPassword.'
                             ELSE N'Heads up: you joined without a @SeatPassword, so if this session dies, your seat (and chips) can''t be reclaimed.' END;
                    END
                END
            END
        END

        /* Apply a betting action. */
        IF @MySeat IS NOT NULL AND @Action IN (N'Check', N'Call', N'Bet', N'Raise', N'AllIn', N'Fold')
        BEGIN
            SELECT @GState = GameState, @TurnSeat = TurnSeat, @BetToCall = BetToCall,
                   @RaiseCount = RaiseCount, @Round = BettingRound, @GHand = HandNumber
            FROM TexasHoldEm_Public.TexasHoldEm_Game;
            SELECT @MyBet = BetThisRound, @MyChips = Chips, @MyNeedsToAct = NeedsToAct, @MyFolded = Folded
            FROM TexasHoldEm_Public.TexasHoldEm_Players WHERE SeatNum = @MySeat;

            IF @GState <> 'InHand' OR @TurnSeat <> @MySeat OR ISNULL(@MyNeedsToAct, 0) = 0 OR @MyFolded = 1
            BEGIN
                SET @Notice = N'It''s not your turn right now (maybe the shot clock got you?). Hang tight.';
                /* Remember WHICH action bounced. This session doesn't return
                   yet - it keeps waiting - and the table can hand the turn
                   back before it does, at which point this notice is a lie.
                   See the rewrite just past the wait loop. */
                SET @MissedAction = @Action;
            END
            ELSE
            BEGIN
                SET @Owed = @BetToCall - @MyBet;
                SET @Unit = CASE WHEN @Round <= 1 THEN @SmallBet ELSE @BigBet END;
                SET @NewBet = CASE WHEN @BetToCall = 0 THEN @Unit ELSE @BetToCall + @Unit END;

                IF @Action = N'Check' AND @Owed > 0
                BEGIN
                    SET @Notice = CONCAT(N'You can''t check - it costs ', @Owed, N' to call.');
                    SET @ReturnNow = 1;
                END
                ELSE IF @Action IN (N'Bet', N'Raise') AND @RaiseCount >= @MaxRaises
                BEGIN
                    SET @Notice = N'Betting''s capped this round - you can Call, go AllIn, or Fold.';
                    SET @ReturnNow = 1;
                END
                ELSE IF @Action IN (N'Bet', N'Raise') AND @MyChips < (@NewBet - @MyBet)
                BEGIN
                    SET @Notice = N'Not enough chips to raise. You can Call, go AllIn, or Fold.';
                    SET @ReturnNow = 1;
                END
                ELSE IF @Action = N'AllIn' AND @MyChips <= 0
                BEGIN
                    SET @Notice = N'You''re already all in. Enjoy the ride.';
                    SET @ReturnNow = 1;
                END
                ELSE
                BEGIN
                    IF @Action = N'Fold'
                    BEGIN
                        UPDATE TexasHoldEm_Public.TexasHoldEm_Players SET Folded = 1, NeedsToAct = 0, TimeoutStrikes = 0
                         WHERE SeatNum = @MySeat;
                        INSERT TexasHoldEm_Public.TexasHoldEm_Log (HandNumber, Message) VALUES (@GHand, CONCAT(@PlayerName, N' folds.'));
                    END
                    ELSE IF @Action = N'Check' OR (@Action = N'Call' AND @Owed <= 0)
                    BEGIN
                        UPDATE TexasHoldEm_Public.TexasHoldEm_Players SET NeedsToAct = 0, TimeoutStrikes = 0
                         WHERE SeatNum = @MySeat;
                        INSERT TexasHoldEm_Public.TexasHoldEm_Log (HandNumber, Message) VALUES (@GHand, CONCAT(@PlayerName, N' checks.'));
                    END
                    ELSE IF @Action = N'Call'
                    BEGIN
                        SET @Pay = CASE WHEN @MyChips < @Owed THEN @MyChips ELSE @Owed END;
                        UPDATE TexasHoldEm_Public.TexasHoldEm_Players
                           SET Chips = Chips - @Pay, BetThisRound = BetThisRound + @Pay,
                               AllIn = CASE WHEN @MyChips <= @Owed THEN 1 ELSE 0 END,
                               NeedsToAct = 0, TimeoutStrikes = 0
                         WHERE SeatNum = @MySeat;
                        INSERT TexasHoldEm_Public.TexasHoldEm_Log (HandNumber, Message)
                        VALUES (@GHand, CONCAT(@PlayerName, N' calls ', @Pay,
                                CASE WHEN @MyChips <= @Owed THEN N' and is ALL IN.' ELSE N'.' END));
                    END
                    ELSE IF @Action = N'AllIn'
                    BEGIN
                        SET @Pay = @MyChips;
                        SET @AllInTo = @MyBet + @Pay;   /* total wager this round */
                        UPDATE TexasHoldEm_Public.TexasHoldEm_Players
                           SET Chips = 0, BetThisRound = @AllInTo, AllIn = 1,
                               NeedsToAct = 0, TimeoutStrikes = 0
                         WHERE SeatNum = @MySeat;
                        /* A shove that beats the current bet puts everyone back to work.
                           Real poker wouldn't reopen betting for an undersized raise;
                           this table isn't that fussy, and it ignores the raise cap too. */
                        IF @AllInTo > @BetToCall
                        BEGIN
                            UPDATE TexasHoldEm_Public.TexasHoldEm_Players SET NeedsToAct = 1
                             WHERE InHand = 1 AND Folded = 0 AND AllIn = 0 AND SeatNum <> @MySeat;
                            UPDATE TexasHoldEm_Public.TexasHoldEm_Game SET BetToCall = @AllInTo, RaiseCount = RaiseCount + 1;
                        END
                        INSERT TexasHoldEm_Public.TexasHoldEm_Log (HandNumber, Message)
                        VALUES (@GHand, CASE
                                WHEN @AllInTo > @BetToCall
                                    THEN CONCAT(@PlayerName, N' moves ALL IN for ', @Pay, N'. It''s ', @AllInTo, N' to call.')
                                WHEN @AllInTo = @BetToCall
                                    THEN CONCAT(@PlayerName, N' calls ALL IN for ', @Pay, N'.')
                                ELSE CONCAT(@PlayerName, N' calls ALL IN for ', @Pay,
                                            N', which doesn''t cover the ', @BetToCall, N'.') END);
                    END
                    ELSE /* Bet / Raise */
                    BEGIN
                        SET @Pay = @NewBet - @MyBet;
                        UPDATE TexasHoldEm_Public.TexasHoldEm_Players
                           SET Chips = Chips - @Pay, BetThisRound = @NewBet,
                               AllIn = CASE WHEN @MyChips = @Pay THEN 1 ELSE 0 END,
                               NeedsToAct = 0, TimeoutStrikes = 0
                         WHERE SeatNum = @MySeat;
                        UPDATE TexasHoldEm_Public.TexasHoldEm_Players SET NeedsToAct = 1
                         WHERE InHand = 1 AND Folded = 0 AND AllIn = 0 AND SeatNum <> @MySeat;
                        UPDATE TexasHoldEm_Public.TexasHoldEm_Game SET BetToCall = @NewBet, RaiseCount = RaiseCount + 1;
                        INSERT TexasHoldEm_Public.TexasHoldEm_Log (HandNumber, Message)
                        VALUES (@GHand, CONCAT(@PlayerName,
                                CASE WHEN @BetToCall = 0 THEN N' bets ' ELSE N' raises to ' END, @NewBet, N'.'));
                    END

                    SET @NextSeat = NULL;
                    SELECT TOP (1) @NextSeat = SeatNum FROM TexasHoldEm_Public.TexasHoldEm_Players
                     WHERE InHand = 1 AND Folded = 0 AND AllIn = 0 AND NeedsToAct = 1
                     ORDER BY CASE WHEN SeatNum > @MySeat THEN 0 ELSE 1 END, SeatNum;
                    UPDATE TexasHoldEm_Public.TexasHoldEm_Game SET TurnSeat = @NextSeat, TurnStartedAt = SYSDATETIME();
                END
            END
        END

        /* Cash out. Skipped if @ReturnNow is already 1 - a waitlisted Leave
           was just handled above, and this generic "you weren't seated"
           branch would otherwise stomp that notice right back off. */
        IF @Action = N'Leave' AND @ReturnNow = 0
        BEGIN
            IF @MySeat IS NULL
                SET @Notice = N'You weren''t seated anyway. Easiest fold of your life.';
            ELSE
            BEGIN
                SELECT @GState = GameState, @GHand = HandNumber, @TurnSeat = TurnSeat FROM TexasHoldEm_Public.TexasHoldEm_Game;
                SELECT @MyInHand = InHand, @MyFolded = Folded FROM TexasHoldEm_Public.TexasHoldEm_Players WHERE SeatNum = @MySeat;

                IF @GState = 'InHand' AND @MyInHand = 1 AND @MyFolded = 0
                BEGIN
                    UPDATE TexasHoldEm_Public.TexasHoldEm_Players SET Folded = 1, NeedsToAct = 0, WantsToLeave = 1
                     WHERE SeatNum = @MySeat;
                    INSERT TexasHoldEm_Public.TexasHoldEm_Log (HandNumber, Message)
                    VALUES (@GHand, CONCAT(@PlayerName, N' folds and is cashing out after this hand.'));
                    IF @TurnSeat = @MySeat
                    BEGIN
                        SET @NextSeat = NULL;
                        SELECT TOP (1) @NextSeat = SeatNum FROM TexasHoldEm_Public.TexasHoldEm_Players
                         WHERE InHand = 1 AND Folded = 0 AND AllIn = 0 AND NeedsToAct = 1
                         ORDER BY CASE WHEN SeatNum > @MySeat THEN 0 ELSE 1 END, SeatNum;
                        UPDATE TexasHoldEm_Public.TexasHoldEm_Game SET TurnSeat = @NextSeat, TurnStartedAt = SYSDATETIME();
                    END
                    SET @Notice = N'You''ve folded. Your chips leave the table with you when this hand ends.';
                END
                ELSE IF @GState = 'InHand' AND @MyInHand = 1 AND @MyFolded = 1
                BEGIN
                    UPDATE TexasHoldEm_Public.TexasHoldEm_Players SET WantsToLeave = 1 WHERE SeatNum = @MySeat;
                    SET @Notice = N'You''ll be removed when this hand ends. Thanks for playing!';
                END
                ELSE
                BEGIN
                    INSERT TexasHoldEm_Public.TexasHoldEm_Log (HandNumber, Message)
                    SELECT @GHand, CONCAT(@PlayerName, N' leaves the table with ', Chips, N' chips.')
                    FROM TexasHoldEm_Public.TexasHoldEm_Players WHERE SeatNum = @MySeat;
                    UPDATE i
                       SET Chips = p.Chips, PlayerRole = 'SPECTATOR', WantsSeat = 0,
                           TimedOut = 0, LastSeenAt = SYSDATETIME(),
                           LastPlayedHand = p.LastPlayedHand,
                           LastViewedHand = p.LastViewedHand
                    FROM TexasHoldEm_Public.TexasHoldEm_Identities AS i
                    JOIN TexasHoldEm_Public.TexasHoldEm_Players AS p
                      ON p.PlayerName = i.PlayerName
                    WHERE p.SeatNum = @MySeat AND p.IsBot = 0;
                    DELETE TexasHoldEm_Public.TexasHoldEm_Players WHERE SeatNum = @MySeat;
                    SET @IdentityRole = 'SPECTATOR';
                    SET @Notice = N'You''ve left the table. Thanks for playing!';
                END
                SET @LeftTable = 1;
            END
            SET @ReturnNow = 1;
        END

        /* Which hand am I waiting to see finish? */
        SELECT @GState = GameState, @GHand = HandNumber FROM TexasHoldEm_Public.TexasHoldEm_Game;
        SET @TargetHand = CASE WHEN @GState IN ('InHand', 'BetweenHands') THEN @GHand ELSE @GHand + 1 END;
    END /* first pass */

    /* ================================================================
       THE ENGINE. Any session holding the lock advances everything that
       is ready to advance: the join clock, robot decisions, human shot
       clocks, streets, showdowns, and the next hand. Runs until the game
       is waiting on a live human (or the join clock).
       ================================================================ */
    SET @Spins = 0;
    WHILE @Spins < 200 AND @SkipEngine = 0
    BEGIN
        SET @Spins += 1;
        SET @StartHandNow = 0;
        SET @HandDone = 0;

        SELECT @GState = GameState, @GHand = HandNumber, @Dealer = DealerSeat,
               @SBSeat = SmallBlindSeat, @BBSeat = BigBlindSeat,
               @Round = BettingRound, @BoardShown = BoardShown, @Pot = Pot,
               @BetToCall = BetToCall, @RaiseCount = RaiseCount,
               @TurnSeat = TurnSeat, @TurnStartedAt = TurnStartedAt,
               @JoinEnds = JoinWindowEndsAt, @NextHandAt = NextHandStartsAt,
               @B1 = Board1, @B2 = Board2, @B3 = Board3, @B4 = Board4, @B5 = Board5
        FROM TexasHoldEm_Public.TexasHoldEm_Game;

        IF @GState = 'GameOver' BREAK;

        IF @GState = 'WaitingForPlayers'
        BEGIN
            SELECT @NumPlayers = COUNT(*) FROM TexasHoldEm_Public.TexasHoldEm_Players;
            IF @NumPlayers = 0 AND NOT EXISTS (SELECT 1 FROM TexasHoldEm_Public.TexasHoldEm_Waitlist) BREAK;
            IF SYSDATETIME() < @JoinEnds AND @NumPlayers < @MaxSeats BREAK;
            SET @StartHandNow = 1;
        END

        IF @GState = 'BetweenHands'
        BEGIN
            SELECT @UnviewedHumans = COUNT(*)
            FROM TexasHoldEm_Public.TexasHoldEm_Players
            WHERE IsBot = 0
              AND LastPlayedHand = @GHand
              AND LastViewedHand < @GHand;

            SELECT @ReturningHumans = COUNT(*)
            FROM TexasHoldEm_Public.TexasHoldEm_Identities
            WHERE PlayerRole = 'SPECTATOR' AND TimedOut = 1 AND Chips > 0
              AND LastPlayedHand = @GHand AND LastViewedHand < @GHand;
            SET @UnviewedHumans += @ReturningHumans;

            /* Whoever just lost their last chip has no seat row to be counted
               in - the bust cleanup deleted it - so without this they can't
               hold the table open long enough to be told they busted. That is
               not hypothetical: bust the last seated human while somebody is
               on the waitlist and the game stays alive, nobody is "unviewed",
               and the next hand is dealt in this same invocation, before the
               busted player's session ever renders the hand they lost. */
            SELECT @BustedHumans = COUNT(*)
            FROM TexasHoldEm_Public.TexasHoldEm_Identities
            WHERE PlayerRole = 'OUT'
              AND LastPlayedHand = @GHand AND LastViewedHand < @GHand;
            SET @UnviewedHumans += @BustedHumans;

            /* Keep the completed table and showdown transcript available
               until every still-relevant human participant has received it,
               but never let a disconnected player block beyond the deadline.
               A busted player who never comes back to look is covered by the
               same deadline as a disconnected one. */
            IF @UnviewedHumans > 0 AND SYSDATETIME() < @NextHandAt BREAK;
            SET @StartHandNow = 1;
        END

        IF @StartHandNow = 1
        BEGIN
            /* Before every hand (not just the first one): honor any seat
               reservations first (a robot got bumped mid-hand and promised
               its chair to a specific human - see the bump branch above),
               then pull whoever's waited longest in the general FIFO line
               into whatever's still empty, then fill the rest with robots
               so the table always plays full. Robots are seat-warmers, not
               regulars - the next human to walk up takes a robot's chair
               instead of going to the rail. */
            DELETE @Promoted;
            INSERT @Promoted (WaitId, SeatNum, PlayerName, SessionId, SessionLoginTime, PasswordSalt, PasswordHash, Chips)
            SELECT w.WaitId, w.ReservedSeat, w.PlayerName, w.SessionId, w.SessionLoginTime,
                   w.PasswordSalt, w.PasswordHash, ISNULL(i.Chips, @StartingChips)
            FROM TexasHoldEm_Public.TexasHoldEm_Waitlist w
            LEFT JOIN TexasHoldEm_Public.TexasHoldEm_Identities i ON i.PlayerName = w.PlayerName
            WHERE w.ReservedSeat IS NOT NULL
              AND NOT EXISTS (SELECT 1 FROM TexasHoldEm_Public.TexasHoldEm_Players p WHERE p.SeatNum = w.ReservedSeat);

            ;WITH freeseats AS (
                SELECT v.SeatNum, rn = ROW_NUMBER() OVER (ORDER BY v.SeatNum)
                FROM (VALUES (1),(2),(3),(4)) v(SeatNum)
                WHERE NOT EXISTS (SELECT 1 FROM TexasHoldEm_Public.TexasHoldEm_Players p WHERE p.SeatNum = v.SeatNum)
                  AND NOT EXISTS (SELECT 1 FROM @Promoted pr WHERE pr.SeatNum = v.SeatNum)),
            waiters AS (
                SELECT w.WaitId, w.PlayerName, w.SessionId, w.SessionLoginTime, w.PasswordSalt, w.PasswordHash,
                       Chips = ISNULL(i.Chips, @StartingChips),
                       rn = ROW_NUMBER() OVER (ORDER BY w.WaitId)
                FROM TexasHoldEm_Public.TexasHoldEm_Waitlist w
                LEFT JOIN TexasHoldEm_Public.TexasHoldEm_Identities i ON i.PlayerName = w.PlayerName
                WHERE w.ReservedSeat IS NULL)   /* reserved rows are handled above, on their own seat only */
            INSERT @Promoted (WaitId, SeatNum, PlayerName, SessionId, SessionLoginTime, PasswordSalt, PasswordHash, Chips)
            SELECT w.WaitId, f.SeatNum, w.PlayerName, w.SessionId, w.SessionLoginTime,
                   w.PasswordSalt, w.PasswordHash, w.Chips
            FROM freeseats f JOIN waiters w ON w.rn = f.rn;

            IF EXISTS (SELECT 1 FROM @Promoted)
            BEGIN
                INSERT TexasHoldEm_Public.TexasHoldEm_Players (SeatNum, PlayerName, SessionId, SessionLoginTime,
                                                PasswordSalt, PasswordHash, IsBot, Chips)
                SELECT SeatNum, PlayerName, SessionId, SessionLoginTime, PasswordSalt, PasswordHash, 0, Chips
                FROM @Promoted;

                UPDATE i
                   SET PlayerRole = 'PLAYER', WantsSeat = 0, TimedOut = 0,
                       SessionId = p.SessionId, SessionLoginTime = p.SessionLoginTime,
                       Chips = p.Chips, LastSeenAt = SYSDATETIME()
                FROM TexasHoldEm_Public.TexasHoldEm_Identities AS i
                JOIN @Promoted AS p ON p.PlayerName = i.PlayerName;

                DELETE TexasHoldEm_Public.TexasHoldEm_Waitlist WHERE WaitId IN (SELECT WaitId FROM @Promoted);

                INSERT TexasHoldEm_Public.TexasHoldEm_Log (HandNumber, Message)
                SELECT @GHand, CONCAT(PlayerName, N' is off the waitlist and sits down with ', Chips, N' chips.')
                FROM @Promoted;
            END

            ;WITH freeseats AS (
                SELECT v.SeatNum, rn = ROW_NUMBER() OVER (ORDER BY v.SeatNum)
                FROM (VALUES (1),(2),(3),(4)) v(SeatNum)
                WHERE NOT EXISTS (SELECT 1 FROM TexasHoldEm_Public.TexasHoldEm_Players p WHERE p.SeatNum = v.SeatNum)),
            bots AS (
                /* Rank only the bot names that AREN'T already at the table.
                   Robots bust one at a time far more often than all at once,
                   so ranking all three unconditionally hands the first free
                   seat to 'Clippy' even when Clippy is still sitting there -
                   a PlayerName UNIQUE violation that isn't caught anywhere
                   and aborts the call for every player at the table, not
                   just the one who triggered the deal. */
                SELECT b.BotName, rn = ROW_NUMBER() OVER (ORDER BY b.SortOrder)
                FROM (VALUES (1, N'Clippy'), (2, N'HAL'), (3, N'Bender')) b(SortOrder, BotName)
                WHERE NOT EXISTS (SELECT 1 FROM TexasHoldEm_Public.TexasHoldEm_Players p
                                   WHERE p.PlayerName = b.BotName))
            INSERT TexasHoldEm_Public.TexasHoldEm_Players (SeatNum, PlayerName, SessionId, IsBot, Chips)
            SELECT f.SeatNum, b.BotName, 0, 1, @StartingChips
            FROM freeseats f JOIN bots b ON b.rn = f.rn;
            SET @BotsAdded = @@ROWCOUNT;

            IF @BotsAdded > 0
            BEGIN
                SET @Msg = NULL;
                SELECT @Msg = STRING_AGG(PlayerName, N', ') WITHIN GROUP (ORDER BY SeatNum)
                FROM TexasHoldEm_Public.TexasHoldEm_Players WHERE IsBot = 1;
                IF @Msg IS NOT NULL
                    INSERT TexasHoldEm_Public.TexasHoldEm_Log (HandNumber, Message)
                    VALUES (@GHand, CONCAT(N'Filling the empty seats with robots: ', @Msg,
                            N'. They''ll give up a chair when a human wants one. Good luck.'));
            END

            /* ===== Start a new hand: button, blinds, shuffle, deal. ===== */
            SET @PrevDealer = ISNULL(@Dealer, 0);
            SET @GHand += 1;

            UPDATE TexasHoldEm_Public.TexasHoldEm_Players
               SET InHand = CASE WHEN Chips > 0 THEN 1 ELSE 0 END,
                   Folded = 0, AllIn = 0, BetThisRound = 0, NeedsToAct = 0,
                   HoleCardsEncrypted = NULL,
                   LastPlayedHand = CASE WHEN IsBot = 0 AND Chips > 0 THEN @GHand ELSE LastPlayedHand END;

            SELECT @NumInHand = COUNT(*) FROM TexasHoldEm_Public.TexasHoldEm_Players WHERE InHand = 1;
            IF @NumInHand < 2
            BEGIN
                UPDATE TexasHoldEm_Public.TexasHoldEm_Game SET GameState = 'GameOver', HandNumber = @GHand, TurnSeat = NULL;
                INSERT TexasHoldEm_Public.TexasHoldEm_Log (HandNumber, Message) VALUES (@GHand, N'Not enough players to deal. GAME OVER.');
                CONTINUE;
            END

            SET @Dealer = NULL;
            SELECT TOP (1) @Dealer = SeatNum FROM TexasHoldEm_Public.TexasHoldEm_Players WHERE InHand = 1
             ORDER BY CASE WHEN SeatNum > @PrevDealer THEN 0 ELSE 1 END, SeatNum;

            IF @NumInHand = 2
            BEGIN
                /* Heads-up: the dealer posts the small blind and acts first pre-flop. */
                SET @SBSeat = @Dealer;
                SET @BBSeat = NULL;
                SELECT TOP (1) @BBSeat = SeatNum FROM TexasHoldEm_Public.TexasHoldEm_Players
                 WHERE InHand = 1 AND SeatNum <> @Dealer;
            END
            ELSE
            BEGIN
                SET @SBSeat = NULL;
                SELECT TOP (1) @SBSeat = SeatNum FROM TexasHoldEm_Public.TexasHoldEm_Players WHERE InHand = 1 AND SeatNum <> @Dealer
                 ORDER BY CASE WHEN SeatNum > @Dealer THEN 0 ELSE 1 END, SeatNum;
                SET @BBSeat = NULL;
                SELECT TOP (1) @BBSeat = SeatNum FROM TexasHoldEm_Public.TexasHoldEm_Players WHERE InHand = 1 AND SeatNum <> @SBSeat
                 ORDER BY CASE WHEN SeatNum > @SBSeat THEN 0 ELSE 1 END, SeatNum;
            END

            DELETE @Shuffled;
            INSERT @Shuffled (Pos, CardId)
            SELECT ROW_NUMBER() OVER (ORDER BY NEWID()), CardId FROM #Poker_Cards;

            ;WITH p AS (SELECT SeatNum, HoleCardsEncrypted, rn = ROW_NUMBER() OVER (ORDER BY SeatNum)
                        FROM TexasHoldEm_Public.TexasHoldEm_Players WHERE InHand = 1)
            UPDATE p SET HoleCardsEncrypted = EncryptByCert
                (
                    CERT_ID(N'sp_TexasHoldEm_CardProtection_Claude'),
                    CONVERT(varbinary(1), s1.CardId) + CONVERT(varbinary(1), s2.CardId)
                )
            FROM p
            JOIN @Shuffled AS s1 ON s1.Pos = p.rn
            JOIN @Shuffled AS s2 ON s2.Pos = p.rn + @NumInHand;

            UPDATE g SET Board1 = b1.CardId, Board2 = b2.CardId, Board3 = b3.CardId,
                         Board4 = b4.CardId, Board5 = b5.CardId
            FROM TexasHoldEm_Public.TexasHoldEm_Game g
            JOIN @Shuffled AS b1 ON b1.Pos = @NumInHand * 2 + 1
            JOIN @Shuffled AS b2 ON b2.Pos = @NumInHand * 2 + 2
            JOIN @Shuffled AS b3 ON b3.Pos = @NumInHand * 2 + 3
            JOIN @Shuffled AS b4 ON b4.Pos = @NumInHand * 2 + 4
            JOIN @Shuffled AS b5 ON b5.Pos = @NumInHand * 2 + 5;

            UPDATE TexasHoldEm_Public.TexasHoldEm_Players
               SET BetThisRound = CASE WHEN Chips < @SmallBlind THEN Chips ELSE @SmallBlind END,
                   AllIn = CASE WHEN Chips <= @SmallBlind THEN 1 ELSE 0 END,
                   Chips = CASE WHEN Chips < @SmallBlind THEN 0 ELSE Chips - @SmallBlind END
             WHERE SeatNum = @SBSeat;

            UPDATE TexasHoldEm_Public.TexasHoldEm_Players
               SET BetThisRound = CASE WHEN Chips < @BigBlind THEN Chips ELSE @BigBlind END,
                   AllIn = CASE WHEN Chips <= @BigBlind THEN 1 ELSE 0 END,
                   Chips = CASE WHEN Chips < @BigBlind THEN 0 ELSE Chips - @BigBlind END
             WHERE SeatNum = @BBSeat;

            UPDATE TexasHoldEm_Public.TexasHoldEm_Players SET NeedsToAct = 1 WHERE InHand = 1 AND AllIn = 0;

            SET @NextSeat = NULL;
            SELECT TOP (1) @NextSeat = SeatNum FROM TexasHoldEm_Public.TexasHoldEm_Players
             WHERE InHand = 1 AND Folded = 0 AND AllIn = 0 AND NeedsToAct = 1
             ORDER BY CASE WHEN SeatNum > @BBSeat THEN 0 ELSE 1 END, SeatNum;

            UPDATE TexasHoldEm_Public.TexasHoldEm_Game
               SET GameState = 'InHand', HandNumber = @GHand, DealerSeat = @Dealer,
                   SmallBlindSeat = @SBSeat, BigBlindSeat = @BBSeat,
                   BettingRound = 0, BoardShown = 0, ShowdownShown = 0, Pot = 0,
                   BetToCall = @BigBlind, RaiseCount = 1,
                   TurnSeat = @NextSeat, TurnStartedAt = SYSDATETIME(),
                   JoinWindowEndsAt = NULL, NextHandStartsAt = NULL;

            INSERT TexasHoldEm_Public.TexasHoldEm_Log (HandNumber, Message)
            SELECT @GHand, CONCAT(N'=== HAND #', @GHand, N' === ', d.PlayerName, N' has the button. ',
                   s.PlayerName, N' posts the small blind (', @SmallBlind, N'), ',
                   b.PlayerName, N' posts the big blind (', @BigBlind, N'). Cards are in the air!')
            FROM TexasHoldEm_Public.TexasHoldEm_Players d
            CROSS JOIN TexasHoldEm_Public.TexasHoldEm_Players s
            CROSS JOIN TexasHoldEm_Public.TexasHoldEm_Players b
            WHERE d.SeatNum = @Dealer AND s.SeatNum = @SBSeat AND b.SeatNum = @BBSeat;

            CONTINUE;
        END

        /* ===== From here down, a hand is in progress. ===== */
        SELECT @Unfolded = COUNT(*) FROM TexasHoldEm_Public.TexasHoldEm_Players WHERE InHand = 1 AND Folded = 0;

        IF @Unfolded <= 1
        BEGIN
            /* Everybody else folded - no showdown, no peeking. */
            SELECT @RoundBets = ISNULL(SUM(BetThisRound), 0) FROM TexasHoldEm_Public.TexasHoldEm_Players WHERE InHand = 1;
            UPDATE TexasHoldEm_Public.TexasHoldEm_Players SET BetThisRound = 0 WHERE InHand = 1;
            SET @Pot += @RoundBets;

            SET @WinSeat = NULL;
            SELECT @WinSeat = SeatNum, @WinName = PlayerName
            FROM TexasHoldEm_Public.TexasHoldEm_Players WHERE InHand = 1 AND Folded = 0;
            UPDATE TexasHoldEm_Public.TexasHoldEm_Players
               SET Chips = Chips + @Pot, LastWonHand = @GHand WHERE SeatNum = @WinSeat;
            INSERT TexasHoldEm_Public.TexasHoldEm_Log (HandNumber, Message)
            VALUES (@GHand, CONCAT(N'Everyone else folded. ', @WinName, N' rakes in ', @Pot, N' chips without showing.'));
            UPDATE TexasHoldEm_Public.TexasHoldEm_Game SET Pot = 0, TurnSeat = NULL;
            SET @HandDone = 1;
        END
        ELSE IF NOT EXISTS (SELECT 1 FROM TexasHoldEm_Public.TexasHoldEm_Players
                            WHERE InHand = 1 AND Folded = 0 AND AllIn = 0 AND NeedsToAct = 1)
        BEGIN
            /* Betting round complete. First, hand back an uncalled bet: if one
               player wagered more this round than anybody else could match -
               the usual way to shove into a shorter stack - the excess is theirs.
               This table has no side pots, so without this the overage would just
               evaporate into a pot they can't win back. */
            SET @TopBet = NULL; SET @NextBet = NULL; SET @RefundSeat = NULL;
            SELECT TOP (1) @RefundSeat = SeatNum, @TopBet = BetThisRound
            FROM TexasHoldEm_Public.TexasHoldEm_Players WHERE InHand = 1 ORDER BY BetThisRound DESC, SeatNum;
            SELECT @NextBet = ISNULL(MAX(BetThisRound), 0)
            FROM TexasHoldEm_Public.TexasHoldEm_Players WHERE InHand = 1 AND SeatNum <> @RefundSeat;
            SET @Refund = ISNULL(@TopBet, 0) - ISNULL(@NextBet, 0);
            IF @Refund > 0
            BEGIN
                UPDATE TexasHoldEm_Public.TexasHoldEm_Players
                   SET Chips = Chips + @Refund, BetThisRound = BetThisRound - @Refund,
                       AllIn = CASE WHEN Chips + @Refund > 0 THEN 0 ELSE AllIn END
                 WHERE SeatNum = @RefundSeat;
                INSERT TexasHoldEm_Public.TexasHoldEm_Log (HandNumber, Message)
                SELECT @GHand, CONCAT(N'Nobody could cover it all, so ', PlayerName, N' takes back ',
                       @Refund, N' in uncalled chips.')
                FROM TexasHoldEm_Public.TexasHoldEm_Players WHERE SeatNum = @RefundSeat;
            END

            /* Now sweep what's left into the pot. */
            SELECT @RoundBets = ISNULL(SUM(BetThisRound), 0) FROM TexasHoldEm_Public.TexasHoldEm_Players WHERE InHand = 1;
            UPDATE TexasHoldEm_Public.TexasHoldEm_Players SET BetThisRound = 0 WHERE InHand = 1;
            SET @Pot += @RoundBets;
            UPDATE TexasHoldEm_Public.TexasHoldEm_Game SET Pot = @Pot, BetToCall = 0, RaiseCount = 0, TurnSeat = NULL;

            IF @Round >= 3
            BEGIN
                /* ===== SHOWDOWN ===== */
                DELETE @ShowResults;
                DECLARE cur_show CURSOR LOCAL FAST_FORWARD FOR
                    SELECT p.SeatNum, p.PlayerName,
                           CONVERT(tinyint, SUBSTRING(h.HoleCards, 1, 1)),
                           CONVERT(tinyint, SUBSTRING(h.HoleCards, 2, 1))
                    FROM TexasHoldEm_Public.TexasHoldEm_Players AS p
                    CROSS APPLY
                    (
                        VALUES
                        (
                            CONVERT(varbinary(2), DecryptByCert
                            (
                                CERT_ID(N'sp_TexasHoldEm_CardProtection_Claude'),
                                p.HoleCardsEncrypted,
                                N'Cl@udeTexasH0ldEm_2026!Cards'
                            ))
                        )
                    ) AS h(HoleCards)
                    WHERE p.InHand = 1 AND p.Folded = 0
                    ORDER BY CASE WHEN SeatNum > @Dealer THEN 0 ELSE 1 END, SeatNum;
                OPEN cur_show;
                FETCH NEXT FROM cur_show INTO @cSeat, @cName, @cC1, @cC2;
                WHILE @@FETCH_STATUS = 0
                BEGIN
                    /* Evaluate the best 5-card hand from these 7 cards. */
                    DELETE @Seven;
                    INSERT @Seven (CardRank, CardSuit)
                    SELECT CardRank, CardSuit FROM #Poker_Cards
                    WHERE CardId IN (@cC1, @cC2, @B1, @B2, @B3, @B4, @B5);

                    SET @FlushSuit = NULL; SET @StraightHigh = NULL; SET @SFHigh = NULL;
                    SET @Quad = NULL; SET @Trip = NULL; SET @Pair1 = NULL; SET @Pair2 = NULL; SET @FHPair = NULL;
                    SET @T1 = 0; SET @T2 = 0; SET @T3 = 0; SET @T4 = 0; SET @T5 = 0;

                    DELETE @RanksT;
                    INSERT @RanksT SELECT DISTINCT CardRank FROM @Seven;
                    IF EXISTS (SELECT 1 FROM @Seven WHERE CardRank = 14) INSERT @RanksT VALUES (1); /* wheel */

                    SELECT TOP (1) @FlushSuit = CardSuit FROM @Seven GROUP BY CardSuit HAVING COUNT(*) >= 5;

                    SELECT @StraightHigh = MAX(h.hi)
                    FROM (VALUES (5),(6),(7),(8),(9),(10),(11),(12),(13),(14)) h(hi)
                    WHERE 5 = (SELECT COUNT(*) FROM @RanksT r WHERE r.CardRank BETWEEN h.hi - 4 AND h.hi);

                    IF @FlushSuit IS NOT NULL
                    BEGIN
                        DELETE @FRanks;
                        INSERT @FRanks SELECT DISTINCT CardRank FROM @Seven WHERE CardSuit = @FlushSuit;
                        IF EXISTS (SELECT 1 FROM @Seven WHERE CardSuit = @FlushSuit AND CardRank = 14)
                            INSERT @FRanks VALUES (1);
                        SELECT @SFHigh = MAX(h.hi)
                        FROM (VALUES (5),(6),(7),(8),(9),(10),(11),(12),(13),(14)) h(hi)
                        WHERE 5 = (SELECT COUNT(*) FROM @FRanks r WHERE r.CardRank BETWEEN h.hi - 4 AND h.hi);
                    END

                    SELECT @Quad  = MAX(CASE WHEN cnt >= 4 THEN CardRank END),
                           @Trip  = MAX(CASE WHEN cnt >= 3 THEN CardRank END),
                           @Pair1 = MAX(CASE WHEN cnt >= 2 THEN CardRank END)
                    FROM (SELECT CardRank, cnt = COUNT(*) FROM @Seven GROUP BY CardRank) x;

                    SELECT @Pair2  = MAX(CASE WHEN cnt >= 2 AND CardRank <> @Pair1 THEN CardRank END),
                           @FHPair = MAX(CASE WHEN cnt >= 2 AND CardRank <> @Trip THEN CardRank END)
                    FROM (SELECT CardRank, cnt = COUNT(*) FROM @Seven GROUP BY CardRank) x;

                    IF @SFHigh IS NOT NULL
                    BEGIN
                        SET @Cat = 8; SET @T1 = @SFHigh;
                        SET @HandName = CASE WHEN @SFHigh = 14 THEN N'a ROYAL FLUSH'
                             ELSE CONCAT(N'a Straight Flush, ',
                                  (SELECT RankName FROM #Poker_RankNames WHERE RankValue = @SFHigh), N' high') END;
                    END
                    ELSE IF @Quad IS NOT NULL
                    BEGIN
                        SET @Cat = 7; SET @T1 = @Quad;
                        SELECT @T2 = MAX(CardRank) FROM @Seven WHERE CardRank <> @Quad;
                        SET @HandName = CONCAT(N'Four of a Kind, ',
                             (SELECT RankPlural FROM #Poker_RankNames WHERE RankValue = @Quad));
                    END
                    ELSE IF @Trip IS NOT NULL AND @FHPair IS NOT NULL
                    BEGIN
                        SET @Cat = 6; SET @T1 = @Trip; SET @T2 = @FHPair;
                        SET @HandName = CONCAT(N'a Full House, ',
                             (SELECT RankPlural FROM #Poker_RankNames WHERE RankValue = @Trip), N' over ',
                             (SELECT RankPlural FROM #Poker_RankNames WHERE RankValue = @FHPair));
                    END
                    ELSE IF @FlushSuit IS NOT NULL
                    BEGIN
                        SET @Cat = 5;
                        SELECT @T1 = MAX(CASE WHEN rn = 1 THEN CardRank END),
                               @T2 = MAX(CASE WHEN rn = 2 THEN CardRank END),
                               @T3 = MAX(CASE WHEN rn = 3 THEN CardRank END),
                               @T4 = MAX(CASE WHEN rn = 4 THEN CardRank END),
                               @T5 = MAX(CASE WHEN rn = 5 THEN CardRank END)
                        FROM (SELECT CardRank, rn = ROW_NUMBER() OVER (ORDER BY CardRank DESC)
                              FROM @Seven WHERE CardSuit = @FlushSuit) f;
                        SET @HandName = CONCAT(N'a Flush, ',
                             (SELECT RankName FROM #Poker_RankNames WHERE RankValue = @T1), N' high');
                    END
                    ELSE IF @StraightHigh IS NOT NULL
                    BEGIN
                        SET @Cat = 4; SET @T1 = @StraightHigh;
                        SET @HandName = CONCAT(N'a Straight, ',
                             (SELECT RankName FROM #Poker_RankNames WHERE RankValue = @StraightHigh), N' high');
                    END
                    ELSE IF @Trip IS NOT NULL
                    BEGIN
                        SET @Cat = 3; SET @T1 = @Trip;
                        SELECT @T2 = MAX(CardRank) FROM @Seven WHERE CardRank <> @Trip;
                        SELECT @T3 = MAX(CardRank) FROM @Seven WHERE CardRank <> @Trip AND CardRank <> @T2;
                        SET @HandName = CONCAT(N'Three of a Kind, ',
                             (SELECT RankPlural FROM #Poker_RankNames WHERE RankValue = @Trip));
                    END
                    ELSE IF @Pair2 IS NOT NULL
                    BEGIN
                        SET @Cat = 2; SET @T1 = @Pair1; SET @T2 = @Pair2;
                        SELECT @T3 = MAX(CardRank) FROM @Seven WHERE CardRank <> @Pair1 AND CardRank <> @Pair2;
                        SET @HandName = CONCAT(N'Two Pair, ',
                             (SELECT RankPlural FROM #Poker_RankNames WHERE RankValue = @Pair1), N' and ',
                             (SELECT RankPlural FROM #Poker_RankNames WHERE RankValue = @Pair2));
                    END
                    ELSE IF @Pair1 IS NOT NULL
                    BEGIN
                        SET @Cat = 1; SET @T1 = @Pair1;
                        SELECT @T2 = MAX(CardRank) FROM @Seven WHERE CardRank <> @Pair1;
                        SELECT @T3 = MAX(CardRank) FROM @Seven WHERE CardRank <> @Pair1 AND CardRank <> @T2;
                        SELECT @T4 = MAX(CardRank) FROM @Seven WHERE CardRank <> @Pair1 AND CardRank NOT IN (@T2, @T3);
                        SET @HandName = CONCAT(N'a Pair of ',
                             (SELECT RankPlural FROM #Poker_RankNames WHERE RankValue = @Pair1));
                    END
                    ELSE
                    BEGIN
                        SET @Cat = 0;
                        SELECT @T1 = MAX(CASE WHEN rn = 1 THEN CardRank END),
                               @T2 = MAX(CASE WHEN rn = 2 THEN CardRank END),
                               @T3 = MAX(CASE WHEN rn = 3 THEN CardRank END),
                               @T4 = MAX(CASE WHEN rn = 4 THEN CardRank END),
                               @T5 = MAX(CASE WHEN rn = 5 THEN CardRank END)
                        FROM (SELECT CardRank, rn = ROW_NUMBER() OVER (ORDER BY CardRank DESC) FROM @Seven) a;
                        SET @HandName = CONCAT(
                             (SELECT RankName FROM #Poker_RankNames WHERE RankValue = @T1), N' high');
                    END

                    SET @Score = @Cat * CAST(10000000000 AS bigint)
                               + @T1 * 100000000 + @T2 * 1000000 + @T3 * 10000 + @T4 * 100 + @T5;

                    INSERT @ShowResults (SeatNum, PlayerName, Score, HandName)
                    VALUES (@cSeat, @cName, @Score, @HandName);

                    SELECT @Msg = CONCAT(@cName, N' shows ', c1.Display, N' ', c2.Display, N' - ', @HandName, N'.')
                    FROM #Poker_Cards c1 CROSS JOIN #Poker_Cards c2
                    WHERE c1.CardId = @cC1 AND c2.CardId = @cC2;
                    INSERT TexasHoldEm_Public.TexasHoldEm_Log (HandNumber, Message) VALUES (@GHand, @Msg);

                    FETCH NEXT FROM cur_show INTO @cSeat, @cName, @cC1, @cC2;
                END
                CLOSE cur_show;
                DEALLOCATE cur_show;

                SELECT @BestScore = MAX(Score) FROM @ShowResults;
                SELECT @NumWinners = COUNT(*) FROM @ShowResults WHERE Score = @BestScore;
                SET @Share = @Pot / @NumWinners;
                SET @Rem = @Pot % @NumWinners;

                /* Split pots divide evenly; odd chips go to the earliest seat past the button. */
                ;WITH w AS (SELECT sr.SeatNum,
                                   rn = ROW_NUMBER() OVER (ORDER BY CASE WHEN sr.SeatNum > @Dealer THEN 0 ELSE 1 END, sr.SeatNum)
                            FROM @ShowResults sr WHERE sr.Score = @BestScore)
                UPDATE p SET Chips = p.Chips + @Share + CASE WHEN w.rn <= @Rem THEN 1 ELSE 0 END,
                             LastWonHand = @GHand
                FROM TexasHoldEm_Public.TexasHoldEm_Players p JOIN w ON w.SeatNum = p.SeatNum;

                IF @NumWinners = 1
                    INSERT TexasHoldEm_Public.TexasHoldEm_Log (HandNumber, Message)
                    SELECT @GHand, CONCAT(PlayerName, N' wins the pot (', @Pot, N') with ', HandName, N'!')
                    FROM @ShowResults WHERE Score = @BestScore;
                ELSE
                    INSERT TexasHoldEm_Public.TexasHoldEm_Log (HandNumber, Message)
                    SELECT @GHand, CONCAT(x.WinnerNames, N' split the pot (', @Pot, N').')
                    FROM (SELECT WinnerNames = STRING_AGG(PlayerName, N' and ')
                          FROM @ShowResults WHERE Score = @BestScore) x;

                UPDATE TexasHoldEm_Public.TexasHoldEm_Game SET Pot = 0, ShowdownShown = 1;
                SET @HandDone = 1;
            END
            ELSE
            BEGIN
                /* Deal the next street. */
                SET @Round += 1;
                SET @BoardShown = CASE @Round WHEN 1 THEN 3 WHEN 2 THEN 4 ELSE 5 END;

                SET @BoardDisp = NULL;
                SELECT @BoardDisp = STRING_AGG(c.Display, N' ') WITHIN GROUP (ORDER BY b.ord)
                FROM (VALUES (1, @B1), (2, @B2), (3, @B3), (4, @B4), (5, @B5)) b(ord, cid)
                JOIN #Poker_Cards c ON c.CardId = b.cid
                WHERE b.ord <= @BoardShown;

                INSERT TexasHoldEm_Public.TexasHoldEm_Log (HandNumber, Message)
                VALUES (@GHand, CONCAT(N'*** ', CASE @Round WHEN 1 THEN N'FLOP' WHEN 2 THEN N'TURN' ELSE N'RIVER' END,
                        N': ', @BoardDisp, N' *** (pot: ', @Pot, N')'));

                UPDATE TexasHoldEm_Public.TexasHoldEm_Game SET BettingRound = @Round, BoardShown = @BoardShown;

                SELECT @ActiveBettors = COUNT(*) FROM TexasHoldEm_Public.TexasHoldEm_Players
                 WHERE InHand = 1 AND Folded = 0 AND AllIn = 0;
                IF @ActiveBettors >= 2
                BEGIN
                    UPDATE TexasHoldEm_Public.TexasHoldEm_Players SET NeedsToAct = 1
                     WHERE InHand = 1 AND Folded = 0 AND AllIn = 0;
                    SET @NextSeat = NULL;
                    SELECT TOP (1) @NextSeat = SeatNum FROM TexasHoldEm_Public.TexasHoldEm_Players
                     WHERE InHand = 1 AND Folded = 0 AND AllIn = 0 AND NeedsToAct = 1
                     ORDER BY CASE WHEN SeatNum > @Dealer THEN 0 ELSE 1 END, SeatNum;
                    UPDATE TexasHoldEm_Public.TexasHoldEm_Game SET TurnSeat = @NextSeat, TurnStartedAt = SYSDATETIME();
                END
                /* If everyone's all in, nobody can bet: the loop comes back
                   around and deals the next street automatically. */
                CONTINUE;
            END
        END

        IF @HandDone = 1
        BEGIN
            /* ===== End of the hand: standings, busts, exits, next hand. ===== */
            SET @Msg = NULL;
            SELECT @Msg = CONCAT(N'Chip counts: ',
                   STRING_AGG(CONCAT(PlayerName, N' ', Chips), N' | ') WITHIN GROUP (ORDER BY Chips DESC))
            FROM TexasHoldEm_Public.TexasHoldEm_Players;
            INSERT TexasHoldEm_Public.TexasHoldEm_Log (HandNumber, Message) VALUES (@GHand, @Msg);

            /* Bank the authoritative human stacks before removing any chair.
               Busted identities become OUT; timeout removals keep their chips
               as SPECTATORs so a password-authenticated return resumes the
               same bankroll. */
            UPDATE i
               SET Chips = p.Chips,
                   PlayerRole = CASE WHEN p.Chips <= 0 THEN 'OUT'
                                     WHEN p.WantsToLeave = 1 THEN 'SPECTATOR'
                                     ELSE 'PLAYER' END,
                   WantsSeat = 0,
                   TimedOut = CASE WHEN p.WantsToLeave = 1
                                         AND p.TimeoutStrikes >= @MaxTimeoutStrikes
                                   THEN 1 ELSE 0 END,
                   LastSeenAt = SYSDATETIME(),
                   LastPlayedHand = p.LastPlayedHand,
                   LastViewedHand = p.LastViewedHand
            FROM TexasHoldEm_Public.TexasHoldEm_Identities AS i
            JOIN TexasHoldEm_Public.TexasHoldEm_Players AS p
              ON p.PlayerName = i.PlayerName
            WHERE p.IsBot = 0;

            /* Humans only. Robots have no identity row and no retention, and
               they buy straight back in at the next hand start - telling the
               table Clippy "cannot rebuy during retention" is false, and it
               reads especially badly one line above the refill message. */
            INSERT TexasHoldEm_Public.TexasHoldEm_Log (HandNumber, Message)
            SELECT @GHand, CONCAT(PlayerName, N' is out of chips and is OUT; the identity cannot rebuy during retention.')
            FROM TexasHoldEm_Public.TexasHoldEm_Players WHERE Chips <= 0 AND IsBot = 0;

            /* Photograph the seats before they're cleared, so the Seat grid
               can still show who just went broke - and, if the hand went to
               a showdown, the cards they went broke holding. Anyone who is
               still in the seat table isn't in here, so the previous hand's
               rows go away as soon as this hand produces its own. */
            DELETE TexasHoldEm_Public.TexasHoldEm_HandBusts;
            INSERT TexasHoldEm_Public.TexasHoldEm_HandBusts (SeatNum, PlayerName, IsBot, HandNumber, Cards)
            SELECT p.SeatNum, p.PlayerName, p.IsBot, @GHand,
                   CASE WHEN h.HoleCards IS NOT NULL
                             THEN CONCAT(c1.Display, N' ', c2.Display)
                        ELSE N'' END
            FROM TexasHoldEm_Public.TexasHoldEm_Players AS p
            OUTER APPLY
            (
                SELECT CONVERT(varbinary(2), DecryptByCert
                (
                    CERT_ID(N'sp_TexasHoldEm_CardProtection_Claude'),
                    p.HoleCardsEncrypted,
                    N'Cl@udeTexasH0ldEm_2026!Cards'
                )) AS HoleCards
                WHERE p.HoleCardsEncrypted IS NOT NULL
                  AND p.InHand = 1 AND p.Folded = 0
                  /* Same rule the seat grid uses: cards are public only once
                     the showdown has actually shown them. */
                  AND EXISTS (SELECT 1 FROM TexasHoldEm_Public.TexasHoldEm_Game
                               WHERE ShowdownShown = 1)
            ) AS h
            LEFT JOIN #Poker_Cards AS c1
              ON c1.CardId = CONVERT(tinyint, SUBSTRING(h.HoleCards, 1, 1))
            LEFT JOIN #Poker_Cards AS c2
              ON c2.CardId = CONVERT(tinyint, SUBSTRING(h.HoleCards, 2, 1))
            WHERE p.Chips <= 0;

            DELETE TexasHoldEm_Public.TexasHoldEm_Players WHERE Chips <= 0;

            INSERT TexasHoldEm_Public.TexasHoldEm_Log (HandNumber, Message)
            SELECT @GHand, CONCAT(PlayerName,
                   CASE WHEN TimeoutStrikes >= @MaxTimeoutStrikes
                        THEN CONCAT(N' timed out and leaves the seat with ', Chips, N' retained chips.')
                        ELSE CONCAT(N' cashes out ', Chips, N' chips and leaves.') END)
            FROM TexasHoldEm_Public.TexasHoldEm_Players WHERE WantsToLeave = 1;
            DELETE TexasHoldEm_Public.TexasHoldEm_Players WHERE WantsToLeave = 1;

            /* The log is permanent now - keep it from growing into a fact table. */
            DELETE TexasHoldEm_Public.TexasHoldEm_Log
             WHERE LogId <= (SELECT MAX(LogId) - 300 FROM TexasHoldEm_Public.TexasHoldEm_Log);

            SELECT @NumPlayers = COUNT(*),
                   @HumansLeft = ISNULL(SUM(CASE WHEN IsBot = 0 THEN 1 ELSE 0 END), 0)
            FROM TexasHoldEm_Public.TexasHoldEm_Players;

            SELECT @ReturningHumans = COUNT(*)
            FROM TexasHoldEm_Public.TexasHoldEm_Identities
            WHERE PlayerRole = 'SPECTATOR' AND TimedOut = 1 AND Chips > 0
              AND LastPlayedHand = @GHand AND LastViewedHand < @GHand;

            /* None of these endings should strand somebody on the waitlist -
               a person still queued for a seat means the game isn't really
               over, it just needs one more hand-start to pull them in. */
            IF @NumPlayers = 0 AND @ReturningHumans = 0
               AND NOT EXISTS (SELECT 1 FROM TexasHoldEm_Public.TexasHoldEm_Waitlist)
            BEGIN
                INSERT TexasHoldEm_Public.TexasHoldEm_Log (HandNumber, Message) VALUES (@GHand, N'Everyone''s gone home. GAME OVER.');
                UPDATE TexasHoldEm_Public.TexasHoldEm_Game SET GameState = 'GameOver', TurnSeat = NULL;
            END
            ELSE IF @HumansLeft = 0 AND @NumPlayers > 0 AND @ReturningHumans = 0
                    AND NOT EXISTS (SELECT 1 FROM TexasHoldEm_Public.TexasHoldEm_Waitlist)
            BEGIN
                INSERT TexasHoldEm_Public.TexasHoldEm_Log (HandNumber, Message)
                VALUES (@GHand, N'No humans remain. The machines win. GAME OVER.');
                UPDATE TexasHoldEm_Public.TexasHoldEm_Game SET GameState = 'GameOver', TurnSeat = NULL;
            END
            ELSE
            BEGIN
                /* Everybody else just goes between hands - including a lone
                   surviving human, who keeps the stack they won. The next-hand
                   setup refills their empty seats with fresh robots, so busting
                   the table isn't game over. */

                /* Mark the moment anyway. Clearing the table is the best thing
                   that happens at this game, and without this the transcript
                   goes straight from three robots going broke to a note about
                   the acknowledgement deadline. It also explains where those
                   robots went before the refill line lands one hand later. */
                IF @NumPlayers = 1 AND @HumansLeft = 1
                    INSERT TexasHoldEm_Public.TexasHoldEm_Log (HandNumber, Message)
                    SELECT @GHand, CONCAT(N'*** ', PlayerName, N' busts the whole table with ', Chips,
                           N' chips! Fresh robots buy in for the next hand. ***')
                    FROM TexasHoldEm_Public.TexasHoldEm_Players;

                INSERT TexasHoldEm_Public.TexasHoldEm_Log (HandNumber, Message)
                VALUES (@GHand, CONCAT(N'Waiting for participating humans to receive the result; the next hand starts after everyone checks in or ',
                        @BetweenHandsSeconds, N' seconds pass.'));
                UPDATE TexasHoldEm_Public.TexasHoldEm_Game
                   SET GameState = 'BetweenHands', TurnSeat = NULL,
                       NextHandStartsAt = DATEADD(second, @BetweenHandsSeconds, SYSDATETIME());
            END
            CONTINUE;
        END

        /* ===== Somebody owes the table a decision. ===== */
        SET @ActorSeat = NULL;
        SELECT @ActorSeat = SeatNum, @ActorBot = IsBot, @ActorName = PlayerName,
               @ActorChips = Chips, @ActorBet = BetThisRound, @ActorStrikes = TimeoutStrikes,
               /* CardId 0-51 encodes rank as CardId / 4 + 2 - see the #Cards deck above. */
               @ActorRank1 = CONVERT(tinyint, SUBSTRING(h.HoleCards, 1, 1)) / 4 + 2,
               @ActorRank2 = CONVERT(tinyint, SUBSTRING(h.HoleCards, 2, 1)) / 4 + 2
        FROM TexasHoldEm_Public.TexasHoldEm_Players AS p
        CROSS APPLY
        (
            VALUES
            (
                CONVERT(varbinary(2), DecryptByCert
                (
                    CERT_ID(N'sp_TexasHoldEm_CardProtection_Claude'),
                    p.HoleCardsEncrypted,
                    N'Cl@udeTexasH0ldEm_2026!Cards'
                ))
            )
        ) AS h(HoleCards)
        WHERE SeatNum = @TurnSeat AND InHand = 1 AND Folded = 0 AND AllIn = 0 AND NeedsToAct = 1;

        IF @ActorSeat IS NULL
        BEGIN
            /* Stale turn pointer (someone folded out of turn, etc.) - repoint it. */
            SET @NextSeat = NULL;
            SELECT TOP (1) @NextSeat = SeatNum FROM TexasHoldEm_Public.TexasHoldEm_Players
             WHERE InHand = 1 AND Folded = 0 AND AllIn = 0 AND NeedsToAct = 1
             ORDER BY CASE WHEN SeatNum > ISNULL(@TurnSeat, @Dealer) THEN 0 ELSE 1 END, SeatNum;
            UPDATE TexasHoldEm_Public.TexasHoldEm_Game SET TurnSeat = @NextSeat, TurnStartedAt = SYSDATETIME();
            CONTINUE;
        END

        SET @Owed = @BetToCall - @ActorBet;
        SET @Unit = CASE WHEN @Round <= 1 THEN @SmallBet ELSE @BigBet END;
        SET @NewBet = CASE WHEN @BetToCall = 0 THEN @Unit ELSE @BetToCall + @Unit END;

        IF @ActorBot = 1
        BEGIN
            /* The robot "brain": it actually looks at its hole cards now. Pairs and
               big cards get raised, junk gets folded when it's facing a bet, and the
               dice decide the rest so the table stays unpredictable. Still not GTO. */
            SET @r = ABS(CONVERT(bigint, CHECKSUM(NEWID()))) % 100;
            /* Fixed-limit table: a raise needs an open raise slot and the chips to make it. */
            SET @CanRaise = CASE WHEN @RaiseCount < @MaxRaises AND @ActorChips >= (@NewBet - @ActorBet)
                                 THEN 1 ELSE 0 END;
            /* Shoving is only for short stacks. This is a LIMIT table with 50 big
               bets in front of everyone at the start, so a robot that jams its whole
               stack on hand one just ends the game. A stack only goes in when the
               fixed-limit bets can't get it in anyway: desperation under two bets,
               or a monster under five. @r is 0-99, so "@r < 45" is a 45% chance. */
            SET @Shove = CASE WHEN @ActorChips > 0
                               AND ((@ActorChips <= 2 * @Unit AND @r < 45)
                                    OR (@ActorChips <= 5 * @Unit
                                        AND @ActorRank1 = @ActorRank2 AND @ActorRank1 >= 12
                                        AND @r < 60))
                              THEN 1 ELSE 0 END;

            IF @Owed > 0
            BEGIN
                /* Junk hands, and bets that cost more than a third of the stack, get away. */
                IF (@ActorRank1 <> @ActorRank2 AND @ActorRank1 < 10 AND @ActorRank2 < 10 AND @r < 22)
                   OR (@Owed > (@ActorChips / 3) AND @r < 35)
                    SET @BotMove = 'Fold';
                ELSE IF @Shove = 1
                    SET @BotMove = 'AllIn';
                ELSE IF (@ActorRank1 = @ActorRank2 OR @ActorRank1 >= 12 OR @ActorRank2 >= 12)
                     AND @r >= 82 AND @CanRaise = 1
                    SET @BotMove = 'Raise';
                ELSE
                    SET @BotMove = 'Call';
            END
            ELSE
            BEGIN
                /* Nothing to call: bet the premium hands, plus the occasional bluff. */
                IF @Shove = 1
                    SET @BotMove = 'AllIn';
                ELSE IF (@ActorRank1 = @ActorRank2 OR @ActorRank1 >= 13 OR @ActorRank2 >= 13 OR @r >= 80)
                     AND @CanRaise = 1
                    SET @BotMove = 'Raise';
                ELSE
                    SET @BotMove = 'Check';
            END

            IF @BotMove = 'Check'
            BEGIN
                UPDATE TexasHoldEm_Public.TexasHoldEm_Players SET NeedsToAct = 0 WHERE SeatNum = @ActorSeat;
                INSERT TexasHoldEm_Public.TexasHoldEm_Log (HandNumber, Message) VALUES (@GHand, CONCAT(@ActorName, N' checks.'));
            END
            ELSE IF @BotMove = 'Call'
            BEGIN
                SET @Pay = CASE WHEN @ActorChips < @Owed THEN @ActorChips ELSE @Owed END;
                UPDATE TexasHoldEm_Public.TexasHoldEm_Players
                   SET Chips = Chips - @Pay, BetThisRound = BetThisRound + @Pay,
                       AllIn = CASE WHEN @ActorChips <= @Owed THEN 1 ELSE 0 END, NeedsToAct = 0
                 WHERE SeatNum = @ActorSeat;
                INSERT TexasHoldEm_Public.TexasHoldEm_Log (HandNumber, Message)
                VALUES (@GHand, CONCAT(@ActorName, N' calls ', @Pay,
                        CASE WHEN @ActorChips <= @Owed THEN N' and is ALL IN.' ELSE N'.' END));
            END
            ELSE IF @BotMove = 'AllIn'
            BEGIN
                SET @Pay = @ActorChips;
                SET @AllInTo = @ActorBet + @Pay;
                UPDATE TexasHoldEm_Public.TexasHoldEm_Players
                   SET Chips = 0, BetThisRound = @AllInTo, AllIn = 1, NeedsToAct = 0
                 WHERE SeatNum = @ActorSeat;
                IF @AllInTo > @BetToCall
                BEGIN
                    UPDATE TexasHoldEm_Public.TexasHoldEm_Players SET NeedsToAct = 1
                     WHERE InHand = 1 AND Folded = 0 AND AllIn = 0 AND SeatNum <> @ActorSeat;
                    UPDATE TexasHoldEm_Public.TexasHoldEm_Game SET BetToCall = @AllInTo, RaiseCount = RaiseCount + 1;
                END
                INSERT TexasHoldEm_Public.TexasHoldEm_Log (HandNumber, Message)
                VALUES (@GHand, CASE
                        WHEN @AllInTo > @BetToCall
                            THEN CONCAT(@ActorName, N' moves ALL IN for ', @Pay, N'. It''s ', @AllInTo, N' to call.')
                        WHEN @AllInTo = @BetToCall
                            THEN CONCAT(@ActorName, N' calls ALL IN for ', @Pay, N'.')
                        ELSE CONCAT(@ActorName, N' calls ALL IN for ', @Pay,
                                    N', which doesn''t cover the ', @BetToCall, N'.') END);
            END
            ELSE IF @BotMove = 'Raise'
            BEGIN
                SET @Pay = @NewBet - @ActorBet;
                UPDATE TexasHoldEm_Public.TexasHoldEm_Players
                   SET Chips = Chips - @Pay, BetThisRound = @NewBet,
                       AllIn = CASE WHEN @ActorChips = @Pay THEN 1 ELSE 0 END, NeedsToAct = 0
                 WHERE SeatNum = @ActorSeat;
                UPDATE TexasHoldEm_Public.TexasHoldEm_Players SET NeedsToAct = 1
                 WHERE InHand = 1 AND Folded = 0 AND AllIn = 0 AND SeatNum <> @ActorSeat;
                UPDATE TexasHoldEm_Public.TexasHoldEm_Game SET BetToCall = @NewBet, RaiseCount = RaiseCount + 1;
                INSERT TexasHoldEm_Public.TexasHoldEm_Log (HandNumber, Message)
                VALUES (@GHand, CONCAT(@ActorName,
                        CASE WHEN @BetToCall = 0 THEN N' bets ' ELSE N' raises to ' END, @NewBet, N'.'));
            END
            ELSE
            BEGIN
                UPDATE TexasHoldEm_Public.TexasHoldEm_Players SET Folded = 1, NeedsToAct = 0 WHERE SeatNum = @ActorSeat;
                INSERT TexasHoldEm_Public.TexasHoldEm_Log (HandNumber, Message) VALUES (@GHand, CONCAT(@ActorName, N' folds.'));
            END

            /* Occasional trash talk. The robots contain multitudes. */
            IF ABS(CONVERT(bigint, CHECKSUM(NEWID()))) % 100 < 18
            BEGIN
                SET @Msg = NULL;
                SELECT @Msg = CONCAT(@ActorName, N' says: "', q.Quip, N'"')
                FROM (VALUES
                    (N'Clippy', 1, N'It looks like you''re trying to win a poker hand. Would you like help with that?'),
                    (N'Clippy', 2, N'Have you tried turning your cards off and on again?'),
                    (N'Clippy', 3, N'I''m not bluffing. I''m assisting aggressively.'),
                    (N'HAL',    1, N'I''m sorry, Dave. I''m afraid I can''t fold.'),
                    (N'HAL',    2, N'This hand is too important for me to allow you to jeopardize it.'),
                    (N'HAL',    3, N'My chips are going. I can feel it.'),
                    (N'Bender', 1, N'Bite my shiny metal cards.'),
                    (N'Bender', 2, N'I''m back, baby!'),
                    (N'Bender', 3, N'This game is making me thirsty.')
                ) q(BotName, QuipId, Quip)
                WHERE q.BotName = @ActorName AND q.QuipId = 1 + ABS(CONVERT(bigint, CHECKSUM(NEWID()))) % 3;
                IF @Msg IS NOT NULL
                    INSERT TexasHoldEm_Public.TexasHoldEm_Log (HandNumber, Message) VALUES (@GHand, @Msg);
            END

            SET @NextSeat = NULL;
            SELECT TOP (1) @NextSeat = SeatNum FROM TexasHoldEm_Public.TexasHoldEm_Players
             WHERE InHand = 1 AND Folded = 0 AND AllIn = 0 AND NeedsToAct = 1
             ORDER BY CASE WHEN SeatNum > @ActorSeat THEN 0 ELSE 1 END, SeatNum;
            UPDATE TexasHoldEm_Public.TexasHoldEm_Game SET TurnSeat = @NextSeat, TurnStartedAt = SYSDATETIME();
            CONTINUE;
        END

        /* A human's turn: enforce the shot clock. */
        IF DATEDIFF(second, @TurnStartedAt, SYSDATETIME()) >= @TurnSeconds
        BEGIN
            IF @Owed > 0
            BEGIN
                UPDATE TexasHoldEm_Public.TexasHoldEm_Players SET Folded = 1, NeedsToAct = 0, TimeoutStrikes = TimeoutStrikes + 1
                 WHERE SeatNum = @ActorSeat;
                INSERT TexasHoldEm_Public.TexasHoldEm_Log (HandNumber, Message)
                VALUES (@GHand, CONCAT(@ActorName, N' took too long and folds.'));
            END
            ELSE
            BEGIN
                UPDATE TexasHoldEm_Public.TexasHoldEm_Players SET NeedsToAct = 0, TimeoutStrikes = TimeoutStrikes + 1
                 WHERE SeatNum = @ActorSeat;
                INSERT TexasHoldEm_Public.TexasHoldEm_Log (HandNumber, Message)
                VALUES (@GHand, CONCAT(@ActorName, N' took too long and checks.'));
            END

            IF @ActorStrikes + 1 >= @MaxTimeoutStrikes
            BEGIN
                UPDATE TexasHoldEm_Public.TexasHoldEm_Players SET WantsToLeave = 1 WHERE SeatNum = @ActorSeat;
                INSERT TexasHoldEm_Public.TexasHoldEm_Log (HandNumber, Message)
                VALUES (@GHand, CONCAT(@ActorName, N' has timed out ', @MaxTimeoutStrikes,
                        N' times and will be removed after this hand.'));
            END

            SET @NextSeat = NULL;
            SELECT TOP (1) @NextSeat = SeatNum FROM TexasHoldEm_Public.TexasHoldEm_Players
             WHERE InHand = 1 AND Folded = 0 AND AllIn = 0 AND NeedsToAct = 1
             ORDER BY CASE WHEN SeatNum > @ActorSeat THEN 0 ELSE 1 END, SeatNum;
            UPDATE TexasHoldEm_Public.TexasHoldEm_Game SET TurnSeat = @NextSeat, TurnStartedAt = SYSDATETIME();
            CONTINUE;
        END

        BREAK; /* A live human is thinking. Nothing for the engine to do. */
    END /* engine */

    /* ================================================================
       Snapshot the world for this session, then let go of the lock.
       ================================================================ */
    SELECT @GState = GameState, @GHand = HandNumber, @Dealer = DealerSeat,
           @SBSeat = SmallBlindSeat, @BBSeat = BigBlindSeat,
           @TurnSeat = TurnSeat, @TurnStartedAt = TurnStartedAt,
           @Round = BettingRound, @Pot = Pot, @BetToCall = BetToCall,
           @RaiseCount = RaiseCount, @BoardShown = BoardShown,
           @ShowdownShown = ShowdownShown, @JoinEnds = JoinWindowEndsAt,
           @NextHandAt = NextHandStartsAt,
           @B1 = Board1, @B2 = Board2, @B3 = Board3, @B4 = Board4, @B5 = Board5
    FROM TexasHoldEm_Public.TexasHoldEm_Game;
    SET @SnapshotAt = SYSDATETIME();

    SET @SeatExists = 0; SET @CurOwner = NULL; SET @CurLoginTime = NULL;
    SET @MyNeedsToAct = 0; SET @MyFolded = 0;
    SET @MyInHand = 0; SET @MyC1 = NULL; SET @MyC2 = NULL; SET @MyChips = NULL; SET @MyBet = 0;
    IF @MySeat IS NOT NULL
        SELECT @SeatExists = 1, @CurOwner = SessionId, @CurLoginTime = SessionLoginTime,
               @MyNeedsToAct = NeedsToAct,
               @MyFolded = Folded, @MyInHand = InHand,
               @MyC1 = CONVERT(tinyint, SUBSTRING(h.HoleCards, 1, 1)),
               @MyC2 = CONVERT(tinyint, SUBSTRING(h.HoleCards, 2, 1)),
               @MyChips = Chips, @MyBet = BetThisRound
        FROM TexasHoldEm_Public.TexasHoldEm_Players AS p
        OUTER APPLY
        (
            VALUES
            (
                CONVERT(varbinary(2), DecryptByCert
                (
                    CERT_ID(N'sp_TexasHoldEm_CardProtection_Claude'),
                    p.HoleCardsEncrypted,
                    N'Cl@udeTexasH0ldEm_2026!Cards'
                ))
            )
        ) AS h(HoleCards)
        WHERE p.SeatNum = @MySeat;

    IF @IdentityFound = 1
    BEGIN
        SELECT @IdentityRole = PlayerRole, @IdentityChips = Chips,
               @IdentityTimedOut = TimedOut
        FROM TexasHoldEm_Public.TexasHoldEm_Identities
        WHERE IdentityId = @IdentityId;
        IF @SeatExists = 0 SET @MyChips = @IdentityChips;
    END

    SET @MyCards = NULL;
    IF @MyC1 IS NOT NULL
        SELECT @MyCards = CONCAT(c1.Display, N' ', c2.Display)
        FROM #Poker_Cards AS c1
        CROSS JOIN #Poker_Cards AS c2
        WHERE c1.CardId = @MyC1 AND c2.CardId = @MyC2;

    /* Freeze the viewer-specific seat grid while the applock is held. The
       decryption predicate is deliberately inside the snapshot query: after
       COMMIT, rendering cannot accidentally broaden card visibility. */
    DELETE @PlayerSnapshot;
    INSERT @PlayerSnapshot
        (SeatNum, PlayerName, IsBot, Chips, BetThisRound, InHand, Folded, AllIn, Cards, LastWonHand)
    SELECT p.SeatNum, p.PlayerName, p.IsBot, p.Chips, p.BetThisRound,
           p.InHand, p.Folded, p.AllIn,
           CASE WHEN h.HoleCards IS NOT NULL
                     THEN CONCAT(c1.Display, N' ', c2.Display)
                WHEN p.InHand = 1 AND p.Folded = 0 AND p.HoleCardsEncrypted IS NOT NULL
                     THEN N'[hidden]'
                ELSE N'' END,
           p.LastWonHand
    FROM TexasHoldEm_Public.TexasHoldEm_Players AS p
    OUTER APPLY
    (
        SELECT CONVERT(varbinary(2), DecryptByCert
        (
            CERT_ID(N'sp_TexasHoldEm_CardProtection_Claude'),
            p.HoleCardsEncrypted,
            N'Cl@udeTexasH0ldEm_2026!Cards'
        )) AS HoleCards
        WHERE p.HoleCardsEncrypted IS NOT NULL
          AND
          (
              p.SeatNum = @MySeat
              OR (p.InHand = 1 AND p.Folded = 0 AND @ShowdownShown = 1
                  AND @GState IN ('BetweenHands', 'GameOver'))
          )
    ) AS h
    LEFT JOIN #Poker_Cards AS c1
      ON c1.CardId = CONVERT(tinyint, SUBSTRING(h.HoleCards, 1, 1))
    LEFT JOIN #Poker_Cards AS c2
      ON c2.CardId = CONVERT(tinyint, SUBSTRING(h.HoleCards, 2, 1));

    /* Add back whoever busted out of the hand this grid is describing. They
       have no seat row anymore, so they're stitched in here at zero chips
       rather than left as a hole in the table nobody can explain. Rows stop
       appearing on their own when the next hand bumps the hand number, and a
       seat that's already been handed to somebody else belongs to the new
       occupant, not to the ghost. */
    INSERT @PlayerSnapshot
        (SeatNum, PlayerName, IsBot, Chips, BetThisRound, InHand, Folded, AllIn, Cards,
         LastWonHand, Busted)
    /* A busted seat never won the hand it busted in, so LastWonHand is 0. */
    SELECT b.SeatNum, b.PlayerName, b.IsBot, 0, 0, 0, 0, 0,
           /* Held to the same rule as a live seat's cards: a showdown is
              public only once the hand it belongs to is over. */
           CASE WHEN @GState IN ('BetweenHands', 'GameOver') THEN b.Cards
                ELSE N'' END, 0, 1
    FROM TexasHoldEm_Public.TexasHoldEm_HandBusts AS b
    WHERE b.HandNumber = @GHand
      AND NOT EXISTS (SELECT 1 FROM TexasHoldEm_Public.TexasHoldEm_Players AS p
                       WHERE p.SeatNum = b.SeatNum);

    SET @TurnPlayerName = NULL;
    SELECT @TurnPlayerName = PlayerName
    FROM @PlayerSnapshot
    WHERE SeatNum = @TurnSeat;

    DELETE @NewLog;
    INSERT @NewLog (LogId, Message)
    SELECT LogId, Message FROM TexasHoldEm_Public.TexasHoldEm_Log WHERE LogId > @LastLogId;
    SELECT @LastLogId = ISNULL(MAX(LogId), @LastLogId) FROM @NewLog;

    /* Freeze the requested transcript with explicit lower and upper bounds.
       ThisTurn remains the bounded default; the permanent log itself is
       trimmed to 300 rows, so the opt-in wider views are bounded too. */
    DELETE @Happened;
    SET @ResponseLogUpper = @LastLogId;

    IF @ShowWhatHappened = N'ThisTurn'
        INSERT @Happened (LogId, Message)
        SELECT LogId, Message
        FROM TexasHoldEm_Public.TexasHoldEm_Log
        WHERE LogId > @TurnStartLogId AND LogId <= @ResponseLogUpper;
    ELSE IF @ShowWhatHappened = N'ThisGame'
    BEGIN
        SELECT @GameStartLogId = ISNULL(MAX(x.LogId), 0)
        FROM
        (
            SELECT LogId, HandNumber,
                   PrevHand = LAG(HandNumber) OVER (ORDER BY LogId)
            FROM TexasHoldEm_Public.TexasHoldEm_Log
            WHERE LogId <= @ResponseLogUpper
        ) AS x
        WHERE x.PrevHand IS NOT NULL AND x.HandNumber < x.PrevHand;

        INSERT @Happened (LogId, Message)
        SELECT LogId, Message
        FROM TexasHoldEm_Public.TexasHoldEm_Log
        WHERE LogId >= @GameStartLogId AND LogId <= @ResponseLogUpper;
    END
    ELSE
        INSERT @Happened (LogId, Message)
        SELECT LogId, Message
        FROM TexasHoldEm_Public.TexasHoldEm_Log
        WHERE LogId >= 0 AND LogId <= @ResponseLogUpper;

    /* A BetweenHands response contains this hand's final table and transcript.
       Acknowledge only this viewer and only the hand captured above. The next
       invocation may then advance once every relevant human has checked in. */
    IF @GState = 'BetweenHands' AND @GHand >= @TargetHand AND @MySeat IS NOT NULL
        UPDATE TexasHoldEm_Public.TexasHoldEm_Players
           SET LastViewedHand = @GHand
         WHERE SeatNum = @MySeat
           AND IsBot = 0
           AND LastPlayedHand = @GHand
           AND LastViewedHand < @GHand;

    IF @GState = 'BetweenHands' AND @GHand >= @TargetHand AND @IdentityFound = 1
        UPDATE TexasHoldEm_Public.TexasHoldEm_Identities
           SET LastViewedHand = @GHand, LastSeenAt = @SnapshotAt
         WHERE IdentityId = @IdentityId
           AND LastPlayedHand = @GHand
           AND LastViewedHand < @GHand;

    COMMIT;

    /* Stream the action to the Messages tab as it happens. */
    DECLARE cur_stream CURSOR LOCAL FAST_FORWARD FOR SELECT Message FROM @NewLog ORDER BY LogId;
    OPEN cur_stream;
    FETCH NEXT FROM cur_stream INTO @Msg;
    WHILE @@FETCH_STATUS = 0
    BEGIN
        RAISERROR(N'%s', 0, 1, @Msg) WITH NOWAIT;
        FETCH NEXT FROM cur_stream INTO @Msg;
    END
    CLOSE cur_stream;
    DEALLOCATE cur_stream;

    /* Whisper this session its own hole cards once per hand. */
    IF @GState = 'InHand' AND @SeatExists = 1 AND @MyInHand = 1 AND @MyC1 IS NOT NULL
       AND @CardsShownForHand <> @GHand
    BEGIN
        SET @MyCards = NULL;
        SELECT @MyCards = CONCAT(c1.Display, N' ', c2.Display)
        FROM #Poker_Cards c1 CROSS JOIN #Poker_Cards c2 WHERE c1.CardId = @MyC1 AND c2.CardId = @MyC2;
        SET @Msg = CONCAT(N'>>> Your hole cards, ', @PlayerName, N': ', @MyCards, N' <<<');
        RAISERROR(N'%s', 0, 1, @Msg) WITH NOWAIT;
        SET @CardsShownForHand = @GHand;
    END

    /* Hang onto the notice. If this pass turns out to be the one that hands
       results back, the severity-11 raise at the very bottom delivers it and
       drags SSMS over to the Messages tab. */
    IF @Notice IS NOT NULL SET @LastNotice = @Notice;

    /* Is there a reason to give this session its results back? */
    IF @ReturnNow = 1 BREAK;
    IF @GState = 'GameOver' BREAK;
    IF @IsObserver = 0 AND @MySeat IS NOT NULL AND @SeatExists = 1
       AND (@CurOwner <> @@SPID OR @CurLoginTime IS NULL OR @CurLoginTime <> @MyLoginTime)
    BEGIN
        SET @SeatStolen = 1;
        BREAK;
    END
    IF @IsObserver = 0 AND @MySeat IS NOT NULL AND @SeatExists = 0 BREAK;      /* busted or removed */
    IF @GState = 'InHand' AND @SeatExists = 1 AND @TurnSeat = @MySeat
       AND @MyNeedsToAct = 1 AND @MyFolded = 0 BREAK;                          /* your move! */
    IF @GState = 'BetweenHands' AND @GHand >= @TargetHand BREAK;               /* hand's over */
    IF @WaitForTurn = 0 BREAK;                                                  /* polling client */
    IF DATEDIFF(minute, @WaitStart, SYSDATETIME()) >= @MaxWaitMinutes
    BEGIN
        SET @GaveUp = 1;
        BREAK;
    END

    /* Still waiting, so say it now rather than making them wait for the
       end-of-proc raise - and clear it, since they've now seen it. */
    IF @Notice IS NOT NULL
    BEGIN
        RAISERROR(N'%s', 0, 1, @Notice) WITH NOWAIT;
        SET @Notice = NULL;
        SET @LastNotice = NULL;
    END

    IF @ToldWaiting = 0
    BEGIN
        RAISERROR(N'(Waiting for the action - watch this Messages tab. Your query finishes when you need to do something.)', 0, 1) WITH NOWAIT;
        SET @ToldWaiting = 1;
    END

    WAITFOR DELAY '00:00:02';
END /* main wait loop */

/* A rejected action ages badly. "It's not your turn" was true when the
   action arrived, but this session then sat in the loop above until it had
   something to say - and the most common reason it stops waiting is that the
   turn came back around. Delivering the original wording now would argue
   with the YOUR TURN prompt three inches above it in the same response, which
   is exactly what a player reports as a bug. Same fact, told against the
   table as it stands at the moment they read it. */
IF @MissedAction IS NOT NULL AND @LastNotice IS NOT NULL
   AND @GState = 'InHand' AND @SeatExists = 1 AND @TurnSeat = @MySeat
   AND @MyNeedsToAct = 1 AND @MyFolded = 0
    SET @LastNotice = CONCAT(N'Your ', @MissedAction,
        N' didn''t count - the table had already moved past that decision when it arrived. ',
        N'You''re up NOW though, so run one of the commands in What Now.');

/* ================================================================
   Show this session everything: the table, the players, exactly what to
   run next, and then the action. What Now comes before What Happened on
   purpose - the play-by-play can run long, and nobody should have to
   scroll past it to find out what to type.
   ================================================================ */
IF @GameGone = 1
BEGIN
    SELECT [House Fire] = N'The game tables vanished mid-hand. Players can''t do that anymore, so ask your admin what they just dropped. Re-run the setup script to rebuild the casino.';
    RETURN;
END

SET @BoardDisp = NULL;
SELECT @BoardDisp = STRING_AGG(c.Display, N' ') WITHIN GROUP (ORDER BY b.ord)
FROM (VALUES (1, @B1), (2, @B2), (3, @B3), (4, @B4), (5, @B5)) b(ord, cid)
JOIN #Poker_Cards c ON c.CardId = b.cid
WHERE b.ord <= @BoardShown;

SET @PotDisp = @Pot + ISNULL((SELECT SUM(BetThisRound) FROM @PlayerSnapshot WHERE InHand = 1), 0);

/* Result 1: the table at a glance. */
SELECT [Hand #] = NULLIF(@GHand, 0),
       [Stage] = CASE @GState
                    WHEN 'WaitingForPlayers' THEN N'Waiting for players to join'
                    WHEN 'BetweenHands' THEN N'Between hands'
                    WHEN 'GameOver' THEN N'GAME OVER'
                    ELSE CASE @Round WHEN 0 THEN N'Pre-flop betting' WHEN 1 THEN N'Flop betting'
                              WHEN 2 THEN N'Turn betting' ELSE N'River betting' END
                 END,
       [Board] = ISNULL(@BoardDisp, N'(nothing dealt yet)'),
       [Pot] = @PotDisp,
       [Your Cards] = CASE WHEN @MyCards IS NOT NULL AND @MyInHand = 1 THEN @MyCards
                           WHEN @SeatExists = 1 THEN N'(none yet)'
                           ELSE N'(observer)' END,
       [Your Chips] = @MyChips;

/* Result 2: the players. Hole cards show only for you - and for everyone
   left standing after a showdown, because that's public. */
SELECT [Seat] = p.SeatNum,
       [Player] = p.PlayerName + CASE WHEN p.IsBot = 1 THEN N' [bot]' ELSE N'' END,
       [Position] = CASE WHEN p.SeatNum = @Dealer AND p.SeatNum = @SBSeat THEN N'Dealer + Small Blind'
                         WHEN p.SeatNum = @Dealer THEN N'Dealer'
                         WHEN p.SeatNum = @SBSeat THEN N'Small Blind'
                         WHEN p.SeatNum = @BBSeat THEN N'Big Blind'
                         ELSE N'' END,
       [Chips] = p.Chips,
       [This Round] = p.BetThisRound,
       [Cards] = p.Cards,
       /* Winner! outranks everything else here: the hand is over, so ALL IN
          and Folded are history, and the whole point of this column at that
          moment is to answer "who won?" without reading the play-by-play.
          The flag ages out on its own - the next deal bumps the hand number.
          Busted goes first only because a ghost seat has nothing else true
          to say: it can't have won the hand it lost its last chip in. */
       [Status] = CASE WHEN p.Busted = 1 THEN N'Busted out'
                       WHEN p.LastWonHand > 0 AND p.LastWonHand = @GHand THEN N'Winner!'
                       WHEN p.Folded = 1 THEN N'Folded'
                       WHEN p.AllIn = 1 THEN N'ALL IN'
                       WHEN @GState = 'InHand' AND p.SeatNum = @TurnSeat THEN N'<<< deciding'
                       WHEN @GState = 'InHand' AND p.InHand = 0 THEN N'Sitting out this hand'
                       ELSE N'' END
FROM @PlayerSnapshot AS p
ORDER BY p.SeatNum;

/* Result 3: what to do now. Never echo @SeatPassword back - results get
   screenshotted, projected, and streamed. */
SET @NameArg = CASE WHEN @PlayerName IS NOT NULL
                    THEN CONCAT(N', @PlayerName = ''', REPLACE(@PlayerName, N'''', N''''''), N'''')
                    ELSE N'' END;
DELETE @Prompt;

IF @SeatStolen = 1
    INSERT @Prompt (Line) VALUES
        (N'Another session reconnected with your player name and @SeatPassword and took over your seat.'),
        (N'If that wasn''t you, somebody knows your password. Pick a better one next game.');
ELSE IF @GaveUp = 1
    INSERT @Prompt (Line) VALUES
        (CONCAT(N'Waited ', @MaxWaitMinutes, N' minutes with nothing to do, so this query is giving up. Run EXEC sp_TexasHoldEm_Public to resume.'));
ELSE IF @LeftTable = 1
    INSERT @Prompt (Line) VALUES
        (N'You''ve left the game. Thanks for playing! Run EXEC sp_TexasHoldEm_Public any time to get back in.');
ELSE IF @GState = 'GameOver'
    INSERT @Prompt (Line) VALUES
        (N'GAME OVER. Run EXEC sp_TexasHoldEm_Public @Action = ''NewGame'' to open a fresh game.'),
        (N'A database administrator can use @Action = ''Reset'' to abandon a stuck game at any time.');
ELSE IF @GState = 'InHand' AND @SeatExists = 1 AND @TurnSeat = @MySeat
     AND @MyNeedsToAct = 1 AND @MyFolded = 0
BEGIN
    SET @Owed = @BetToCall - @MyBet;
    SET @Unit = CASE WHEN @Round <= 1 THEN @SmallBet ELSE @BigBet END;
    SET @NewBet = CASE WHEN @BetToCall = 0 THEN @Unit ELSE @BetToCall + @Unit END;
    SET @SecondsLeft = @TurnSeconds - DATEDIFF(second, @TurnStartedAt, @SnapshotAt);
    IF @SecondsLeft < 0 SET @SecondsLeft = 0;

    INSERT @Prompt (Line) VALUES
        (CONCAT(N'>>> YOUR TURN, ', @PlayerName, N'! You have ', @MyCards, N'. Pot: ', @PotDisp, N'. ',
                CASE WHEN @Owed > 0 THEN CONCAT(N'It costs ', @Owed, N' to call. ') ELSE N'Nothing to call. ' END,
                N'About ', @SecondsLeft, N' seconds on the shot clock:'));

    IF @Owed <= 0
        INSERT @Prompt (Line) VALUES
            (CONCAT(N'EXEC sp_TexasHoldEm_Public @Action = ''Check''', @NameArg, N';'));
    ELSE
        INSERT @Prompt (Line) VALUES
            (CONCAT(N'EXEC sp_TexasHoldEm_Public @Action = ''Call''', @NameArg, N';',
                    CASE WHEN @MyChips < @Owed THEN CONCAT(N'   -- ALL IN for your last ', @MyChips)
                         ELSE CONCAT(N'   -- costs ', @Owed) END));

    IF @RaiseCount < @MaxRaises AND @MyChips >= (@NewBet - @MyBet)
        INSERT @Prompt (Line) VALUES
            (CONCAT(N'EXEC sp_TexasHoldEm_Public @Action = ''Raise''', @NameArg, N';',
                    CASE WHEN @BetToCall = 0 THEN N'   -- bet ' ELSE N'   -- raise to ' END, @NewBet));

    /* The shove is always on the menu - the raise cap doesn't apply to it, and
       this includes an exact or short all-in call, not just a raise-sized one. */
    IF @MyChips > 0
        INSERT @Prompt (Line) VALUES
            (CONCAT(N'EXEC sp_TexasHoldEm_Public @Action = ''AllIn''', @NameArg, N';',
                    N'   -- shove all ', @MyChips, N', for a total of ', @MyBet + @MyChips, N' this round'));

    INSERT @Prompt (Line) VALUES
        (CONCAT(N'EXEC sp_TexasHoldEm_Public @Action = ''Fold''', @NameArg, N';'));

    INSERT @Prompt (Line) VALUES
        (N'(Running from a new session? Add your @SeatPassword to any of those.)');
END
ELSE IF @IsObserver = 1
    INSERT @Prompt (Line) VALUES
        (N'You''re watching from the rail. Poll with EXEC sp_TexasHoldEm_Public @Action = ''Status'' about every 2 seconds,'),
        (N'or EXEC sp_TexasHoldEm_Public to grab a seat when one opens up.');
ELSE IF @IdentityRole = 'OUT'
    INSERT @Prompt (Line) VALUES
        (CONCAT(N'You are OUT with 0 chips. This identity cannot receive another free stack for ',
                @OutRetentionMinutes, N' minutes. Watch with @Action = ''Status'' or wait for a fresh game.'));
ELSE IF @IdentityRole = 'SPECTATOR' AND @IdentityTimedOut = 1
    INSERT @Prompt (Line) VALUES
        (CONCAT(N'Your timed-out identity still has ', @IdentityChips,
                N' chips. Run EXEC sp_TexasHoldEm_Public', STUFF(@NameArg, 1, 2, N' '),
                N' with your @SeatPassword to request a seat and resume that stack.'));
ELSE IF @IdentityRole = 'SPECTATOR'
    INSERT @Prompt (Line) VALUES
        (CONCAT(N'You have ', @IdentityChips,
                N' retained chips off-table. Run EXEC sp_TexasHoldEm_Public', STUFF(@NameArg, 1, 2, N' '),
                N' with your @SeatPassword to request a seat.'));
ELSE IF @MySeat IS NOT NULL AND @SeatExists = 0
    INSERT @Prompt (Line) VALUES
        (N'Your seat is gone. Run EXEC sp_TexasHoldEm_Public @Action = ''Status'' to watch the table.');
ELSE IF @GState = 'WaitingForPlayers'
    INSERT @Prompt (Line) VALUES
        (CONCAT(N'Waiting for players until ', CONVERT(nvarchar(8), @JoinEnds, 108),
                N' (UTC-ish server time). Run EXEC sp_TexasHoldEm_Public in other sessions to join.')),
        (N'Poll with EXEC sp_TexasHoldEm_Public @Action = ''Status''; lobby polling can be slower than every 2 seconds.');
ELSE IF @WaitForTurn = 0 AND @GState = 'InHand' AND @SeatExists = 1
    INSERT @Prompt (Line) VALUES
        (CONCAT(N'Waiting for ', ISNULL(@TurnPlayerName, N'the next player'),
                N'. Poll with EXEC sp_TexasHoldEm_Public @Action = ''Status'' about every 2 seconds.'));
ELSE IF @SeatExists = 1
    INSERT @Prompt (Line) VALUES
        (CONCAT(N'Hand #', @GHand, N' is done. Run EXEC sp_TexasHoldEm_Public', STUFF(@NameArg, 1, 2, N' '), N' to play the next hand.'));
ELSE
    INSERT @Prompt (Line) VALUES
        (N'Run EXEC sp_TexasHoldEm_Public to join the game.');

SELECT [What Now] = Line FROM @Prompt ORDER BY LineId;

/* Result 4: the play-by-play frozen under the same lock as results 1-3. */

IF NOT EXISTS (SELECT 1 FROM @Happened)
    INSERT @Happened (LogId, Message)
    VALUES (0, CASE WHEN @ShowWhatHappened = N'ThisTurn'
                    THEN N'Nothing to replay for this turn. Pass @ShowWhatHappened = ''ThisGame'' or ''AllHistory'' to see more.'
                    ELSE N'Nothing in the log yet. Nobody has played a hand here.' END);

SELECT [What Happened] = Message FROM @Happened ORDER BY LogId;

END TRY
BEGIN CATCH
    IF @@TRANCOUNT > 0 ROLLBACK;
    THROW;
END CATCH

/* SSMS focuses the Results grid whenever a query returns one, and this proc
   always returns one, so whatever we said in the Messages tab gets buried the
   moment the query finishes. Severity 11+ is the only thing that pulls focus
   back there, so when the player needs to READ something - a rejected action,
   a "not your turn" - we hand it back as an error on the way out. Severity 11
   doesn't abort the batch and leaves SQLCMD's exit code at 0; it just turns
   the text red and wins the argument about which tab you're looking at. This
   lives after END CATCH on purpose: raised inside the TRY, the CATCH above
   would swallow it and roll the game back. */
IF @LastNotice IS NOT NULL
    RAISERROR(N'%s', 11, 1, @LastNotice);
END
GO

/* CREATE OR ALTER PROCEDURE removes existing signatures, so every successful
   installer run must sign the current module definition again. */
ADD SIGNATURE TO OBJECT::dbo.sp_TexasHoldEm_Public
    BY CERTIFICATE sp_TexasHoldEm_CardProtection_Claude
    WITH PASSWORD = 'Cl@udeTexasH0ldEm_2026!Cards';
GO

GRANT EXECUTE ON OBJECT::dbo.sp_TexasHoldEm_Public TO TexasHoldEm_Public_Players;
GO

/* Quick demo:

   Window 1:  EXEC sp_TexasHoldEm_Public @PlayerName = 'Brent', @SeatPassword = 'hunter2';
   Window 2:  EXEC sp_TexasHoldEm_Public @PlayerName = 'Claude', @SeatPassword = 'yeehaw';   (within 60 seconds)
   Window 3:  EXEC sp_TexasHoldEm_Public @Action = 'Status';      (instant peek, never blocks)

   Then just do what the [What Now] result set tells you. If a window dies,
   open a new one and reconnect with your @PlayerName and @SeatPassword.

MIT License

Copyright (c) 2026 Brent Ozar Unlimited

Permission is hereby granted, free of charge, to any person obtaining a copy
of this software and associated documentation files (the "Software"), to deal
in the Software without restriction, including without limitation the rights
to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
copies of the Software, and to permit persons to whom the Software is
furnished to do so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in all
copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
SOFTWARE.
*/
