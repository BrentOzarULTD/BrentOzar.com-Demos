/*
sp_TexasHoldEm
================

A multiplayer Texas Hold 'Em demonstration that runs entirely in T-SQL.

Install this procedure in the user database where the game will be played.
Game state is stored only in global temporary tables. In Azure SQL Database,
global temporary tables are scoped to the current database. On SQL Server,
the rows are keyed by database_id so each database has its own game.

The installer also creates a database certificate, but no permanent tables.
Hole cards are encrypted in transient shared state. Players granted only
EXECUTE on this procedure see ciphertext if they query the global temporary
table directly. This is a game-level privacy boundary, not protection from
sysadmin, db_owner, or principals allowed to alter the procedure or certificate.
Other shared game-state columns remain directly readable and modifiable, so
this demonstration is not intended as a security boundary for hostile users.

Quick start (open several SSMS query windows in the same database):

    EXEC dbo.sp_TexasHoldEm @PlayerName = N'Brent';
    EXEC dbo.sp_TexasHoldEm @Action = 'CALL';
    EXEC dbo.sp_TexasHoldEm @Action = 'CHECK';
    EXEC dbo.sp_TexasHoldEm @Action = 'RAISE', @Amount = 40;
    EXEC dbo.sp_TexasHoldEm @Action = 'FOLD';

@Amount is the total number of QueryBucks the player wants to have wagered
on the current betting street (a "raise to" amount, not a "raise by" amount).

Other commands:

    EXEC dbo.sp_TexasHoldEm;                         -- join, watch, or refresh
    EXEC dbo.sp_TexasHoldEm @Action = 'ALLIN';       -- wager the table maximum
    EXEC dbo.sp_TexasHoldEm @Action = 'RESET';       -- abandon and reset the game
    EXEC dbo.sp_TexasHoldEm @Action = 'NEWGAME';     -- restart after GAME OVER

Simplifications:
  * Four seats, 1,000 starting QueryBucks, and 5/10 blinds.
  * Raises may be any amount at least 10 QueryBucks above the current bet,
    up to the no-side-pot table maximum. @Amount is the raise-to total.
  * There are no side pots. The maximum street wager is capped at the amount
    the shortest live stack can cover.
  * Robots use a deliberately simple strategy.
  * Turn and one-player-between-hands waits expire after 60 seconds, but an
    invocation is required to observe and process expiry. If the acting player
    submits an action before another invocation processes the deadline, that
    action wins the race and is accepted.
  * A timed-out human folds, leaves the table after the hand, and may request
    a seat again by invoking the procedure if they still have QueryBucks.
  * Global temporary state can disappear when its creating session disconnects.

The procedure returns three result sets:
  1. Game state and the viewer's prompt.
  2. Seats, stacks, visible cards, and showdown hand descriptions.
  3. The public table log for the current hand.
*/

IF CERT_ID(N'sp_TexasHoldEm_CardProtection_Codex') IS NULL
BEGIN
    CREATE CERTIFICATE sp_TexasHoldEm_CardProtection_Codex
        ENCRYPTION BY PASSWORD = 'QueryBucks-Codex-demo-certificate-2026!'
        WITH SUBJECT = 'Encrypt transient sp_TexasHoldEm hole cards',
             EXPIRY_DATE = '20991231';
END;
GO

DENY CONTROL ON CERTIFICATE::sp_TexasHoldEm_CardProtection_Codex TO public;
GO

IF OBJECT_ID(N'dbo.sp_TexasHoldEm', N'P') IS NULL
    EXEC(N'CREATE PROCEDURE dbo.sp_TexasHoldEm AS RETURN 0;');
GO

ALTER PROCEDURE dbo.sp_TexasHoldEm
    @Action     varchar(20) = NULL,
    @Amount     int = NULL,
    @PlayerName nvarchar(50) = NULL
WITH EXECUTE AS OWNER
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    DECLARE
        @DatabaseId       int = DB_ID(),
        @SessionId        int = @@SPID,
        @Now              datetime2(0),
        @InputAction      varchar(20),
        @OriginalAction   varchar(20),
        @ReadOnlySnapshot bit = 0,
        @ActionConsumed   bit = 0,
        @KeepWaiting      bit = 0,
        @LockResult       int,
        @Phase            varchar(12),
        @Notice           nvarchar(4000) = NULL,
        @HandJustEnded    bit = 0,
        @StartHand        bit = 0,
        @LoopGuard        int = 0;

    SET @OriginalAction = UPPER(LTRIM(RTRIM(COALESCE(@Action, ''))));
    SET @InputAction = NULLIF(@OriginalAction, '');
    IF @OriginalAction IN ('STATUS', 'REFRESH')
        SET @ReadOnlySnapshot = 1;
    IF @InputAction IN ('JOIN', 'WATCH', 'STATUS', 'REFRESH')
        SET @InputAction = NULL;

    IF @InputAction IS NOT NULL
       AND @InputAction NOT IN ('CHECK', 'CALL', 'BET', 'RAISE', 'FOLD', 'ALLIN', 'RESET', 'NEWGAME')
    BEGIN
        THROW 50001, 'Unknown action. Use CHECK, CALL, BET, RAISE, FOLD, ALLIN, RESET, or NEWGAME.', 1;
    END;

    IF @Amount IS NOT NULL AND @Amount < 0
        THROW 50002, '@Amount cannot be negative.', 1;

    /*
    Lobby calls poll once per second. This lets the first caller wait for the
    full signup window while calls from other sessions can still join and make
    a four-human table start immediately.
    */
    WHILE 1 = 1
    BEGIN
        SET @Now = SYSUTCDATETIME();
        SET @KeepWaiting = 0;
        SET @StartHand = 0;
        SET @HandJustEnded = 0;

        BEGIN TRANSACTION;

        EXEC @LockResult = sys.sp_getapplock
            @Resource = N'sp_TexasHoldEm_Codex_State_v1',
            @LockMode = 'Exclusive',
            @LockOwner = 'Transaction',
            @LockTimeout = 5000,
            @DbPrincipal = 'public';

        IF @LockResult < 0
        BEGIN
            ROLLBACK TRANSACTION;
            THROW 50003, 'The poker table is busy. Please try again.', 1;
        END;

        /* Fixed names let the procedure compile without permanent helper objects. */
        IF OBJECT_ID(N'tempdb..##TexasHoldEm_Game_Codex_v1') IS NULL
        BEGIN
            BEGIN TRY
                CREATE TABLE ##TexasHoldEm_Game_Codex_v1
                (
                    DatabaseId        int NOT NULL PRIMARY KEY,
                    GameId            uniqueidentifier NOT NULL,
                    Phase             varchar(12) NOT NULL,
                    HandNumber        int NOT NULL,
                    LobbyClosesAt     datetime2(0) NULL,
                    DealerSeat        tinyint NULL,
                    ActionSeat        tinyint NULL,
                    ActionDeadline    datetime2(0) NULL,
                    CurrentBet        int NOT NULL,
                    MinimumRaise      int NOT NULL,
                    Pot               int NOT NULL,
                    Board1            tinyint NULL,
                    Board2            tinyint NULL,
                    Board3            tinyint NULL,
                    Board4            tinyint NULL,
                    Board5            tinyint NULL,
                    BoardCardsVisible tinyint NOT NULL,
                    CreatedBySessionId int NOT NULL,
                    CreatedAt         datetime2(0) NOT NULL,
                    LastChangedAt     datetime2(0) NOT NULL
                );
            END TRY
            BEGIN CATCH
                IF OBJECT_ID(N'tempdb..##TexasHoldEm_Game_Codex_v1') IS NULL
                    THROW;
            END CATCH;
        END;

        IF OBJECT_ID(N'tempdb..##TexasHoldEm_Players_Codex_v1') IS NULL
        BEGIN
            BEGIN TRY
                CREATE TABLE ##TexasHoldEm_Players_Codex_v1
                (
                    DatabaseId     int NOT NULL,
                    SessionId      int NOT NULL,
                    PlayerName     nvarchar(50) NOT NULL,
                    Seat           tinyint NULL,
                    IsRobot        bit NOT NULL,
                    PlayerRole     varchar(12) NOT NULL,
                    QueryBucks     int NOT NULL,
                    WantsSeat      bit NOT NULL,
                    InHand         bit NOT NULL,
                    Folded         bit NOT NULL,
                    TimedOut       bit NOT NULL,
                    HoleCardsEncrypted varbinary(8000) NULL,
                    StreetBet      int NOT NULL,
                    HandBet        int NOT NULL,
                    ActedThisStreet bit NOT NULL,
                    ShowCards      bit NOT NULL,
                    HandScore      bigint NULL,
                    HandDescription varchar(30) NULL,
                    JoinedAt       datetime2(0) NOT NULL,
                    LastSeenAt     datetime2(0) NOT NULL,
                    CONSTRAINT PK_TexasHoldEm_Players_Codex_v1
                        PRIMARY KEY (DatabaseId, SessionId)
                );
            END TRY
            BEGIN CATCH
                IF OBJECT_ID(N'tempdb..##TexasHoldEm_Players_Codex_v1') IS NULL
                    THROW;
            END CATCH;
        END;

        IF OBJECT_ID(N'tempdb..##TexasHoldEm_Log_Codex_v1') IS NULL
        BEGIN
            BEGIN TRY
                CREATE TABLE ##TexasHoldEm_Log_Codex_v1
                (
                    LogId       bigint IDENTITY(1,1) NOT NULL PRIMARY KEY,
                    DatabaseId  int NOT NULL,
                    HandNumber  int NOT NULL,
                    LoggedAt    datetime2(0) NOT NULL,
                    Message     nvarchar(1000) NOT NULL
                );
            END TRY
            BEGIN CATCH
                IF OBJECT_ID(N'tempdb..##TexasHoldEm_Log_Codex_v1') IS NULL
                    THROW;
            END CATCH;
        END;

        /* RESET is intentionally available for live demos where a table gets stuck. */
        IF @InputAction = 'RESET'
        BEGIN
            DELETE FROM ##TexasHoldEm_Log_Codex_v1 WHERE DatabaseId = @DatabaseId;
            DELETE FROM ##TexasHoldEm_Players_Codex_v1 WHERE DatabaseId = @DatabaseId;
            DELETE FROM ##TexasHoldEm_Game_Codex_v1 WHERE DatabaseId = @DatabaseId;
            SET @InputAction = NULL;
            SET @ActionConsumed = 1;
            SET @Notice = N'The table was reset. A new 60-second lobby is open.';
        END;

        IF @InputAction = 'NEWGAME'
        BEGIN
            IF EXISTS
            (
                SELECT 1
                FROM ##TexasHoldEm_Game_Codex_v1
                WHERE DatabaseId = @DatabaseId
                  AND Phase <> 'GAMEOVER'
            )
            BEGIN
                SET @Notice = N'NEWGAME is available after GAME OVER. Use RESET to abandon a running game.';
                SET @ActionConsumed = 1;
            END
            ELSE
            BEGIN
                DELETE FROM ##TexasHoldEm_Log_Codex_v1 WHERE DatabaseId = @DatabaseId;
                DELETE FROM ##TexasHoldEm_Players_Codex_v1 WHERE DatabaseId = @DatabaseId;
                DELETE FROM ##TexasHoldEm_Game_Codex_v1 WHERE DatabaseId = @DatabaseId;
                SET @InputAction = NULL;
                SET @ActionConsumed = 1;
                SET @Notice = N'A new game and 60-second lobby have started.';
            END;
        END;

        IF NOT EXISTS
        (
            SELECT 1
            FROM ##TexasHoldEm_Game_Codex_v1
            WHERE DatabaseId = @DatabaseId
        )
        BEGIN
            INSERT ##TexasHoldEm_Game_Codex_v1
            (
                DatabaseId, GameId, Phase, HandNumber, LobbyClosesAt,
                DealerSeat, ActionSeat, ActionDeadline, CurrentBet,
                MinimumRaise, Pot, Board1, Board2, Board3, Board4, Board5,
                BoardCardsVisible, CreatedBySessionId, CreatedAt, LastChangedAt
            )
            VALUES
            (
                @DatabaseId, NEWID(), 'LOBBY', 0, DATEADD(second, 60, @Now),
                NULL, NULL, NULL, 0, 10, 0, NULL, NULL, NULL, NULL, NULL,
                0, @SessionId, @Now, @Now
            );

            INSERT ##TexasHoldEm_Log_Codex_v1 (DatabaseId, HandNumber, LoggedAt, Message)
            VALUES (@DatabaseId, 0, @Now,
                N'The table opened. Up to four human players may join for 60 seconds.');
        END;

        SELECT @Phase = Phase
        FROM ##TexasHoldEm_Game_Codex_v1
        WHERE DatabaseId = @DatabaseId;

        IF @InputAction IN ('CHECK', 'CALL', 'BET', 'RAISE', 'FOLD', 'ALLIN')
           AND @Phase NOT IN ('PREFLOP', 'FLOP', 'TURN', 'RIVER')
        BEGIN
            SET @Notice = COALESCE(@Notice + N' ', N'')
                + N'No betting action was pending; ' + @InputAction + N' was ignored.';
            SET @ActionConsumed = 1;
        END;

        /* Register this SQL session as a player or spectator. */
        IF NOT EXISTS
        (
            SELECT 1
            FROM ##TexasHoldEm_Players_Codex_v1
            WHERE DatabaseId = @DatabaseId
              AND SessionId = @SessionId
        )
           AND @ReadOnlySnapshot = 0
        BEGIN
            DECLARE @OpenSeat tinyint = NULL;

            IF @Phase = 'LOBBY'
               AND @OriginalAction <> 'WATCH'
               AND (SELECT COUNT(*)
                    FROM ##TexasHoldEm_Players_Codex_v1
                    WHERE DatabaseId = @DatabaseId
                      AND PlayerRole = 'PLAYER') < 4
            BEGIN
                SELECT TOP (1) @OpenSeat = s.Seat
                FROM (VALUES (1), (2), (3), (4)) AS s(Seat)
                WHERE NOT EXISTS
                (
                    SELECT 1
                    FROM ##TexasHoldEm_Players_Codex_v1 AS p
                    WHERE p.DatabaseId = @DatabaseId
                      AND p.Seat = s.Seat
                      AND p.PlayerRole = 'PLAYER'
                )
                ORDER BY s.Seat;
            END;

            INSERT ##TexasHoldEm_Players_Codex_v1
            (
                DatabaseId, SessionId, PlayerName, Seat, IsRobot, PlayerRole,
                QueryBucks, WantsSeat, InHand, Folded, TimedOut,
                HoleCardsEncrypted, StreetBet, HandBet, ActedThisStreet,
                ShowCards, HandScore, HandDescription, JoinedAt, LastSeenAt
            )
            VALUES
            (
                @DatabaseId, @SessionId,
                COALESCE(NULLIF(@PlayerName, N''), N'Session ' + CONVERT(nvarchar(12), @SessionId)),
                @OpenSeat, 0, CASE WHEN @OpenSeat IS NULL THEN 'SPECTATOR' ELSE 'PLAYER' END,
                1000, CASE WHEN @OpenSeat IS NOT NULL OR @OriginalAction = 'WATCH' THEN 0 ELSE 1 END,
                0, 0, 0, NULL, 0, 0, 0, 0, NULL, NULL, @Now, @Now
            );

            INSERT ##TexasHoldEm_Log_Codex_v1 (DatabaseId, HandNumber, LoggedAt, Message)
            SELECT @DatabaseId, HandNumber, @Now,
                COALESCE(NULLIF(@PlayerName, N''), N'Session ' + CONVERT(nvarchar(12), @SessionId))
                + CASE WHEN @OpenSeat IS NOT NULL
                       THEN N' joined in seat ' + CONVERT(nvarchar(3), @OpenSeat) + N'.'
                       WHEN @OriginalAction = 'WATCH'
                       THEN N' is watching from the rail.'
                       ELSE N' is watching and has requested the next available seat.'
                  END
            FROM ##TexasHoldEm_Game_Codex_v1
            WHERE DatabaseId = @DatabaseId;
        END
        ELSE IF @ReadOnlySnapshot = 0
        BEGIN
            UPDATE ##TexasHoldEm_Players_Codex_v1
            SET PlayerName = COALESCE(NULLIF(@PlayerName, N''), PlayerName),
                LastSeenAt = @Now,
                WantsSeat = CASE
                    WHEN PlayerRole = 'SPECTATOR' AND @OriginalAction = 'WATCH' THEN 0
                    WHEN PlayerRole = 'SPECTATOR' AND QueryBucks > 0
                         AND @OriginalAction NOT IN ('STATUS', 'REFRESH', 'WATCH') THEN 1
                    ELSE WantsSeat
                END
            WHERE DatabaseId = @DatabaseId
              AND SessionId = @SessionId;
        END;

        /* The lobby fills empty seats with robots at 60 seconds, or starts at four humans. */
        IF @Phase = 'LOBBY'
        BEGIN
            DECLARE @LobbyClosesAt datetime2(0), @LobbyPlayers int;

            SELECT @LobbyClosesAt = LobbyClosesAt
            FROM ##TexasHoldEm_Game_Codex_v1
            WHERE DatabaseId = @DatabaseId;

            SELECT @LobbyPlayers = COUNT(*)
            FROM ##TexasHoldEm_Players_Codex_v1
            WHERE DatabaseId = @DatabaseId
              AND PlayerRole = 'PLAYER';

            IF @LobbyPlayers >= 4 OR @Now >= @LobbyClosesAt
            BEGIN
                WHILE @LobbyPlayers < 4
                BEGIN
                    DECLARE @RobotSeat tinyint;

                    SELECT TOP (1) @RobotSeat = s.Seat
                    FROM (VALUES (1), (2), (3), (4)) AS s(Seat)
                    WHERE NOT EXISTS
                    (
                        SELECT 1
                        FROM ##TexasHoldEm_Players_Codex_v1 AS p
                        WHERE p.DatabaseId = @DatabaseId
                          AND p.Seat = s.Seat
                          AND p.PlayerRole = 'PLAYER'
                    )
                    ORDER BY s.Seat;

                    INSERT ##TexasHoldEm_Players_Codex_v1
                    (
                        DatabaseId, SessionId, PlayerName, Seat, IsRobot, PlayerRole,
                        QueryBucks, WantsSeat, InHand, Folded, TimedOut,
                        HoleCardsEncrypted, StreetBet, HandBet, ActedThisStreet,
                        ShowCards, HandScore, HandDescription, JoinedAt, LastSeenAt
                    )
                    VALUES
                    (
                        @DatabaseId, -100000 - @RobotSeat,
                        N'QueryBot ' + CONVERT(nvarchar(3), @RobotSeat), @RobotSeat,
                        1, 'PLAYER', 1000, 0, 0, 0, 0, NULL,
                        0, 0, 0, 0, NULL, NULL, @Now, @Now
                    );

                    SET @LobbyPlayers += 1;
                END;

                SET @StartHand = 1;
            END
            ELSE
                SET @KeepWaiting = 1;
        END;

        /* Between hands, busted/time-out seats open and waiting humans replace robots first. */
        IF @Phase = 'BETWEEN' AND @HandJustEnded = 0
        BEGIN
            UPDATE ##TexasHoldEm_Players_Codex_v1
            SET Seat = NULL,
                PlayerRole = CASE WHEN QueryBucks <= 0 THEN 'OUT' ELSE 'SPECTATOR' END,
                WantsSeat = CASE WHEN QueryBucks <= 0 OR TimedOut = 1 THEN 0 ELSE WantsSeat END,
                InHand = 0
            WHERE DatabaseId = @DatabaseId
              AND PlayerRole = 'PLAYER'
              AND (QueryBucks <= 0 OR TimedOut = 1);

            /* A waiting human gets a robot's seat and inherits no robot money. */
            WHILE EXISTS
            (
                SELECT 1
                FROM ##TexasHoldEm_Players_Codex_v1
                WHERE DatabaseId = @DatabaseId
                  AND PlayerRole = 'SPECTATOR'
                  AND IsRobot = 0
                  AND WantsSeat = 1
                  AND QueryBucks > 0
            )
            AND EXISTS
            (
                SELECT 1
                FROM ##TexasHoldEm_Players_Codex_v1
                WHERE DatabaseId = @DatabaseId
                  AND PlayerRole = 'PLAYER'
                  AND IsRobot = 1
            )
            BEGIN
                DECLARE @WaitingSession int, @ReplacedSeat tinyint, @RemovedRobot int;

                SELECT TOP (1) @WaitingSession = SessionId
                FROM ##TexasHoldEm_Players_Codex_v1
                WHERE DatabaseId = @DatabaseId
                  AND PlayerRole = 'SPECTATOR'
                  AND IsRobot = 0
                  AND WantsSeat = 1
                  AND QueryBucks > 0
                ORDER BY JoinedAt, SessionId;

                SELECT TOP (1)
                    @RemovedRobot = SessionId,
                    @ReplacedSeat = Seat
                FROM ##TexasHoldEm_Players_Codex_v1
                WHERE DatabaseId = @DatabaseId
                  AND PlayerRole = 'PLAYER'
                  AND IsRobot = 1
                ORDER BY Seat DESC;

                DELETE FROM ##TexasHoldEm_Players_Codex_v1
                WHERE DatabaseId = @DatabaseId
                  AND SessionId = @RemovedRobot;

                UPDATE ##TexasHoldEm_Players_Codex_v1
                SET Seat = @ReplacedSeat,
                    PlayerRole = 'PLAYER',
                    WantsSeat = 0,
                    TimedOut = 0
                WHERE DatabaseId = @DatabaseId
                  AND SessionId = @WaitingSession;

                INSERT ##TexasHoldEm_Log_Codex_v1 (DatabaseId, HandNumber, LoggedAt, Message)
                SELECT @DatabaseId, HandNumber, @Now,
                    (SELECT PlayerName
                     FROM ##TexasHoldEm_Players_Codex_v1
                     WHERE DatabaseId = @DatabaseId AND SessionId = @WaitingSession)
                    + N' took seat ' + CONVERT(nvarchar(3), @ReplacedSeat) + N'.'
                FROM ##TexasHoldEm_Game_Codex_v1
                WHERE DatabaseId = @DatabaseId;
            END;

            /* Fill genuinely empty seats from the waiting list. */
            WHILE (SELECT COUNT(*)
                   FROM ##TexasHoldEm_Players_Codex_v1
                   WHERE DatabaseId = @DatabaseId
                     AND PlayerRole = 'PLAYER'
                     AND QueryBucks > 0) < 4
              AND EXISTS
              (
                  SELECT 1
                  FROM ##TexasHoldEm_Players_Codex_v1
                  WHERE DatabaseId = @DatabaseId
                    AND PlayerRole = 'SPECTATOR'
                    AND IsRobot = 0
                    AND WantsSeat = 1
                    AND QueryBucks > 0
              )
            BEGIN
                DECLARE @EmptySeat tinyint, @AdmittedSession int;

                SELECT TOP (1) @EmptySeat = s.Seat
                FROM (VALUES (1), (2), (3), (4)) AS s(Seat)
                WHERE NOT EXISTS
                (
                    SELECT 1
                    FROM ##TexasHoldEm_Players_Codex_v1 AS p
                    WHERE p.DatabaseId = @DatabaseId
                      AND p.PlayerRole = 'PLAYER'
                      AND p.Seat = s.Seat
                )
                ORDER BY s.Seat;

                SELECT TOP (1) @AdmittedSession = SessionId
                FROM ##TexasHoldEm_Players_Codex_v1
                WHERE DatabaseId = @DatabaseId
                  AND PlayerRole = 'SPECTATOR'
                  AND IsRobot = 0
                  AND WantsSeat = 1
                  AND QueryBucks > 0
                ORDER BY JoinedAt, SessionId;

                UPDATE ##TexasHoldEm_Players_Codex_v1
                SET Seat = @EmptySeat,
                    PlayerRole = 'PLAYER',
                    WantsSeat = 0,
                    TimedOut = 0
                WHERE DatabaseId = @DatabaseId
                  AND SessionId = @AdmittedSession;
            END;

            DECLARE @FundedPlayers int, @BetweenClosesAt datetime2(0);

            SELECT @FundedPlayers = COUNT(*)
            FROM ##TexasHoldEm_Players_Codex_v1
            WHERE DatabaseId = @DatabaseId
              AND PlayerRole = 'PLAYER'
              AND QueryBucks > 0;

            SELECT @BetweenClosesAt = LobbyClosesAt
            FROM ##TexasHoldEm_Game_Codex_v1
            WHERE DatabaseId = @DatabaseId;

            IF @FundedPlayers >= 2
                SET @StartHand = 1;
            ELSE IF @Now < @BetweenClosesAt
                SET @KeepWaiting = 1;
            ELSE
            BEGIN
                DECLARE @Champion nvarchar(50);

                SELECT TOP (1) @Champion = PlayerName
                FROM ##TexasHoldEm_Players_Codex_v1
                WHERE DatabaseId = @DatabaseId
                  AND PlayerRole = 'PLAYER'
                  AND QueryBucks > 0;

                UPDATE ##TexasHoldEm_Game_Codex_v1
                SET Phase = 'GAMEOVER',
                    ActionSeat = NULL,
                    ActionDeadline = NULL,
                    LastChangedAt = @Now
                WHERE DatabaseId = @DatabaseId;

                INSERT ##TexasHoldEm_Log_Codex_v1 (DatabaseId, HandNumber, LoggedAt, Message)
                SELECT @DatabaseId, HandNumber, @Now,
                    COALESCE(@Champion, N'Nobody') + N' won the game.'
                FROM ##TexasHoldEm_Game_Codex_v1
                WHERE DatabaseId = @DatabaseId;

                SET @Phase = 'GAMEOVER';
            END;
        END;

        /* Deal and post blinds. This block is shared by the lobby and later hands. */
        IF @StartHand = 1
        BEGIN
            DECLARE
                @OldDealer tinyint,
                @Dealer tinyint,
                @SmallBlindSeat tinyint,
                @BigBlindSeat tinyint,
                @FirstActionSeat tinyint,
                @PlayerCount int,
                @ShortestStack int,
                @SmallBlind int,
                @BigBlind int,
                @NewHand int;

            SELECT @OldDealer = DealerSeat, @NewHand = HandNumber + 1
            FROM ##TexasHoldEm_Game_Codex_v1
            WHERE DatabaseId = @DatabaseId;

            UPDATE ##TexasHoldEm_Players_Codex_v1
            SET InHand = CASE WHEN PlayerRole = 'PLAYER' AND QueryBucks > 0 THEN 1 ELSE 0 END,
                Folded = 0,
                TimedOut = 0,
                HoleCardsEncrypted = NULL,
                StreetBet = 0,
                HandBet = 0,
                ActedThisStreet = 0,
                ShowCards = 0,
                HandScore = NULL,
                HandDescription = NULL
            WHERE DatabaseId = @DatabaseId;

            SELECT @PlayerCount = COUNT(*), @ShortestStack = MIN(QueryBucks)
            FROM ##TexasHoldEm_Players_Codex_v1
            WHERE DatabaseId = @DatabaseId
              AND InHand = 1;

            SELECT TOP (1) @Dealer = Seat
            FROM ##TexasHoldEm_Players_Codex_v1
            WHERE DatabaseId = @DatabaseId
              AND InHand = 1
            ORDER BY CASE WHEN @OldDealer IS NULL OR Seat > @OldDealer THEN 0 ELSE 1 END, Seat;

            IF OBJECT_ID(N'tempdb..#TexasDeck') IS NOT NULL DROP TABLE #TexasDeck;
            IF OBJECT_ID(N'tempdb..#TexasDealOrder') IS NOT NULL DROP TABLE #TexasDealOrder;

            ;WITH N AS
            (
                SELECT TOP (52)
                    ROW_NUMBER() OVER (ORDER BY (SELECT NULL)) AS CardId
                FROM (VALUES (0),(0),(0),(0),(0),(0),(0),(0)) AS a(n)
                CROSS JOIN (VALUES (0),(0),(0),(0),(0),(0),(0),(0)) AS b(n)
            )
            SELECT
                CONVERT(tinyint, CardId) AS CardId,
                ROW_NUMBER() OVER (ORDER BY NEWID()) AS ShufflePosition
            INTO #TexasDeck
            FROM N;

            SELECT
                SessionId,
                ROW_NUMBER() OVER (ORDER BY Seat) AS DealPosition
            INTO #TexasDealOrder
            FROM ##TexasHoldEm_Players_Codex_v1
            WHERE DatabaseId = @DatabaseId
              AND InHand = 1;

            UPDATE p
            SET HoleCardsEncrypted = EncryptByCert
                (
                    CERT_ID(N'sp_TexasHoldEm_CardProtection_Codex'),
                    CONVERT(varbinary(1), d1.CardId) + CONVERT(varbinary(1), d2.CardId)
                )
            FROM ##TexasHoldEm_Players_Codex_v1 AS p
            INNER JOIN #TexasDealOrder AS o ON o.SessionId = p.SessionId
            INNER JOIN #TexasDeck AS d1 ON d1.ShufflePosition = o.DealPosition
            INNER JOIN #TexasDeck AS d2 ON d2.ShufflePosition = @PlayerCount + o.DealPosition
            WHERE p.DatabaseId = @DatabaseId;

            DECLARE @B1 tinyint, @B2 tinyint, @B3 tinyint, @B4 tinyint, @B5 tinyint;

            SELECT @B1 = CardId FROM #TexasDeck WHERE ShufflePosition = @PlayerCount * 2 + 1;
            SELECT @B2 = CardId FROM #TexasDeck WHERE ShufflePosition = @PlayerCount * 2 + 2;
            SELECT @B3 = CardId FROM #TexasDeck WHERE ShufflePosition = @PlayerCount * 2 + 3;
            SELECT @B4 = CardId FROM #TexasDeck WHERE ShufflePosition = @PlayerCount * 2 + 4;
            SELECT @B5 = CardId FROM #TexasDeck WHERE ShufflePosition = @PlayerCount * 2 + 5;

            IF @PlayerCount = 2
                SET @SmallBlindSeat = @Dealer;
            ELSE
                SELECT TOP (1) @SmallBlindSeat = Seat
                FROM ##TexasHoldEm_Players_Codex_v1
                WHERE DatabaseId = @DatabaseId
                  AND InHand = 1
                ORDER BY CASE WHEN Seat > @Dealer THEN 0 ELSE 1 END, Seat;

            SELECT TOP (1) @BigBlindSeat = Seat
            FROM ##TexasHoldEm_Players_Codex_v1
            WHERE DatabaseId = @DatabaseId
              AND InHand = 1
              AND Seat <> @SmallBlindSeat
            ORDER BY CASE WHEN Seat > @SmallBlindSeat THEN 0 ELSE 1 END, Seat;

            SELECT TOP (1) @FirstActionSeat = Seat
            FROM ##TexasHoldEm_Players_Codex_v1
            WHERE DatabaseId = @DatabaseId
              AND InHand = 1
            ORDER BY CASE WHEN Seat > @BigBlindSeat THEN 0 ELSE 1 END, Seat;

            SET @BigBlind = CASE WHEN @ShortestStack < 10 THEN @ShortestStack ELSE 10 END;
            SET @SmallBlind = CASE WHEN @BigBlind < 5 THEN @BigBlind ELSE 5 END;

            UPDATE ##TexasHoldEm_Players_Codex_v1
            SET QueryBucks = QueryBucks - CASE
                    WHEN Seat = @SmallBlindSeat THEN @SmallBlind
                    WHEN Seat = @BigBlindSeat THEN @BigBlind
                    ELSE 0
                END,
                StreetBet = CASE
                    WHEN Seat = @SmallBlindSeat THEN @SmallBlind
                    WHEN Seat = @BigBlindSeat THEN @BigBlind
                    ELSE 0
                END,
                HandBet = CASE
                    WHEN Seat = @SmallBlindSeat THEN @SmallBlind
                    WHEN Seat = @BigBlindSeat THEN @BigBlind
                    ELSE 0
                END
            WHERE DatabaseId = @DatabaseId
              AND InHand = 1;

            UPDATE ##TexasHoldEm_Game_Codex_v1
            SET Phase = 'PREFLOP',
                HandNumber = @NewHand,
                LobbyClosesAt = NULL,
                DealerSeat = @Dealer,
                ActionSeat = @FirstActionSeat,
                ActionDeadline = DATEADD(second, 60, @Now),
                CurrentBet = @BigBlind,
                MinimumRaise = 10,
                Pot = @SmallBlind + @BigBlind,
                Board1 = @B1,
                Board2 = @B2,
                Board3 = @B3,
                Board4 = @B4,
                Board5 = @B5,
                BoardCardsVisible = 0,
                LastChangedAt = @Now
            WHERE DatabaseId = @DatabaseId;

            INSERT ##TexasHoldEm_Log_Codex_v1 (DatabaseId, HandNumber, LoggedAt, Message)
            VALUES
            (
                @DatabaseId, @NewHand, @Now,
                N'Hand ' + CONVERT(nvarchar(12), @NewHand) + N' began. '
                + (SELECT PlayerName FROM ##TexasHoldEm_Players_Codex_v1
                   WHERE DatabaseId = @DatabaseId AND Seat = @SmallBlindSeat AND PlayerRole = 'PLAYER')
                + N' posted ' + CONVERT(nvarchar(12), @SmallBlind) + N'; '
                + (SELECT PlayerName FROM ##TexasHoldEm_Players_Codex_v1
                   WHERE DatabaseId = @DatabaseId AND Seat = @BigBlindSeat AND PlayerRole = 'PLAYER')
                + N' posted ' + CONVERT(nvarchar(12), @BigBlind) + N'.'
            );

            SET @Phase = 'PREFLOP';
            SET @KeepWaiting = 0;
        END;

        /*
        Advance robot turns, expired human turns, and the caller's one supplied
        action until another live human decision is needed or the hand ends.
        */
        WHILE @Phase IN ('PREFLOP', 'FLOP', 'TURN', 'RIVER')
        BEGIN
            SET @LoopGuard += 1;
            IF @LoopGuard > 200
            BEGIN
                ROLLBACK TRANSACTION;
                THROW 50004, 'The poker action loop exceeded its safety limit.', 1;
            END;

            DECLARE
                @ActionSeat tinyint,
                @ActionSession int,
                @ActionPlayer nvarchar(50),
                @IsRobot bit,
                @Deadline datetime2(0),
                @CurrentBet int,
                @MinimumRaise int,
                @StreetBet int,
                @Stack int,
                @ToCall int,
                @TableMaximum int,
                @TurnAction varchar(20) = NULL,
                @TargetBet int = NULL,
                @Pay int = 0,
                @Legal bit = 1,
                @Random int,
                @HoleRank1 int,
                @HoleRank2 int;

            SELECT
                @ActionSeat = g.ActionSeat,
                @Deadline = g.ActionDeadline,
                @CurrentBet = g.CurrentBet,
                @MinimumRaise = g.MinimumRaise,
                @Phase = g.Phase
            FROM ##TexasHoldEm_Game_Codex_v1 AS g
            WHERE g.DatabaseId = @DatabaseId;

            SELECT
                @ActionSession = p.SessionId,
                @ActionPlayer = p.PlayerName,
                @IsRobot = p.IsRobot,
                @StreetBet = p.StreetBet,
                @Stack = p.QueryBucks,
                @HoleRank1 = ((CONVERT(int, SUBSTRING(h.HoleCards, 1, 1)) - 1) % 13) + 2,
                @HoleRank2 = ((CONVERT(int, SUBSTRING(h.HoleCards, 2, 1)) - 1) % 13) + 2
            FROM ##TexasHoldEm_Players_Codex_v1 AS p
            CROSS APPLY
            (
                VALUES
                (
                    CONVERT(varbinary(2), DecryptByCert
                    (
                        CERT_ID(N'sp_TexasHoldEm_CardProtection_Codex'),
                        p.HoleCardsEncrypted,
                        N'QueryBucks-Codex-demo-certificate-2026!'
                    ))
                )
            ) AS h(HoleCards)
            WHERE p.DatabaseId = @DatabaseId
              AND p.Seat = @ActionSeat
              AND p.InHand = 1
              AND p.Folded = 0;

            SET @ToCall = @CurrentBet - @StreetBet;

            SELECT @TableMaximum = MIN(StreetBet + QueryBucks)
            FROM ##TexasHoldEm_Players_Codex_v1
            WHERE DatabaseId = @DatabaseId
              AND InHand = 1
              AND Folded = 0;

            /* A player who is already all-in never has to click through later streets. */
            IF @Stack = 0 AND @ToCall = 0
                SET @TurnAction = 'CHECK';
            ELSE IF @IsRobot = 1
            BEGIN
                SET @Random = CONVERT(int, CONVERT(bigint, CHECKSUM(NEWID())) & 2147483647) % 100;

                IF @ToCall > 0
                BEGIN
                    IF (@HoleRank1 <> @HoleRank2 AND @HoleRank1 < 10 AND @HoleRank2 < 10 AND @Random < 22)
                       OR (@ToCall > (@Stack / 3) AND @Random < 35)
                        SET @TurnAction = 'FOLD';
                    ELSE IF (@HoleRank1 = @HoleRank2 OR @HoleRank1 >= 12 OR @HoleRank2 >= 12)
                         AND @Random >= 82
                         AND @TableMaximum > @CurrentBet
                    BEGIN
                        SET @TurnAction = 'RAISE';
                        SET @TargetBet = CASE
                            WHEN @CurrentBet + @MinimumRaise > @TableMaximum THEN @TableMaximum
                            ELSE @CurrentBet + @MinimumRaise
                        END;
                    END
                    ELSE
                        SET @TurnAction = 'CALL';
                END
                ELSE IF (@HoleRank1 = @HoleRank2 OR @HoleRank1 >= 13 OR @HoleRank2 >= 13 OR @Random >= 80)
                     AND @TableMaximum > @CurrentBet
                BEGIN
                    SET @TurnAction = CASE WHEN @CurrentBet = 0 THEN 'BET' ELSE 'RAISE' END;
                    SET @TargetBet = CASE
                        WHEN @CurrentBet + @MinimumRaise > @TableMaximum THEN @TableMaximum
                        ELSE @CurrentBet + @MinimumRaise
                    END;
                END
                ELSE
                    SET @TurnAction = 'CHECK';
            END
            ELSE IF @ActionSession = @SessionId AND @ActionConsumed = 0 AND @InputAction IS NOT NULL
            BEGIN
                SET @TurnAction = @InputAction;
                SET @TargetBet = @Amount;
                SET @ActionConsumed = 1;
            END
            ELSE IF @Now >= @Deadline
            BEGIN
                SET @TurnAction = 'FOLD';
                UPDATE ##TexasHoldEm_Players_Codex_v1
                SET TimedOut = 1,
                    WantsSeat = 0
                WHERE DatabaseId = @DatabaseId
                  AND SessionId = @ActionSession;
                SET @Notice = COALESCE(@Notice + N' ', N'') + @ActionPlayer + N' timed out and folded.';
            END
            ELSE
            BEGIN
                IF @ActionConsumed = 0 AND @InputAction IS NOT NULL
                BEGIN
                    SET @Notice = COALESCE(@Notice + N' ', N'')
                        + N'It is ' + @ActionPlayer + N'''s turn. Your action was not applied.';
                    SET @ActionConsumed = 1;
                END;
                BREAK;
            END;

            IF @TurnAction = 'CHECK' AND @ToCall <> 0
            BEGIN
                SET @Legal = 0;
                SET @Notice = COALESCE(@Notice + N' ', N'')
                    + N'CHECK is not legal when ' + CONVERT(nvarchar(12), @ToCall)
                    + N' QueryBucks are needed to call.';
            END
            ELSE IF @TurnAction = 'CALL' AND @ToCall <= 0
            BEGIN
                SET @Legal = 0;
                SET @Notice = COALESCE(@Notice + N' ', N'')
                    + N'Nothing needs to be called; use CHECK instead.';
            END
            ELSE IF @TurnAction IN ('BET', 'RAISE')
            BEGIN
                IF @TargetBet IS NULL
                BEGIN
                    SET @Legal = 0;
                    SET @Notice = COALESCE(@Notice + N' ', N'')
                        + N'BET and RAISE require @Amount. It is the total street wager (raise-to amount).';
                END
                ELSE IF @TargetBet <= @CurrentBet
                BEGIN
                    SET @Legal = 0;
                    SET @Notice = COALESCE(@Notice + N' ', N'')
                        + N'The target must be greater than the current bet of '
                        + CONVERT(nvarchar(12), @CurrentBet) + N'.';
                END
                ELSE IF @TargetBet > @TableMaximum
                BEGIN
                    SET @Legal = 0;
                    SET @Notice = COALESCE(@Notice + N' ', N'')
                        + N'The no-side-pot table maximum is '
                        + CONVERT(nvarchar(12), @TableMaximum) + N' QueryBucks this street.';
                END
                ELSE IF @TargetBet < @CurrentBet + @MinimumRaise AND @TargetBet <> @TableMaximum
                BEGIN
                    SET @Legal = 0;
                    SET @Notice = COALESCE(@Notice + N' ', N'')
                        + N'The minimum raise-to amount is '
                        + CONVERT(nvarchar(12), @CurrentBet + @MinimumRaise)
                        + N', unless moving to the table maximum.';
                END;
            END;

            IF @Legal = 0
                BREAK;

            IF @TurnAction = 'FOLD'
            BEGIN
                UPDATE ##TexasHoldEm_Players_Codex_v1
                SET Folded = 1,
                    ActedThisStreet = 1
                WHERE DatabaseId = @DatabaseId
                  AND SessionId = @ActionSession;

                INSERT ##TexasHoldEm_Log_Codex_v1 (DatabaseId, HandNumber, LoggedAt, Message)
                SELECT @DatabaseId, HandNumber, @Now, @ActionPlayer + N' folded.'
                FROM ##TexasHoldEm_Game_Codex_v1
                WHERE DatabaseId = @DatabaseId;
            END
            ELSE IF @TurnAction = 'CHECK'
            BEGIN
                UPDATE ##TexasHoldEm_Players_Codex_v1
                SET ActedThisStreet = 1
                WHERE DatabaseId = @DatabaseId
                  AND SessionId = @ActionSession;

                INSERT ##TexasHoldEm_Log_Codex_v1 (DatabaseId, HandNumber, LoggedAt, Message)
                SELECT @DatabaseId, HandNumber, @Now, @ActionPlayer + N' checked.'
                FROM ##TexasHoldEm_Game_Codex_v1
                WHERE DatabaseId = @DatabaseId;
            END
            ELSE
            BEGIN
                IF @TurnAction = 'CALL'
                    SET @TargetBet = @CurrentBet;
                ELSE IF @TurnAction = 'ALLIN'
                    SET @TargetBet = @TableMaximum;

                IF @TargetBet <= @CurrentBet
                    SET @TurnAction = CASE WHEN @ToCall > 0 THEN 'CALL' ELSE 'CHECK' END;

                SET @Pay = @TargetBet - @StreetBet;

                IF @TurnAction = 'CHECK'
                BEGIN
                    UPDATE ##TexasHoldEm_Players_Codex_v1
                    SET ActedThisStreet = 1
                    WHERE DatabaseId = @DatabaseId
                      AND SessionId = @ActionSession;
                END
                ELSE
                BEGIN
                    IF @TargetBet > @CurrentBet
                    BEGIN
                        UPDATE ##TexasHoldEm_Players_Codex_v1
                        SET ActedThisStreet = CASE WHEN SessionId = @ActionSession THEN 1 ELSE 0 END
                        WHERE DatabaseId = @DatabaseId
                          AND InHand = 1
                          AND Folded = 0;

                        UPDATE ##TexasHoldEm_Game_Codex_v1
                        SET CurrentBet = @TargetBet
                        WHERE DatabaseId = @DatabaseId;

                        SET @CurrentBet = @TargetBet;
                    END;

                    UPDATE ##TexasHoldEm_Players_Codex_v1
                    SET QueryBucks = QueryBucks - @Pay,
                        StreetBet = @TargetBet,
                        HandBet = HandBet + @Pay,
                        ActedThisStreet = 1
                    WHERE DatabaseId = @DatabaseId
                      AND SessionId = @ActionSession;

                    UPDATE ##TexasHoldEm_Game_Codex_v1
                    SET Pot = Pot + @Pay
                    WHERE DatabaseId = @DatabaseId;
                END;

                INSERT ##TexasHoldEm_Log_Codex_v1 (DatabaseId, HandNumber, LoggedAt, Message)
                SELECT @DatabaseId, HandNumber, @Now,
                    @ActionPlayer + CASE
                        WHEN @TurnAction = 'CHECK' THEN N' checked.'
                        WHEN @TurnAction = 'CALL' THEN N' called ' + CONVERT(nvarchar(12), @Pay) + N'.'
                        WHEN @TurnAction = 'ALLIN' THEN N' moved to the table maximum of ' + CONVERT(nvarchar(12), @TargetBet) + N'.'
                        ELSE N' raised to ' + CONVERT(nvarchar(12), @TargetBet) + N'.'
                    END
                FROM ##TexasHoldEm_Game_Codex_v1
                WHERE DatabaseId = @DatabaseId;
            END;

            /* A lone un-folded player wins without exposing hole cards. */
            IF (SELECT COUNT(*)
                FROM ##TexasHoldEm_Players_Codex_v1
                WHERE DatabaseId = @DatabaseId
                  AND InHand = 1
                  AND Folded = 0) = 1
            BEGIN
                DECLARE @FoldWinner int, @FoldWinnerName nvarchar(50), @FoldPot int;

                SELECT TOP (1) @FoldWinner = SessionId, @FoldWinnerName = PlayerName
                FROM ##TexasHoldEm_Players_Codex_v1
                WHERE DatabaseId = @DatabaseId
                  AND InHand = 1
                  AND Folded = 0;

                SELECT @FoldPot = Pot
                FROM ##TexasHoldEm_Game_Codex_v1
                WHERE DatabaseId = @DatabaseId;

                UPDATE ##TexasHoldEm_Players_Codex_v1
                SET QueryBucks = QueryBucks + @FoldPot
                WHERE DatabaseId = @DatabaseId
                  AND SessionId = @FoldWinner;

                UPDATE ##TexasHoldEm_Game_Codex_v1
                SET Phase = 'BETWEEN',
                    ActionSeat = NULL,
                    ActionDeadline = NULL,
                    LobbyClosesAt = DATEADD(second, 60, @Now),
                    CurrentBet = 0,
                    Pot = 0,
                    LastChangedAt = @Now
                WHERE DatabaseId = @DatabaseId;

                INSERT ##TexasHoldEm_Log_Codex_v1 (DatabaseId, HandNumber, LoggedAt, Message)
                SELECT @DatabaseId, HandNumber, @Now,
                    @FoldWinnerName + N' won the ' + CONVERT(nvarchar(12), @FoldPot)
                    + N'-QueryBuck pot; the other players folded.'
                FROM ##TexasHoldEm_Game_Codex_v1
                WHERE DatabaseId = @DatabaseId;

                SET @Phase = 'BETWEEN';
                SET @HandJustEnded = 1;
                BREAK;
            END;

            /* If everyone has acted and matched, expose the next street. */
            IF NOT EXISTS
            (
                SELECT 1
                FROM ##TexasHoldEm_Players_Codex_v1
                WHERE DatabaseId = @DatabaseId
                  AND InHand = 1
                  AND Folded = 0
                  AND (ActedThisStreet = 0 OR StreetBet < @CurrentBet)
            )
            BEGIN
                IF @Phase = 'RIVER'
                BEGIN
                    /* Evaluate every five-card combination from each live seven-card hand. */
                    IF OBJECT_ID(N'tempdb..#Seven') IS NOT NULL DROP TABLE #Seven;
                    IF OBJECT_ID(N'tempdb..#Five') IS NOT NULL DROP TABLE #Five;
                    IF OBJECT_ID(N'tempdb..#ComboStats') IS NOT NULL DROP TABLE #ComboStats;
                    IF OBJECT_ID(N'tempdb..#RankGroups') IS NOT NULL DROP TABLE #RankGroups;
                    IF OBJECT_ID(N'tempdb..#ComboScores') IS NOT NULL DROP TABLE #ComboScores;
                    IF OBJECT_ID(N'tempdb..#PlayerScores') IS NOT NULL DROP TABLE #PlayerScores;

                    SELECT
                        p.SessionId,
                        v.Position,
                        ((v.CardId - 1) % 13) + 2 AS RankValue,
                        (v.CardId - 1) / 13 AS SuitValue
                    INTO #Seven
                    FROM ##TexasHoldEm_Players_Codex_v1 AS p
                    CROSS JOIN ##TexasHoldEm_Game_Codex_v1 AS g
                    CROSS APPLY
                    (
                        VALUES
                        (
                            CONVERT(varbinary(2), DecryptByCert
                            (
                                CERT_ID(N'sp_TexasHoldEm_CardProtection_Codex'),
                                p.HoleCardsEncrypted,
                                N'QueryBucks-Codex-demo-certificate-2026!'
                            ))
                        )
                    ) AS h(HoleCards)
                    CROSS APPLY
                    (
                        VALUES
                            (1, CONVERT(tinyint, SUBSTRING(h.HoleCards, 1, 1))),
                            (2, CONVERT(tinyint, SUBSTRING(h.HoleCards, 2, 1))),
                            (3, g.Board1), (4, g.Board2), (5, g.Board3),
                            (6, g.Board4), (7, g.Board5)
                    ) AS v(Position, CardId)
                    WHERE p.DatabaseId = @DatabaseId
                      AND g.DatabaseId = @DatabaseId
                      AND p.InHand = 1
                      AND p.Folded = 0;

                    SELECT
                        a.SessionId,
                        ROW_NUMBER() OVER
                        (
                            ORDER BY a.SessionId, a.Position, b.Position, c.Position, d.Position, e.Position
                        ) AS ComboId,
                        a.RankValue AS R1, b.RankValue AS R2, c.RankValue AS R3,
                        d.RankValue AS R4, e.RankValue AS R5,
                        a.SuitValue AS S1, b.SuitValue AS S2, c.SuitValue AS S3,
                        d.SuitValue AS S4, e.SuitValue AS S5
                    INTO #Five
                    FROM #Seven AS a
                    INNER JOIN #Seven AS b ON b.SessionId = a.SessionId AND b.Position > a.Position
                    INNER JOIN #Seven AS c ON c.SessionId = a.SessionId AND c.Position > b.Position
                    INNER JOIN #Seven AS d ON d.SessionId = a.SessionId AND d.Position > c.Position
                    INNER JOIN #Seven AS e ON e.SessionId = a.SessionId AND e.Position > d.Position;

                    SELECT
                        f.SessionId,
                        f.ComboId,
                        COUNT(DISTINCT r.RankValue) AS DistinctRanks,
                        MIN(r.RankValue) AS MinimumRank,
                        MAX(r.RankValue) AS MaximumRank,
                        SUM(DISTINCT r.RankValue) AS RankSum,
                        CASE WHEN f.S1 = f.S2 AND f.S1 = f.S3 AND f.S1 = f.S4 AND f.S1 = f.S5
                             THEN 1 ELSE 0 END AS IsFlush
                    INTO #ComboStats
                    FROM #Five AS f
                    CROSS APPLY (VALUES (f.R1),(f.R2),(f.R3),(f.R4),(f.R5)) AS r(RankValue)
                    GROUP BY f.SessionId, f.ComboId, f.S1, f.S2, f.S3, f.S4, f.S5;

                    ;WITH Counts AS
                    (
                        SELECT f.SessionId, f.ComboId, r.RankValue, COUNT(*) AS RankCount
                        FROM #Five AS f
                        CROSS APPLY (VALUES (f.R1),(f.R2),(f.R3),(f.R4),(f.R5)) AS r(RankValue)
                        GROUP BY f.SessionId, f.ComboId, r.RankValue
                    )
                    SELECT
                        SessionId,
                        ComboId,
                        RankValue,
                        RankCount,
                        ROW_NUMBER() OVER
                        (
                            PARTITION BY SessionId, ComboId
                            ORDER BY RankCount DESC, RankValue DESC
                        ) AS GroupOrder,
                        ROW_NUMBER() OVER
                        (
                            PARTITION BY SessionId, ComboId
                            ORDER BY RankValue DESC
                        ) AS RankOrder
                    INTO #RankGroups
                    FROM Counts;

                    ;WITH Classified AS
                    (
                        SELECT
                            s.SessionId,
                            s.ComboId,
                            CASE
                                WHEN s.IsFlush = 1
                                 AND (s.DistinctRanks = 5 AND s.MaximumRank - s.MinimumRank = 4
                                      OR s.DistinctRanks = 5 AND s.MinimumRank = 2
                                         AND s.MaximumRank = 14 AND s.RankSum = 28)
                                    THEN 8
                                WHEN MAX(r.RankCount) = 4 THEN 7
                                WHEN MAX(r.RankCount) = 3 AND SUM(CASE WHEN r.RankCount = 2 THEN 1 ELSE 0 END) = 1 THEN 6
                                WHEN s.IsFlush = 1 THEN 5
                                WHEN s.DistinctRanks = 5 AND (s.MaximumRank - s.MinimumRank = 4
                                      OR s.MinimumRank = 2 AND s.MaximumRank = 14 AND s.RankSum = 28)
                                    THEN 4
                                WHEN MAX(r.RankCount) = 3 THEN 3
                                WHEN SUM(CASE WHEN r.RankCount = 2 THEN 1 ELSE 0 END) = 2 THEN 2
                                WHEN MAX(r.RankCount) = 2 THEN 1
                                ELSE 0
                            END AS Category,
                            CASE WHEN s.DistinctRanks = 5 AND s.MinimumRank = 2
                                      AND s.MaximumRank = 14 AND s.RankSum = 28
                                 THEN 5 ELSE s.MaximumRank END AS StraightHigh,
                            MAX(CASE WHEN r.GroupOrder = 1 THEN r.RankValue ELSE 0 END) AS G1,
                            MAX(CASE WHEN r.GroupOrder = 2 THEN r.RankValue ELSE 0 END) AS G2,
                            MAX(CASE WHEN r.GroupOrder = 3 THEN r.RankValue ELSE 0 END) AS G3,
                            MAX(CASE WHEN r.GroupOrder = 4 THEN r.RankValue ELSE 0 END) AS G4,
                            MAX(CASE WHEN r.GroupOrder = 5 THEN r.RankValue ELSE 0 END) AS G5,
                            MAX(CASE WHEN r.RankOrder = 1 THEN r.RankValue ELSE 0 END) AS H1,
                            MAX(CASE WHEN r.RankOrder = 2 THEN r.RankValue ELSE 0 END) AS H2,
                            MAX(CASE WHEN r.RankOrder = 3 THEN r.RankValue ELSE 0 END) AS H3,
                            MAX(CASE WHEN r.RankOrder = 4 THEN r.RankValue ELSE 0 END) AS H4,
                            MAX(CASE WHEN r.RankOrder = 5 THEN r.RankValue ELSE 0 END) AS H5
                        FROM #ComboStats AS s
                        INNER JOIN #RankGroups AS r
                            ON r.SessionId = s.SessionId AND r.ComboId = s.ComboId
                        GROUP BY s.SessionId, s.ComboId, s.IsFlush, s.DistinctRanks,
                                 s.MinimumRank, s.MaximumRank, s.RankSum
                    )
                    SELECT
                        SessionId,
                        ComboId,
                        Category,
                        CONVERT(bigint, Category) * 1000000
                        + CASE Category
                            WHEN 8 THEN StraightHigh * 50625
                            WHEN 7 THEN G1 * 50625 + G2 * 3375
                            WHEN 6 THEN G1 * 50625 + G2 * 3375
                            WHEN 5 THEN H1 * 50625 + H2 * 3375 + H3 * 225 + H4 * 15 + H5
                            WHEN 4 THEN StraightHigh * 50625
                            WHEN 3 THEN G1 * 50625 + G2 * 3375 + G3 * 225
                            WHEN 2 THEN G1 * 50625 + G2 * 3375 + G3 * 225
                            WHEN 1 THEN G1 * 50625 + G2 * 3375 + G3 * 225 + G4 * 15
                            ELSE H1 * 50625 + H2 * 3375 + H3 * 225 + H4 * 15 + H5
                          END AS Score
                    INTO #ComboScores
                    FROM Classified;

                    ;WITH Best AS
                    (
                        SELECT SessionId, MAX(Score) AS Score
                        FROM #ComboScores
                        GROUP BY SessionId
                    )
                    SELECT b.SessionId, b.Score, MAX(c.Category) AS Category
                    INTO #PlayerScores
                    FROM Best AS b
                    INNER JOIN #ComboScores AS c
                        ON c.SessionId = b.SessionId AND c.Score = b.Score
                    GROUP BY b.SessionId, b.Score;

                    UPDATE p
                    SET ShowCards = 1,
                        HandScore = s.Score,
                        HandDescription = CASE s.Category
                            WHEN 8 THEN 'Straight flush'
                            WHEN 7 THEN 'Four of a kind'
                            WHEN 6 THEN 'Full house'
                            WHEN 5 THEN 'Flush'
                            WHEN 4 THEN 'Straight'
                            WHEN 3 THEN 'Three of a kind'
                            WHEN 2 THEN 'Two pair'
                            WHEN 1 THEN 'One pair'
                            ELSE 'High card'
                        END
                    FROM ##TexasHoldEm_Players_Codex_v1 AS p
                    INNER JOIN #PlayerScores AS s ON s.SessionId = p.SessionId
                    WHERE p.DatabaseId = @DatabaseId;

                    DECLARE
                        @WinningScore bigint,
                        @ShowdownPot int,
                        @WinnerCount int,
                        @Share int,
                        @Remainder int,
                        @RemainderWinner int,
                        @WinnerNames nvarchar(1000) = N'';

                    SELECT @WinningScore = MAX(Score) FROM #PlayerScores;
                    SELECT @WinnerCount = COUNT(*) FROM #PlayerScores WHERE Score = @WinningScore;
                    SELECT @ShowdownPot = Pot FROM ##TexasHoldEm_Game_Codex_v1 WHERE DatabaseId = @DatabaseId;

                    SET @Share = @ShowdownPot / @WinnerCount;
                    SET @Remainder = @ShowdownPot % @WinnerCount;

                    SELECT TOP (1) @RemainderWinner = p.SessionId
                    FROM ##TexasHoldEm_Players_Codex_v1 AS p
                    INNER JOIN #PlayerScores AS s ON s.SessionId = p.SessionId
                    WHERE p.DatabaseId = @DatabaseId
                      AND s.Score = @WinningScore
                    ORDER BY p.Seat;

                    UPDATE p
                    SET QueryBucks = QueryBucks + @Share
                        + CASE WHEN p.SessionId = @RemainderWinner THEN @Remainder ELSE 0 END
                    FROM ##TexasHoldEm_Players_Codex_v1 AS p
                    INNER JOIN #PlayerScores AS s ON s.SessionId = p.SessionId
                    WHERE p.DatabaseId = @DatabaseId
                      AND s.Score = @WinningScore;

                    SELECT @WinnerNames = STUFF
                    (
                        (
                            SELECT N', ' + p.PlayerName
                            FROM ##TexasHoldEm_Players_Codex_v1 AS p
                            INNER JOIN #PlayerScores AS s ON s.SessionId = p.SessionId
                            WHERE p.DatabaseId = @DatabaseId
                              AND s.Score = @WinningScore
                            ORDER BY p.Seat
                            FOR XML PATH(''), TYPE
                        ).value('.', 'nvarchar(1000)'),
                        1, 2, N''
                    );

                    UPDATE ##TexasHoldEm_Game_Codex_v1
                    SET Phase = 'BETWEEN',
                        ActionSeat = NULL,
                        ActionDeadline = NULL,
                        LobbyClosesAt = DATEADD(second, 60, @Now),
                        CurrentBet = 0,
                        Pot = 0,
                        BoardCardsVisible = 5,
                        LastChangedAt = @Now
                    WHERE DatabaseId = @DatabaseId;

                    INSERT ##TexasHoldEm_Log_Codex_v1 (DatabaseId, HandNumber, LoggedAt, Message)
                    SELECT @DatabaseId, HandNumber, @Now,
                        @WinnerNames + CASE WHEN @WinnerCount = 1 THEN N' won ' ELSE N' split ' END
                        + N'the ' + CONVERT(nvarchar(12), @ShowdownPot) + N'-QueryBuck pot.'
                    FROM ##TexasHoldEm_Game_Codex_v1
                    WHERE DatabaseId = @DatabaseId;

                    SET @Phase = 'BETWEEN';
                    SET @HandJustEnded = 1;
                    BREAK;
                END
                ELSE
                BEGIN
                    DECLARE @NextPhase varchar(12), @Visible tinyint, @FirstPostFlop tinyint;

                    SET @NextPhase = CASE @Phase
                        WHEN 'PREFLOP' THEN 'FLOP'
                        WHEN 'FLOP' THEN 'TURN'
                        WHEN 'TURN' THEN 'RIVER'
                    END;
                    SET @Visible = CASE @NextPhase WHEN 'FLOP' THEN 3 WHEN 'TURN' THEN 4 ELSE 5 END;

                    UPDATE ##TexasHoldEm_Players_Codex_v1
                    SET StreetBet = 0,
                        ActedThisStreet = 0
                    WHERE DatabaseId = @DatabaseId
                      AND InHand = 1
                      AND Folded = 0;

                    SELECT TOP (1) @FirstPostFlop = p.Seat
                    FROM ##TexasHoldEm_Players_Codex_v1 AS p
                    INNER JOIN ##TexasHoldEm_Game_Codex_v1 AS g ON g.DatabaseId = p.DatabaseId
                    WHERE p.DatabaseId = @DatabaseId
                      AND p.InHand = 1
                      AND p.Folded = 0
                    ORDER BY CASE WHEN p.Seat > g.DealerSeat THEN 0 ELSE 1 END, p.Seat;

                    UPDATE ##TexasHoldEm_Game_Codex_v1
                    SET Phase = @NextPhase,
                        ActionSeat = @FirstPostFlop,
                        ActionDeadline = DATEADD(second, 60, @Now),
                        CurrentBet = 0,
                        BoardCardsVisible = @Visible,
                        LastChangedAt = @Now
                    WHERE DatabaseId = @DatabaseId;

                    INSERT ##TexasHoldEm_Log_Codex_v1 (DatabaseId, HandNumber, LoggedAt, Message)
                    SELECT @DatabaseId, HandNumber, @Now,
                        CASE @NextPhase
                            WHEN 'FLOP' THEN N'The flop was dealt.'
                            WHEN 'TURN' THEN N'The turn was dealt.'
                            ELSE N'The river was dealt.'
                        END
                    FROM ##TexasHoldEm_Game_Codex_v1
                    WHERE DatabaseId = @DatabaseId;

                    SET @Phase = @NextPhase;
                    CONTINUE;
                END;
            END;

            /* Move clockwise to the next player who owes action. */
            DECLARE @NextActionSeat tinyint;

            SELECT TOP (1) @NextActionSeat = Seat
            FROM ##TexasHoldEm_Players_Codex_v1
            WHERE DatabaseId = @DatabaseId
              AND InHand = 1
              AND Folded = 0
              AND (ActedThisStreet = 0 OR StreetBet < @CurrentBet)
            ORDER BY CASE WHEN Seat > @ActionSeat THEN 0 ELSE 1 END, Seat;

            UPDATE ##TexasHoldEm_Game_Codex_v1
            SET ActionSeat = @NextActionSeat,
                ActionDeadline = DATEADD(second, 60, @Now),
                LastChangedAt = @Now
            WHERE DatabaseId = @DatabaseId;
        END;

        IF @InputAction IN ('CHECK', 'CALL', 'BET', 'RAISE', 'FOLD', 'ALLIN')
           AND @ActionConsumed = 0
        BEGIN
            SET @Notice = COALESCE(@Notice + N' ', N'')
                + N'No betting action was pending; ' + @InputAction + N' was ignored.';
            SET @ActionConsumed = 1;
        END;

        COMMIT TRANSACTION;

        IF @KeepWaiting = 1
           AND @InputAction IS NULL
           AND @OriginalAction NOT IN ('STATUS', 'REFRESH', 'WATCH')
        BEGIN
            WAITFOR DELAY '00:00:01';
            CONTINUE;
        END;

        BREAK;
    END;

    /* Build the viewer-specific prompt after state changes are committed. */
    DECLARE
        @ViewerRole varchar(12),
        @ViewerSeat tinyint,
        @ViewerBucks int,
        @ViewerWantsSeat bit,
        @GamePhase varchar(12),
        @GameHand int,
        @GamePot int,
        @GameBet int,
        @GameMinimumRaise int,
        @GameActionSeat tinyint,
        @GameDeadline datetime2(0),
        @GameLobbyEnd datetime2(0),
        @BoardVisible tinyint,
        @Board1 tinyint, @Board2 tinyint, @Board3 tinyint, @Board4 tinyint, @Board5 tinyint,
        @Prompt nvarchar(1000),
        @LegalActions nvarchar(500),
        @Example nvarchar(1000),
        @ViewerStreetBet int,
        @ViewerStack int,
        @ViewerToCall int,
        @OutputMaximum int,
        @DisplayedMinimumRaiseTo int,
        @SecondsRemaining int;

    SELECT
        @ViewerRole = PlayerRole,
        @ViewerSeat = Seat,
        @ViewerBucks = QueryBucks,
        @ViewerWantsSeat = WantsSeat,
        @ViewerStreetBet = StreetBet,
        @ViewerStack = QueryBucks
    FROM ##TexasHoldEm_Players_Codex_v1
    WHERE DatabaseId = @DatabaseId
      AND SessionId = @SessionId;

    IF @ViewerRole IS NULL AND @ReadOnlySnapshot = 1
        SET @ViewerRole = 'SPECTATOR';

    SELECT
        @GamePhase = Phase,
        @GameHand = HandNumber,
        @GamePot = Pot,
        @GameBet = CurrentBet,
        @GameMinimumRaise = MinimumRaise,
        @GameActionSeat = ActionSeat,
        @GameDeadline = ActionDeadline,
        @GameLobbyEnd = LobbyClosesAt,
        @BoardVisible = BoardCardsVisible,
        @Board1 = Board1, @Board2 = Board2, @Board3 = Board3, @Board4 = Board4, @Board5 = Board5
    FROM ##TexasHoldEm_Game_Codex_v1
    WHERE DatabaseId = @DatabaseId;

    SET @ViewerToCall = CASE WHEN @GameBet > COALESCE(@ViewerStreetBet, 0)
                             THEN @GameBet - COALESCE(@ViewerStreetBet, 0) ELSE 0 END;

    SELECT @OutputMaximum = MIN(StreetBet + QueryBucks)
    FROM ##TexasHoldEm_Players_Codex_v1
    WHERE DatabaseId = @DatabaseId
      AND InHand = 1
      AND Folded = 0;

    SET @DisplayedMinimumRaiseTo = CASE
        WHEN @OutputMaximum <= @GameBet THEN NULL
        WHEN @GameBet + @GameMinimumRaise > @OutputMaximum THEN @OutputMaximum
        ELSE @GameBet + @GameMinimumRaise
    END;

    SET @SecondsRemaining = CASE
        WHEN @GamePhase = 'LOBBY' THEN DATEDIFF(second, SYSUTCDATETIME(), @GameLobbyEnd)
        WHEN @GamePhase = 'BETWEEN' THEN DATEDIFF(second, SYSUTCDATETIME(), @GameLobbyEnd)
        WHEN @GameDeadline IS NOT NULL THEN DATEDIFF(second, SYSUTCDATETIME(), @GameDeadline)
        ELSE NULL
    END;
    IF @SecondsRemaining < 0 SET @SecondsRemaining = 0;

    IF @GamePhase = 'LOBBY'
    BEGIN
        SET @Prompt = N'Waiting for up to four human players. Robots fill open seats when the lobby expires.';
        SET @LegalActions = N'Run the procedure from another session to join.';
        SET @Example = N'EXEC dbo.sp_TexasHoldEm @PlayerName = N''Ada'';';
    END
    ELSE IF @GamePhase = 'BETWEEN'
    BEGIN
        SET @Prompt = N'The hand is over. Waiting players may take open seats before the next hand.';
        SET @LegalActions = CASE WHEN @ViewerRole = 'SPECTATOR' AND @ViewerWantsSeat = 1
                                 THEN N'You have requested the next available seat.'
                                 ELSE N'Run the procedure again to continue.' END;
        SET @Example = N'EXEC dbo.sp_TexasHoldEm;';
    END
    ELSE IF @GamePhase = 'GAMEOVER'
    BEGIN
        SET @Prompt = N'GAME OVER.';
        SET @LegalActions = N'Start a fresh 1,000-QueryBuck game with NEWGAME.';
        SET @Example = N'EXEC dbo.sp_TexasHoldEm @Action = ''NEWGAME'', @PlayerName = N''Ada'';';
    END
    ELSE IF @ViewerRole = 'PLAYER' AND @ViewerSeat = @GameActionSeat
    BEGIN
        SET @Prompt = N'It is your turn.';
        SET @LegalActions = CASE WHEN @ViewerToCall = 0
            THEN N'CHECK'
                 + CASE WHEN @DisplayedMinimumRaiseTo IS NULL THEN N''
                        WHEN @GameBet = 0 THEN N'; BET to at least '
                            + CONVERT(nvarchar(12), @DisplayedMinimumRaiseTo)
                            + N' (maximum ' + CONVERT(nvarchar(12), @OutputMaximum) + N'); ALLIN'
                        ELSE N'; RAISE to at least '
                            + CONVERT(nvarchar(12), @DisplayedMinimumRaiseTo)
                            + N' (maximum ' + CONVERT(nvarchar(12), @OutputMaximum) + N'); ALLIN'
                   END
                 + N'; FOLD.'
            ELSE N'CALL ' + CONVERT(nvarchar(12), @ViewerToCall)
                 + CASE WHEN @DisplayedMinimumRaiseTo IS NULL THEN N''
                        ELSE N'; RAISE to at least '
                            + CONVERT(nvarchar(12), @DisplayedMinimumRaiseTo)
                            + N' (maximum ' + CONVERT(nvarchar(12), @OutputMaximum) + N'); ALLIN'
                   END
                 + N'; FOLD.'
        END;
        SET @Example = CASE WHEN @ViewerToCall = 0
            THEN N'EXEC dbo.sp_TexasHoldEm @Action = ''CHECK'';'
            ELSE N'EXEC dbo.sp_TexasHoldEm @Action = ''CALL'';'
        END;
    END
    ELSE
    BEGIN
        SET @Prompt = CASE WHEN @ViewerRole = 'SPECTATOR'
            THEN N'You are watching. Private cards remain hidden until a called showdown.'
            ELSE N'Waiting for seat ' + CONVERT(nvarchar(3), @GameActionSeat) + N' to act.' END;
        SET @LegalActions = N'Refresh the public table state.';
        SET @Example = N'EXEC dbo.sp_TexasHoldEm @Action = ''STATUS'';';
    END;

    /* Result set 1: status and prompt. */
    SELECT
        DB_NAME() AS [Database],
        @SessionId AS YourSessionId,
        @ViewerRole AS YourRole,
        @ViewerSeat AS YourSeat,
        @ViewerBucks AS YourQueryBucks,
        @GamePhase AS GameStatus,
        @GameHand AS HandNumber,
        @GamePot AS PotQueryBucks,
        @GameBet AS CurrentStreetBet,
        @GameActionSeat AS ActionSeat,
        @SecondsRemaining AS SecondsRemaining,
        @Notice AS Notice,
        @Prompt AS Prompt,
        @LegalActions AS LegalActions,
        @Example AS ExampleCommand;

    /* Result set 2: table, public board, and only cards this viewer may see. */
    SELECT
        p.Seat,
        p.PlayerName,
        CASE WHEN p.IsRobot = 1 THEN 'Robot' ELSE 'Human' END AS PlayerType,
        p.QueryBucks,
        CASE
            WHEN p.PlayerRole <> 'PLAYER' THEN p.PlayerRole
            WHEN p.InHand = 0 THEN 'Waiting'
            WHEN p.Folded = 1 THEN 'Folded'
            WHEN p.Seat = @GameActionSeat THEN 'Thinking'
            ELSE 'In hand'
        END AS PlayerStatus,
        p.StreetBet AS BetThisStreet,
        p.HandBet AS InThePot,
        CASE WHEN p.HoleCardsEncrypted IS NULL THEN N'(none)'
            WHEN p.SessionId = @SessionId OR p.ShowCards = 1
            THEN
                CASE ((CONVERT(int, SUBSTRING(h.HoleCards, 1, 1)) - 1) % 13) + 2
                    WHEN 14 THEN 'A' WHEN 13 THEN 'K' WHEN 12 THEN 'Q' WHEN 11 THEN 'J' WHEN 10 THEN 'T'
                    ELSE CONVERT(varchar(2), ((CONVERT(int, SUBSTRING(h.HoleCards, 1, 1)) - 1) % 13) + 2) END
                + CASE (CONVERT(int, SUBSTRING(h.HoleCards, 1, 1)) - 1) / 13
                    WHEN 0 THEN N'♣' WHEN 1 THEN N'♦' WHEN 2 THEN N'♥' ELSE N'♠' END
                + N' '
                + CASE ((CONVERT(int, SUBSTRING(h.HoleCards, 2, 1)) - 1) % 13) + 2
                    WHEN 14 THEN 'A' WHEN 13 THEN 'K' WHEN 12 THEN 'Q' WHEN 11 THEN 'J' WHEN 10 THEN 'T'
                    ELSE CONVERT(varchar(2), ((CONVERT(int, SUBSTRING(h.HoleCards, 2, 1)) - 1) % 13) + 2) END
                + CASE (CONVERT(int, SUBSTRING(h.HoleCards, 2, 1)) - 1) / 13
                    WHEN 0 THEN N'♣' WHEN 1 THEN N'♦' WHEN 2 THEN N'♥' ELSE N'♠' END
            ELSE N'Hidden'
        END AS HoleCards,
        CASE WHEN p.ShowCards = 1 THEN p.HandDescription ELSE NULL END AS ShowdownHand,
        CASE WHEN @BoardVisible = 0 THEN N'(none)'
             ELSE
                CASE ((@Board1 - 1) % 13) + 2
                    WHEN 14 THEN 'A' WHEN 13 THEN 'K' WHEN 12 THEN 'Q' WHEN 11 THEN 'J' WHEN 10 THEN 'T'
                    ELSE CONVERT(varchar(2), ((@Board1 - 1) % 13) + 2) END
                + CASE (@Board1 - 1) / 13 WHEN 0 THEN N'♣' WHEN 1 THEN N'♦' WHEN 2 THEN N'♥' ELSE N'♠' END
                + CASE WHEN @BoardVisible >= 2 THEN N' ' +
                    CASE ((@Board2 - 1) % 13) + 2 WHEN 14 THEN 'A' WHEN 13 THEN 'K' WHEN 12 THEN 'Q' WHEN 11 THEN 'J' WHEN 10 THEN 'T'
                        ELSE CONVERT(varchar(2), ((@Board2 - 1) % 13) + 2) END
                    + CASE (@Board2 - 1) / 13 WHEN 0 THEN N'♣' WHEN 1 THEN N'♦' WHEN 2 THEN N'♥' ELSE N'♠' END ELSE N'' END
                + CASE WHEN @BoardVisible >= 3 THEN N' ' +
                    CASE ((@Board3 - 1) % 13) + 2 WHEN 14 THEN 'A' WHEN 13 THEN 'K' WHEN 12 THEN 'Q' WHEN 11 THEN 'J' WHEN 10 THEN 'T'
                        ELSE CONVERT(varchar(2), ((@Board3 - 1) % 13) + 2) END
                    + CASE (@Board3 - 1) / 13 WHEN 0 THEN N'♣' WHEN 1 THEN N'♦' WHEN 2 THEN N'♥' ELSE N'♠' END ELSE N'' END
                + CASE WHEN @BoardVisible >= 4 THEN N' ' +
                    CASE ((@Board4 - 1) % 13) + 2 WHEN 14 THEN 'A' WHEN 13 THEN 'K' WHEN 12 THEN 'Q' WHEN 11 THEN 'J' WHEN 10 THEN 'T'
                        ELSE CONVERT(varchar(2), ((@Board4 - 1) % 13) + 2) END
                    + CASE (@Board4 - 1) / 13 WHEN 0 THEN N'♣' WHEN 1 THEN N'♦' WHEN 2 THEN N'♥' ELSE N'♠' END ELSE N'' END
                + CASE WHEN @BoardVisible >= 5 THEN N' ' +
                    CASE ((@Board5 - 1) % 13) + 2 WHEN 14 THEN 'A' WHEN 13 THEN 'K' WHEN 12 THEN 'Q' WHEN 11 THEN 'J' WHEN 10 THEN 'T'
                        ELSE CONVERT(varchar(2), ((@Board5 - 1) % 13) + 2) END
                    + CASE (@Board5 - 1) / 13 WHEN 0 THEN N'♣' WHEN 1 THEN N'♦' WHEN 2 THEN N'♥' ELSE N'♠' END ELSE N'' END
        END AS CommunityCards
    FROM ##TexasHoldEm_Players_Codex_v1 AS p
    CROSS APPLY
    (
        VALUES
        (
            CONVERT(varbinary(2), DecryptByCert
            (
                CERT_ID(N'sp_TexasHoldEm_CardProtection_Codex'),
                p.HoleCardsEncrypted,
                N'QueryBucks-Codex-demo-certificate-2026!'
            ))
        )
    ) AS h(HoleCards)
    WHERE p.DatabaseId = @DatabaseId
      AND p.PlayerRole IN ('PLAYER', 'OUT')
    ORDER BY CASE WHEN p.Seat IS NULL THEN 1 ELSE 0 END, p.Seat, p.JoinedAt;

    /* Result set 3: public action transcript for this hand. */
    SELECT LoggedAt, Message
    FROM ##TexasHoldEm_Log_Codex_v1
    WHERE DatabaseId = @DatabaseId
      AND HandNumber = @GameHand
    ORDER BY LogId;
END;
GO

/*
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
