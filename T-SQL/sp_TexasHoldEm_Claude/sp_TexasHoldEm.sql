/* sp_TexasHoldEm - multiplayer Texas Hold 'Em, played entirely in SSMS.

How to play:

  1. Create this proc in any user database. Everyone connects to that SAME
     database (required - the game state lives in global temp tables, and on
     Azure SQL DB those are scoped per-database anyway).

  2. In one query window:   EXEC sp_TexasHoldEm @PlayerName = 'Brent';
     That starts a game and waits up to 60 seconds for others to join.
     (@PlayerName is optional - you'll get a name like "Player 57" - but a
     name lets you reconnect from a new session and reclaim your seat.)

  3. In other windows/sessions:   EXEC sp_TexasHoldEm @PlayerName = 'Erika';
     Up to 4 seats. If nobody else joins within 60 seconds, you play against
     three robots: Clippy, HAL, and Bender. If the table's full, you watch
     from the rail as an observer and see what the public sees.

  4. Your query "runs" while you wait - that's the design. Watch the Messages
     tab: the action streams in live. The query finishes when YOU need to do
     something, and the results tell you exactly what to run, like:
        EXEC sp_TexasHoldEm @Action = 'Call',  @PlayerName = 'Brent';
        EXEC sp_TexasHoldEm @Action = 'Raise', @PlayerName = 'Brent';
        EXEC sp_TexasHoldEm @Action = 'Fold',  @PlayerName = 'Brent';
     After a hand ends, run EXEC sp_TexasHoldEm again to keep playing.

Actions: Join (default), Check, Call, Bet, Raise, Fold, Leave, Watch,
         Status (instant snapshot, never blocks), Help.

House rules:
  - Fixed-limit Hold 'Em: blinds 10/20, bets 20 pre-flop & flop, 40 on the
    turn & river, max one bet + three raises per round. Everybody starts
    with 1,000 chips; you're out when you're broke (but you can buy back in
    if a seat is open - the log will shame you appropriately).
  - 60-second shot clock per decision. Take too long and you auto-check or
    auto-fold; three strikes and your seat goes to the next player.
  - No side pots: you can call all-in for less, and if you win you take the
    whole pot. Vegas would not approve. Vegas also isn't a stored procedure.

Requirements & caveats:
  - SQL Server 2017+ or Azure SQL DB (uses STRING_AGG and global ## tables).
  - All players must be in the same database on the same server. On boxed
    SQL Server there's one game per instance: the ## tables are instance-
    global but applocks are database-scoped, so the game claims a home
    database and politely refuses sessions connected anywhere else.
  - The game state lives in global temp tables (##TexasHoldEm_*), created by
    whoever runs the proc first. If THAT session disconnects, SQL Server
    drops the tables and the casino burns down mid-hand. Everyone else gets
    a polite message. This is a demo, not a career.
  - The whole game serializes on sp_getapplock, so a hung session can't
    corrupt the table state - it just gets folded by the shot clock.

License and info: see the bottom of this file.
*/
SET ANSI_NULLS ON;
GO
SET QUOTED_IDENTIFIER ON;
GO
CREATE OR ALTER PROCEDURE dbo.sp_TexasHoldEm
    @Action nvarchar(20) = NULL,
    @PlayerName nvarchar(30) = NULL
AS
BEGIN
SET NOCOUNT ON;

/* House rules - tweak to taste: */
DECLARE @SmallBlind int = 10,
        @BigBlind int = 20,
        @SmallBet int = 20,          /* bet size pre-flop and on the flop */
        @BigBet int = 40,            /* bet size on the turn and river */
        @MaxRaises int = 4,          /* one bet + three raises per round */
        @StartingChips int = 1000,
        @MaxSeats int = 4,
        @JoinWindowSeconds int = 60,
        @TurnSeconds int = 60,       /* the shot clock */
        @MaxTimeoutStrikes int = 3,
        @BetweenHandsSeconds int = 10,
        @MaxWaitMinutes int = 60;    /* give up blocking after this long */

DECLARE @rc int,
        @OwnerDb nvarchar(128),
        @Msg nvarchar(2047),
        @Notice nvarchar(500),
        @MySeat tinyint,
        @MyInHand bit,
        @IsObserver bit = 0,
        @ReturnNow bit = 0,
        @FirstPass bit = 1,
        @ToldWaiting bit = 0,
        @LeftTable bit = 0,
        @SeatStolen bit = 0,
        @GaveUp bit = 0,
        @GameGone bit = 0,
        @TargetHand int = 0,
        @WaitStart datetime2 = SYSDATETIME(),
        @LastLogId int = 0,
        @CardsShownForHand int = -1,
        /* game snapshot */
        @GState varchar(20), @GHand int, @Dealer tinyint, @SBSeat tinyint, @BBSeat tinyint,
        @Round tinyint, @BoardShown tinyint, @ShowdownShown bit, @Pot int, @PotDisp int,
        @BetToCall int, @RaiseCount int, @TurnSeat tinyint, @TurnStartedAt datetime2,
        @JoinEnds datetime2, @NextHandAt datetime2,
        @B1 tinyint, @B2 tinyint, @B3 tinyint, @B4 tinyint, @B5 tinyint,
        @BoardDisp nvarchar(30),
        /* my seat snapshot */
        @SeatExists bit, @CurOwner int, @MyNeedsToAct bit, @MyFolded bit,
        @MyChips int, @MyBet int, @MyC1 tinyint, @MyC2 tinyint, @MyCards nvarchar(12),
        /* engine workspace */
        @Spins int, @StartHandNow bit, @HandDone bit,
        @NumPlayers int, @HumansLeft int, @NumInHand int, @Unfolded int, @ActiveBettors int,
        @PrevDealer tinyint, @ActorSeat tinyint, @ActorBot bit, @ActorName nvarchar(30),
        @ActorChips int, @ActorBet int, @ActorStrikes tinyint,
        @Owed int, @Unit int, @NewBet int, @Pay int, @NextSeat tinyint, @r int,
        @BotMove varchar(10), @RoundBets int, @WinSeat tinyint, @WinName nvarchar(30),
        /* showdown & hand evaluation */
        @cSeat tinyint, @cName nvarchar(30), @cC1 tinyint, @cC2 tinyint,
        @FlushSuit tinyint, @StraightHigh int, @SFHigh int,
        @Quad int, @Trip int, @Pair1 int, @Pair2 int, @FHPair int,
        @Cat bigint, @T1 int, @T2 int, @T3 int, @T4 int, @T5 int,
        @Score bigint, @HandName nvarchar(60),
        @BestScore bigint, @NumWinners int, @Share int, @Rem int,
        @NameArg nvarchar(80), @SecondsLeft int;

DECLARE @NewLog TABLE (LogId int, Message nvarchar(500));
DECLARE @Shuffled TABLE (Pos int, CardId tinyint);
DECLARE @Seven TABLE (CardRank int, CardSuit tinyint);
DECLARE @RanksT TABLE (CardRank int);
DECLARE @FRanks TABLE (CardRank int);
DECLARE @ShowResults TABLE (SeatNum tinyint, PlayerName nvarchar(30), Score bigint, HandName nvarchar(60));
DECLARE @Prompt TABLE (LineId int IDENTITY(1,1), Line nvarchar(300));

/* A deck of cards. CardId 0-51: rank = CardId / 4 + 2 (2..14), suit = CardId % 4. */
CREATE TABLE #Cards (CardId tinyint PRIMARY KEY, CardRank int, CardSuit tinyint, Display nvarchar(3));
;WITH n AS (SELECT TOP (52) ROW_NUMBER() OVER (ORDER BY (SELECT NULL)) - 1 AS CardId FROM sys.all_objects)
INSERT #Cards (CardId, CardRank, CardSuit, Display)
SELECT CardId, CardId / 4 + 2, CardId % 4,
       CASE CardId / 4 + 2 WHEN 14 THEN N'A' WHEN 13 THEN N'K' WHEN 12 THEN N'Q' WHEN 11 THEN N'J'
            ELSE CAST(CardId / 4 + 2 AS nvarchar(2)) END
       + SUBSTRING(N'♠♥♦♣', CardId % 4 + 1, 1)
FROM n;

CREATE TABLE #RankNames (RankValue int PRIMARY KEY, RankName nvarchar(6), RankPlural nvarchar(7));
INSERT #RankNames (RankValue, RankName, RankPlural) VALUES
 (2,N'Two',N'Twos'),(3,N'Three',N'Threes'),(4,N'Four',N'Fours'),(5,N'Five',N'Fives'),
 (6,N'Six',N'Sixes'),(7,N'Seven',N'Sevens'),(8,N'Eight',N'Eights'),(9,N'Nine',N'Nines'),
 (10,N'Ten',N'Tens'),(11,N'Jack',N'Jacks'),(12,N'Queen',N'Queens'),(13,N'King',N'Kings'),(14,N'Ace',N'Aces');

SET @Action = NULLIF(LTRIM(RTRIM(@Action)), N'');
SET @PlayerName = NULLIF(LTRIM(RTRIM(@PlayerName)), N'');
IF @Action = N'Join' SET @Action = NULL;

IF @Action IS NOT NULL
   AND @Action NOT IN (N'Check', N'Call', N'Bet', N'Raise', N'Fold', N'Leave', N'Watch', N'Status', N'Help')
BEGIN
    SELECT [Say What?] = CONCAT(N'I don''t know the action ''', @Action,
        N'''. Try: Join, Check, Call, Bet, Raise, Fold, Leave, Watch, Status, or Help.');
    RETURN;
END

IF @Action = N'Help'
BEGIN
    SELECT [sp_TexasHoldEm Help] = v.Line
    FROM (VALUES
        (1, N'EXEC sp_TexasHoldEm @PlayerName = ''YourName'';        -- join (or start) a game'),
        (2, N'EXEC sp_TexasHoldEm @Action = ''Check'',  @PlayerName = ''YourName'';'),
        (3, N'EXEC sp_TexasHoldEm @Action = ''Call'',   @PlayerName = ''YourName'';'),
        (4, N'EXEC sp_TexasHoldEm @Action = ''Raise'',  @PlayerName = ''YourName'';  -- ''Bet'' works too'),
        (5, N'EXEC sp_TexasHoldEm @Action = ''Fold'',   @PlayerName = ''YourName'';'),
        (6, N'EXEC sp_TexasHoldEm @Action = ''Leave'',  @PlayerName = ''YourName'';  -- cash out'),
        (7, N'EXEC sp_TexasHoldEm @Action = ''Watch'';                              -- spectate, never sits you down'),
        (8, N'EXEC sp_TexasHoldEm @Action = ''Status'';                             -- instant snapshot, never blocks'),
        (9, N'While your query runs, watch the Messages tab - the action streams in live.'),
        (10,N'The query finishes when it''s your turn, and tells you exactly what to run next.')
        ) v(LineId, Line)
    ORDER BY v.LineId;
    RETURN;
END

IF @PlayerName IN (N'Clippy', N'HAL', N'Bender')
BEGIN
    SELECT [Nice Try] = CONCAT(@PlayerName, N' is one of the house robots. Pick a different name.');
    RETURN;
END

BEGIN TRY

WHILE 1 = 1
BEGIN
    /* The game evaporates if the creating session disconnects - global temp
       tables get dropped. Detect that and bow out gracefully. */
    IF @FirstPass = 0 AND OBJECT_ID('tempdb..##TexasHoldEm_Game') IS NULL
    BEGIN
        SET @GameGone = 1;
        BREAK;
    END

    BEGIN TRAN;
    EXEC @rc = sp_getapplock @Resource = N'sp_TexasHoldEm', @LockMode = 'Exclusive',
                             @LockOwner = 'Transaction', @LockTimeout = 15000;
    IF @rc < 0
    BEGIN
        ROLLBACK;
        RAISERROR(N'Couldn''t get the table lock - the game is jammed up. Try again in a few seconds.', 16, 1);
        RETURN;
    END

    /* ================================================================
       FIRST PASS ONLY: create the game, take a seat, apply your action.
       ================================================================ */
    IF @FirstPass = 1
    BEGIN
        SET @FirstPass = 0;

        IF OBJECT_ID('tempdb..##TexasHoldEm_Game') IS NULL
        BEGIN
            IF @Action IN (N'Check', N'Call', N'Bet', N'Raise', N'Fold', N'Leave', N'Watch', N'Status')
            BEGIN
                COMMIT;
                SELECT [No Game] = N'There''s no game running. Run EXEC sp_TexasHoldEm to start one.';
                RETURN;
            END

            /* COLLATE DATABASE_DEFAULT keeps string comparisons working when
               the user database's collation differs from tempdb's. */
            /* Bootstrap race: two first-callers in DIFFERENT databases hold
               different applocks, so the CREATE itself is the tiebreaker -
               the loser hits error 2714 and gets the wrong-database refusal
               below instead of an ugly object-already-exists error. */
            BEGIN TRY

            CREATE TABLE ##TexasHoldEm_Game (
                GameState varchar(20) COLLATE DATABASE_DEFAULT NOT NULL,
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
                /* On SQL Server, ## tables are instance-global but applocks are
                   database-scoped, so the game claims a home database and turns
                   away sessions from anywhere else - one table per instance. */
                CreatedInDatabase nvarchar(128) COLLATE DATABASE_DEFAULT NOT NULL);

            CREATE TABLE ##TexasHoldEm_Players (
                SeatNum tinyint PRIMARY KEY,
                PlayerName nvarchar(30) COLLATE DATABASE_DEFAULT NOT NULL,
                SessionId int NOT NULL,
                IsBot bit NOT NULL,
                Chips int NOT NULL,
                Card1 tinyint NULL,
                Card2 tinyint NULL,
                InHand bit NOT NULL DEFAULT 0,
                Folded bit NOT NULL DEFAULT 0,
                AllIn bit NOT NULL DEFAULT 0,
                BetThisRound int NOT NULL DEFAULT 0,
                NeedsToAct bit NOT NULL DEFAULT 0,
                TimeoutStrikes tinyint NOT NULL DEFAULT 0,
                WantsToLeave bit NOT NULL DEFAULT 0);

            CREATE TABLE ##TexasHoldEm_Log (
                LogId int IDENTITY(1,1) PRIMARY KEY,
                HandNumber int NOT NULL,
                EventTime datetime2 NOT NULL DEFAULT SYSDATETIME(),
                Message nvarchar(500) COLLATE DATABASE_DEFAULT NOT NULL);

            INSERT ##TexasHoldEm_Game (GameState, HandNumber, JoinWindowEndsAt, CreatedInDatabase)
            VALUES ('WaitingForPlayers', 0, DATEADD(second, @JoinWindowSeconds, SYSDATETIME()), DB_NAME());

            INSERT ##TexasHoldEm_Log (HandNumber, Message)
            VALUES (0, CONCAT(N'A new Texas Hold ''Em game is starting! Waiting up to ', @JoinWindowSeconds,
                    N' seconds for players. Run EXEC sp_TexasHoldEm in other sessions to join.'));

            END TRY
            BEGIN CATCH
                IF ERROR_NUMBER() <> 2714 THROW;   /* only "object already exists" means we lost the race */
                IF @@TRANCOUNT > 0 ROLLBACK;       /* undo our half of the bootstrap, release our applock */

                /* Same-database racers are serialized by our applock, so the
                   winner is (almost) always another database. This read waits
                   for the winner's create/insert transaction to commit. */
                SET @OwnerDb = NULL;
                IF OBJECT_ID('tempdb..##TexasHoldEm_Game') IS NOT NULL
                    SELECT @OwnerDb = CreatedInDatabase FROM ##TexasHoldEm_Game;

                IF @OwnerDb IS NULL OR @OwnerDb = DB_NAME()
                    SELECT [Try Again] = N'Another session was starting a game at the same instant. Run EXEC sp_TexasHoldEm again to join it.';
                ELSE
                    SELECT [Wrong Database] = CONCAT(N'There''s already a game running from the [', @OwnerDb,
                        N'] database on this instance, and one table is all this casino''s got. Connect to that database to play.');
                RETURN;
            END CATCH
        END
        ELSE
        BEGIN
            /* Somebody else's game: make sure it lives in THIS database, because
               our applock can't protect a game that belongs to another one. */
            SET @OwnerDb = NULL;
            SELECT @OwnerDb = CreatedInDatabase FROM ##TexasHoldEm_Game;
            IF @OwnerDb IS NULL OR @OwnerDb <> DB_NAME()
            BEGIN
                COMMIT;
                SELECT [Wrong Database] = CONCAT(N'There''s already a game running from the [', @OwnerDb,
                    N'] database on this instance, and one table is all this casino''s got. Connect to that database to play.');
                RETURN;
            END

            SET @LastLogId = ISNULL((SELECT MAX(LogId) FROM ##TexasHoldEm_Log), 0) - 12;
            IF @LastLogId < 0 SET @LastLogId = 0;

            /* Last game ended? Joining sweeps up the confetti and starts fresh. */
            IF (SELECT GameState FROM ##TexasHoldEm_Game) = 'GameOver' AND @Action IS NULL
            BEGIN
                DELETE ##TexasHoldEm_Players;
                UPDATE ##TexasHoldEm_Game
                   SET GameState = 'WaitingForPlayers', HandNumber = 0, DealerSeat = NULL,
                       SmallBlindSeat = NULL, BigBlindSeat = NULL, BettingRound = NULL,
                       BoardShown = 0, ShowdownShown = 0,
                       Board1 = NULL, Board2 = NULL, Board3 = NULL, Board4 = NULL, Board5 = NULL,
                       Pot = 0, BetToCall = 0, RaiseCount = 0, TurnSeat = NULL, TurnStartedAt = NULL,
                       JoinWindowEndsAt = DATEADD(second, @JoinWindowSeconds, SYSDATETIME()),
                       NextHandStartsAt = NULL;
                INSERT ##TexasHoldEm_Log (HandNumber, Message)
                VALUES (0, CONCAT(N'A new game is starting! Waiting up to ', @JoinWindowSeconds,
                        N' seconds for players to join.'));
            END
        END

        /* Find my seat: by session first, then by name (that's how you
           reclaim your seat after reconnecting - your name is your key). */
        SET @MySeat = NULL;
        SELECT @MySeat = SeatNum FROM ##TexasHoldEm_Players WHERE SessionId = @@SPID AND IsBot = 0;
        /* Only actions that actually take control of the seat may reclaim it -
           a Status or Watch peek must never hijack a live player's session. */
        IF @MySeat IS NULL AND @PlayerName IS NOT NULL
           AND (@Action IS NULL OR @Action IN (N'Check', N'Call', N'Bet', N'Raise', N'Fold', N'Leave'))
        BEGIN
            SET @CurOwner = NULL;
            SELECT @MySeat = SeatNum, @CurOwner = SessionId
              FROM ##TexasHoldEm_Players WHERE PlayerName = @PlayerName AND IsBot = 0;
            IF @MySeat IS NOT NULL AND @CurOwner <> @@SPID
            BEGIN
                UPDATE ##TexasHoldEm_Players SET SessionId = @@SPID WHERE SeatNum = @MySeat;
                INSERT ##TexasHoldEm_Log (HandNumber, Message)
                SELECT HandNumber, CONCAT(@PlayerName, N' reconnected and reclaimed their seat.')
                FROM ##TexasHoldEm_Game;
            END
        END
        IF @MySeat IS NOT NULL AND @PlayerName IS NULL
            SELECT @PlayerName = PlayerName FROM ##TexasHoldEm_Players WHERE SeatNum = @MySeat;

        IF @Action = N'Watch' AND @MySeat IS NULL SET @IsObserver = 1;
        IF @Action = N'Status' SET @ReturnNow = 1;

        /* Take a seat if there's room; otherwise you're on the rail. */
        IF @MySeat IS NULL AND @IsObserver = 0 AND @ReturnNow = 0
        BEGIN
            IF @Action IN (N'Check', N'Call', N'Bet', N'Raise', N'Fold', N'Leave')
            BEGIN
                SET @Notice = N'You''re not seated at this table, so you can''t do that. Run EXEC sp_TexasHoldEm to join.';
                SET @ReturnNow = 1;
            END
            ELSE IF (SELECT COUNT(*) FROM ##TexasHoldEm_Players) >= @MaxSeats
            BEGIN
                SET @IsObserver = 1;
                SET @Notice = CONCAT(N'The table''s full (', @MaxSeats,
                    N' seats). You''re watching from the rail - you''ll see everything the public sees.');
            END
            ELSE
            BEGIN
                SET @PlayerName = COALESCE(@PlayerName, CONCAT(N'Player ', @@SPID));
                SELECT TOP (1) @MySeat = v.SeatNum
                FROM (VALUES (1),(2),(3),(4)) v(SeatNum)
                WHERE NOT EXISTS (SELECT 1 FROM ##TexasHoldEm_Players p WHERE p.SeatNum = v.SeatNum)
                ORDER BY v.SeatNum;

                INSERT ##TexasHoldEm_Players (SeatNum, PlayerName, SessionId, IsBot, Chips)
                VALUES (@MySeat, @PlayerName, @@SPID, 0, @StartingChips);

                INSERT ##TexasHoldEm_Log (HandNumber, Message)
                SELECT HandNumber,
                       CASE WHEN GameState = 'WaitingForPlayers'
                            THEN CONCAT(@PlayerName, N' joins the game with ', @StartingChips, N' chips.')
                            ELSE CONCAT(@PlayerName, N' sits down with ', @StartingChips,
                                 N' chips and will be dealt into the next hand.') END
                FROM ##TexasHoldEm_Game;
            END
        END

        /* Apply a betting action. */
        IF @MySeat IS NOT NULL AND @Action IN (N'Check', N'Call', N'Bet', N'Raise', N'Fold')
        BEGIN
            SELECT @GState = GameState, @TurnSeat = TurnSeat, @BetToCall = BetToCall,
                   @RaiseCount = RaiseCount, @Round = BettingRound, @GHand = HandNumber
            FROM ##TexasHoldEm_Game;
            SELECT @MyBet = BetThisRound, @MyChips = Chips, @MyNeedsToAct = NeedsToAct, @MyFolded = Folded
            FROM ##TexasHoldEm_Players WHERE SeatNum = @MySeat;

            IF @GState <> 'InHand' OR @TurnSeat <> @MySeat OR ISNULL(@MyNeedsToAct, 0) = 0 OR @MyFolded = 1
                SET @Notice = N'It''s not your turn right now (maybe the shot clock got you?). Hang tight.';
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
                    SET @Notice = N'Betting''s capped this round - you can Call or Fold.';
                    SET @ReturnNow = 1;
                END
                ELSE IF @Action IN (N'Bet', N'Raise') AND @MyChips < (@NewBet - @MyBet)
                BEGIN
                    SET @Notice = N'Not enough chips to raise. You can Call (all in if needed) or Fold.';
                    SET @ReturnNow = 1;
                END
                ELSE
                BEGIN
                    IF @Action = N'Fold'
                    BEGIN
                        UPDATE ##TexasHoldEm_Players SET Folded = 1, NeedsToAct = 0, TimeoutStrikes = 0
                         WHERE SeatNum = @MySeat;
                        INSERT ##TexasHoldEm_Log (HandNumber, Message) VALUES (@GHand, CONCAT(@PlayerName, N' folds.'));
                    END
                    ELSE IF @Action = N'Check' OR (@Action = N'Call' AND @Owed <= 0)
                    BEGIN
                        UPDATE ##TexasHoldEm_Players SET NeedsToAct = 0, TimeoutStrikes = 0
                         WHERE SeatNum = @MySeat;
                        INSERT ##TexasHoldEm_Log (HandNumber, Message) VALUES (@GHand, CONCAT(@PlayerName, N' checks.'));
                    END
                    ELSE IF @Action = N'Call'
                    BEGIN
                        SET @Pay = CASE WHEN @MyChips < @Owed THEN @MyChips ELSE @Owed END;
                        UPDATE ##TexasHoldEm_Players
                           SET Chips = Chips - @Pay, BetThisRound = BetThisRound + @Pay,
                               AllIn = CASE WHEN @MyChips <= @Owed THEN 1 ELSE 0 END,
                               NeedsToAct = 0, TimeoutStrikes = 0
                         WHERE SeatNum = @MySeat;
                        INSERT ##TexasHoldEm_Log (HandNumber, Message)
                        VALUES (@GHand, CONCAT(@PlayerName, N' calls ', @Pay,
                                CASE WHEN @MyChips <= @Owed THEN N' and is ALL IN.' ELSE N'.' END));
                    END
                    ELSE /* Bet / Raise */
                    BEGIN
                        SET @Pay = @NewBet - @MyBet;
                        UPDATE ##TexasHoldEm_Players
                           SET Chips = Chips - @Pay, BetThisRound = @NewBet,
                               AllIn = CASE WHEN @MyChips = @Pay THEN 1 ELSE 0 END,
                               NeedsToAct = 0, TimeoutStrikes = 0
                         WHERE SeatNum = @MySeat;
                        UPDATE ##TexasHoldEm_Players SET NeedsToAct = 1
                         WHERE InHand = 1 AND Folded = 0 AND AllIn = 0 AND SeatNum <> @MySeat;
                        UPDATE ##TexasHoldEm_Game SET BetToCall = @NewBet, RaiseCount = RaiseCount + 1;
                        INSERT ##TexasHoldEm_Log (HandNumber, Message)
                        VALUES (@GHand, CONCAT(@PlayerName,
                                CASE WHEN @BetToCall = 0 THEN N' bets ' ELSE N' raises to ' END, @NewBet, N'.'));
                    END

                    SET @NextSeat = NULL;
                    SELECT TOP (1) @NextSeat = SeatNum FROM ##TexasHoldEm_Players
                     WHERE InHand = 1 AND Folded = 0 AND AllIn = 0 AND NeedsToAct = 1
                     ORDER BY CASE WHEN SeatNum > @MySeat THEN 0 ELSE 1 END, SeatNum;
                    UPDATE ##TexasHoldEm_Game SET TurnSeat = @NextSeat, TurnStartedAt = SYSDATETIME();
                END
            END
        END

        /* Cash out. */
        IF @Action = N'Leave'
        BEGIN
            IF @MySeat IS NULL
                SET @Notice = N'You weren''t seated anyway. Easiest fold of your life.';
            ELSE
            BEGIN
                SELECT @GState = GameState, @GHand = HandNumber, @TurnSeat = TurnSeat FROM ##TexasHoldEm_Game;
                SELECT @MyInHand = InHand, @MyFolded = Folded FROM ##TexasHoldEm_Players WHERE SeatNum = @MySeat;

                IF @GState = 'InHand' AND @MyInHand = 1 AND @MyFolded = 0
                BEGIN
                    UPDATE ##TexasHoldEm_Players SET Folded = 1, NeedsToAct = 0, WantsToLeave = 1
                     WHERE SeatNum = @MySeat;
                    INSERT ##TexasHoldEm_Log (HandNumber, Message)
                    VALUES (@GHand, CONCAT(@PlayerName, N' folds and is cashing out after this hand.'));
                    IF @TurnSeat = @MySeat
                    BEGIN
                        SET @NextSeat = NULL;
                        SELECT TOP (1) @NextSeat = SeatNum FROM ##TexasHoldEm_Players
                         WHERE InHand = 1 AND Folded = 0 AND AllIn = 0 AND NeedsToAct = 1
                         ORDER BY CASE WHEN SeatNum > @MySeat THEN 0 ELSE 1 END, SeatNum;
                        UPDATE ##TexasHoldEm_Game SET TurnSeat = @NextSeat, TurnStartedAt = SYSDATETIME();
                    END
                    SET @Notice = N'You''ve folded. Your chips leave the table with you when this hand ends.';
                END
                ELSE IF @GState = 'InHand' AND @MyInHand = 1 AND @MyFolded = 1
                BEGIN
                    UPDATE ##TexasHoldEm_Players SET WantsToLeave = 1 WHERE SeatNum = @MySeat;
                    SET @Notice = N'You''ll be removed when this hand ends. Thanks for playing!';
                END
                ELSE
                BEGIN
                    INSERT ##TexasHoldEm_Log (HandNumber, Message)
                    SELECT @GHand, CONCAT(@PlayerName, N' leaves the table with ', Chips, N' chips.')
                    FROM ##TexasHoldEm_Players WHERE SeatNum = @MySeat;
                    DELETE ##TexasHoldEm_Players WHERE SeatNum = @MySeat;
                    SET @Notice = N'You''ve left the table. Thanks for playing!';
                END
                SET @LeftTable = 1;
            END
            SET @ReturnNow = 1;
        END

        /* Which hand am I waiting to see finish? */
        SELECT @GState = GameState, @GHand = HandNumber FROM ##TexasHoldEm_Game;
        SET @TargetHand = CASE WHEN @GState = 'InHand' THEN @GHand ELSE @GHand + 1 END;
    END /* first pass */

    IF @FirstPass = 0
    BEGIN
        /* If the game evaporated and a session in a DIFFERENT database started
           a new one between our polls, our applock doesn't cover it - back out. */
        SET @OwnerDb = NULL;
        SELECT @OwnerDb = CreatedInDatabase FROM ##TexasHoldEm_Game;
        IF @OwnerDb IS NULL OR @OwnerDb <> DB_NAME()
        BEGIN
            COMMIT;
            SET @GameGone = 1;
            BREAK;
        END
    END

    /* ================================================================
       THE ENGINE. Any session holding the lock advances everything that
       is ready to advance: the join clock, robot decisions, human shot
       clocks, streets, showdowns, and the next hand. Runs until the game
       is waiting on a live human (or the join clock).
       ================================================================ */
    SET @Spins = 0;
    WHILE @Spins < 200
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
        FROM ##TexasHoldEm_Game;

        IF @GState = 'GameOver' BREAK;

        IF @GState = 'WaitingForPlayers'
        BEGIN
            SELECT @NumPlayers = COUNT(*) FROM ##TexasHoldEm_Players;
            IF @NumPlayers = 0 BREAK;
            IF SYSDATETIME() < @JoinEnds AND @NumPlayers < @MaxSeats BREAK;

            IF @NumPlayers = 1
            BEGIN
                /* Nobody came. Release the robots. */
                ;WITH freeseats AS (
                    SELECT v.SeatNum, rn = ROW_NUMBER() OVER (ORDER BY v.SeatNum)
                    FROM (VALUES (1),(2),(3),(4)) v(SeatNum)
                    WHERE NOT EXISTS (SELECT 1 FROM ##TexasHoldEm_Players p WHERE p.SeatNum = v.SeatNum)),
                bots AS (
                    SELECT b.BotName, rn = ROW_NUMBER() OVER (ORDER BY b.SortOrder)
                    FROM (VALUES (1, N'Clippy'), (2, N'HAL'), (3, N'Bender')) b(SortOrder, BotName))
                INSERT ##TexasHoldEm_Players (SeatNum, PlayerName, SessionId, IsBot, Chips)
                SELECT f.SeatNum, b.BotName, 0, 1, @StartingChips
                FROM freeseats f JOIN bots b ON b.rn = f.rn;

                INSERT ##TexasHoldEm_Log (HandNumber, Message)
                VALUES (@GHand, N'Nobody else joined, so the robots are sitting in: Clippy, HAL, and Bender. Good luck.');
            END
            SET @StartHandNow = 1;
        END

        IF @GState = 'BetweenHands'
        BEGIN
            IF SYSDATETIME() < @NextHandAt BREAK;
            SET @StartHandNow = 1;
        END

        IF @StartHandNow = 1
        BEGIN
            /* ===== Start a new hand: button, blinds, shuffle, deal. ===== */
            SET @PrevDealer = ISNULL(@Dealer, 0);
            SET @GHand += 1;

            UPDATE ##TexasHoldEm_Players
               SET InHand = CASE WHEN Chips > 0 THEN 1 ELSE 0 END,
                   Folded = 0, AllIn = 0, BetThisRound = 0, NeedsToAct = 0,
                   Card1 = NULL, Card2 = NULL;

            SELECT @NumInHand = COUNT(*) FROM ##TexasHoldEm_Players WHERE InHand = 1;
            IF @NumInHand < 2
            BEGIN
                UPDATE ##TexasHoldEm_Game SET GameState = 'GameOver', HandNumber = @GHand, TurnSeat = NULL;
                INSERT ##TexasHoldEm_Log (HandNumber, Message) VALUES (@GHand, N'Not enough players to deal. GAME OVER.');
                CONTINUE;
            END

            SET @Dealer = NULL;
            SELECT TOP (1) @Dealer = SeatNum FROM ##TexasHoldEm_Players WHERE InHand = 1
             ORDER BY CASE WHEN SeatNum > @PrevDealer THEN 0 ELSE 1 END, SeatNum;

            IF @NumInHand = 2
            BEGIN
                /* Heads-up: the dealer posts the small blind and acts first pre-flop. */
                SET @SBSeat = @Dealer;
                SET @BBSeat = NULL;
                SELECT TOP (1) @BBSeat = SeatNum FROM ##TexasHoldEm_Players
                 WHERE InHand = 1 AND SeatNum <> @Dealer;
            END
            ELSE
            BEGIN
                SET @SBSeat = NULL;
                SELECT TOP (1) @SBSeat = SeatNum FROM ##TexasHoldEm_Players WHERE InHand = 1 AND SeatNum <> @Dealer
                 ORDER BY CASE WHEN SeatNum > @Dealer THEN 0 ELSE 1 END, SeatNum;
                SET @BBSeat = NULL;
                SELECT TOP (1) @BBSeat = SeatNum FROM ##TexasHoldEm_Players WHERE InHand = 1 AND SeatNum <> @SBSeat
                 ORDER BY CASE WHEN SeatNum > @SBSeat THEN 0 ELSE 1 END, SeatNum;
            END

            DELETE @Shuffled;
            INSERT @Shuffled (Pos, CardId)
            SELECT ROW_NUMBER() OVER (ORDER BY NEWID()), CardId FROM #Cards;

            ;WITH p AS (SELECT SeatNum, Card1, Card2, rn = ROW_NUMBER() OVER (ORDER BY SeatNum)
                        FROM ##TexasHoldEm_Players WHERE InHand = 1)
            UPDATE p SET Card1 = s1.CardId, Card2 = s2.CardId
            FROM p
            JOIN @Shuffled AS s1 ON s1.Pos = p.rn
            JOIN @Shuffled AS s2 ON s2.Pos = p.rn + @NumInHand;

            UPDATE g SET Board1 = b1.CardId, Board2 = b2.CardId, Board3 = b3.CardId,
                         Board4 = b4.CardId, Board5 = b5.CardId
            FROM ##TexasHoldEm_Game g
            JOIN @Shuffled AS b1 ON b1.Pos = @NumInHand * 2 + 1
            JOIN @Shuffled AS b2 ON b2.Pos = @NumInHand * 2 + 2
            JOIN @Shuffled AS b3 ON b3.Pos = @NumInHand * 2 + 3
            JOIN @Shuffled AS b4 ON b4.Pos = @NumInHand * 2 + 4
            JOIN @Shuffled AS b5 ON b5.Pos = @NumInHand * 2 + 5;

            UPDATE ##TexasHoldEm_Players
               SET BetThisRound = CASE WHEN Chips < @SmallBlind THEN Chips ELSE @SmallBlind END,
                   AllIn = CASE WHEN Chips <= @SmallBlind THEN 1 ELSE 0 END,
                   Chips = CASE WHEN Chips < @SmallBlind THEN 0 ELSE Chips - @SmallBlind END
             WHERE SeatNum = @SBSeat;

            UPDATE ##TexasHoldEm_Players
               SET BetThisRound = CASE WHEN Chips < @BigBlind THEN Chips ELSE @BigBlind END,
                   AllIn = CASE WHEN Chips <= @BigBlind THEN 1 ELSE 0 END,
                   Chips = CASE WHEN Chips < @BigBlind THEN 0 ELSE Chips - @BigBlind END
             WHERE SeatNum = @BBSeat;

            UPDATE ##TexasHoldEm_Players SET NeedsToAct = 1 WHERE InHand = 1 AND AllIn = 0;

            SET @NextSeat = NULL;
            SELECT TOP (1) @NextSeat = SeatNum FROM ##TexasHoldEm_Players
             WHERE InHand = 1 AND Folded = 0 AND AllIn = 0 AND NeedsToAct = 1
             ORDER BY CASE WHEN SeatNum > @BBSeat THEN 0 ELSE 1 END, SeatNum;

            UPDATE ##TexasHoldEm_Game
               SET GameState = 'InHand', HandNumber = @GHand, DealerSeat = @Dealer,
                   SmallBlindSeat = @SBSeat, BigBlindSeat = @BBSeat,
                   BettingRound = 0, BoardShown = 0, ShowdownShown = 0, Pot = 0,
                   BetToCall = @BigBlind, RaiseCount = 1,
                   TurnSeat = @NextSeat, TurnStartedAt = SYSDATETIME(),
                   JoinWindowEndsAt = NULL, NextHandStartsAt = NULL;

            INSERT ##TexasHoldEm_Log (HandNumber, Message)
            SELECT @GHand, CONCAT(N'=== HAND #', @GHand, N' === ', d.PlayerName, N' has the button. ',
                   s.PlayerName, N' posts the small blind (', @SmallBlind, N'), ',
                   b.PlayerName, N' posts the big blind (', @BigBlind, N'). Cards are in the air!')
            FROM ##TexasHoldEm_Players d
            CROSS JOIN ##TexasHoldEm_Players s
            CROSS JOIN ##TexasHoldEm_Players b
            WHERE d.SeatNum = @Dealer AND s.SeatNum = @SBSeat AND b.SeatNum = @BBSeat;

            CONTINUE;
        END

        /* ===== From here down, a hand is in progress. ===== */
        SELECT @Unfolded = COUNT(*) FROM ##TexasHoldEm_Players WHERE InHand = 1 AND Folded = 0;

        IF @Unfolded <= 1
        BEGIN
            /* Everybody else folded - no showdown, no peeking. */
            SELECT @RoundBets = ISNULL(SUM(BetThisRound), 0) FROM ##TexasHoldEm_Players WHERE InHand = 1;
            UPDATE ##TexasHoldEm_Players SET BetThisRound = 0 WHERE InHand = 1;
            SET @Pot += @RoundBets;

            SET @WinSeat = NULL;
            SELECT @WinSeat = SeatNum, @WinName = PlayerName
            FROM ##TexasHoldEm_Players WHERE InHand = 1 AND Folded = 0;
            UPDATE ##TexasHoldEm_Players SET Chips = Chips + @Pot WHERE SeatNum = @WinSeat;
            INSERT ##TexasHoldEm_Log (HandNumber, Message)
            VALUES (@GHand, CONCAT(N'Everyone else folded. ', @WinName, N' rakes in ', @Pot, N' chips without showing.'));
            UPDATE ##TexasHoldEm_Game SET Pot = 0, TurnSeat = NULL;
            SET @HandDone = 1;
        END
        ELSE IF NOT EXISTS (SELECT 1 FROM ##TexasHoldEm_Players
                            WHERE InHand = 1 AND Folded = 0 AND AllIn = 0 AND NeedsToAct = 1)
        BEGIN
            /* Betting round complete: sweep the bets into the pot. */
            SELECT @RoundBets = ISNULL(SUM(BetThisRound), 0) FROM ##TexasHoldEm_Players WHERE InHand = 1;
            UPDATE ##TexasHoldEm_Players SET BetThisRound = 0 WHERE InHand = 1;
            SET @Pot += @RoundBets;
            UPDATE ##TexasHoldEm_Game SET Pot = @Pot, BetToCall = 0, RaiseCount = 0, TurnSeat = NULL;

            IF @Round >= 3
            BEGIN
                /* ===== SHOWDOWN ===== */
                DELETE @ShowResults;
                DECLARE cur_show CURSOR LOCAL FAST_FORWARD FOR
                    SELECT SeatNum, PlayerName, Card1, Card2
                    FROM ##TexasHoldEm_Players WHERE InHand = 1 AND Folded = 0
                    ORDER BY CASE WHEN SeatNum > @Dealer THEN 0 ELSE 1 END, SeatNum;
                OPEN cur_show;
                FETCH NEXT FROM cur_show INTO @cSeat, @cName, @cC1, @cC2;
                WHILE @@FETCH_STATUS = 0
                BEGIN
                    /* Evaluate the best 5-card hand from these 7 cards. */
                    DELETE @Seven;
                    INSERT @Seven (CardRank, CardSuit)
                    SELECT CardRank, CardSuit FROM #Cards
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
                                  (SELECT RankName FROM #RankNames WHERE RankValue = @SFHigh), N' high') END;
                    END
                    ELSE IF @Quad IS NOT NULL
                    BEGIN
                        SET @Cat = 7; SET @T1 = @Quad;
                        SELECT @T2 = MAX(CardRank) FROM @Seven WHERE CardRank <> @Quad;
                        SET @HandName = CONCAT(N'Four of a Kind, ',
                             (SELECT RankPlural FROM #RankNames WHERE RankValue = @Quad));
                    END
                    ELSE IF @Trip IS NOT NULL AND @FHPair IS NOT NULL
                    BEGIN
                        SET @Cat = 6; SET @T1 = @Trip; SET @T2 = @FHPair;
                        SET @HandName = CONCAT(N'a Full House, ',
                             (SELECT RankPlural FROM #RankNames WHERE RankValue = @Trip), N' over ',
                             (SELECT RankPlural FROM #RankNames WHERE RankValue = @FHPair));
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
                             (SELECT RankName FROM #RankNames WHERE RankValue = @T1), N' high');
                    END
                    ELSE IF @StraightHigh IS NOT NULL
                    BEGIN
                        SET @Cat = 4; SET @T1 = @StraightHigh;
                        SET @HandName = CONCAT(N'a Straight, ',
                             (SELECT RankName FROM #RankNames WHERE RankValue = @StraightHigh), N' high');
                    END
                    ELSE IF @Trip IS NOT NULL
                    BEGIN
                        SET @Cat = 3; SET @T1 = @Trip;
                        SELECT @T2 = MAX(CardRank) FROM @Seven WHERE CardRank <> @Trip;
                        SELECT @T3 = MAX(CardRank) FROM @Seven WHERE CardRank <> @Trip AND CardRank <> @T2;
                        SET @HandName = CONCAT(N'Three of a Kind, ',
                             (SELECT RankPlural FROM #RankNames WHERE RankValue = @Trip));
                    END
                    ELSE IF @Pair2 IS NOT NULL
                    BEGIN
                        SET @Cat = 2; SET @T1 = @Pair1; SET @T2 = @Pair2;
                        SELECT @T3 = MAX(CardRank) FROM @Seven WHERE CardRank <> @Pair1 AND CardRank <> @Pair2;
                        SET @HandName = CONCAT(N'Two Pair, ',
                             (SELECT RankPlural FROM #RankNames WHERE RankValue = @Pair1), N' and ',
                             (SELECT RankPlural FROM #RankNames WHERE RankValue = @Pair2));
                    END
                    ELSE IF @Pair1 IS NOT NULL
                    BEGIN
                        SET @Cat = 1; SET @T1 = @Pair1;
                        SELECT @T2 = MAX(CardRank) FROM @Seven WHERE CardRank <> @Pair1;
                        SELECT @T3 = MAX(CardRank) FROM @Seven WHERE CardRank <> @Pair1 AND CardRank <> @T2;
                        SELECT @T4 = MAX(CardRank) FROM @Seven WHERE CardRank <> @Pair1 AND CardRank NOT IN (@T2, @T3);
                        SET @HandName = CONCAT(N'a Pair of ',
                             (SELECT RankPlural FROM #RankNames WHERE RankValue = @Pair1));
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
                             (SELECT RankName FROM #RankNames WHERE RankValue = @T1), N' high');
                    END

                    SET @Score = @Cat * CAST(10000000000 AS bigint)
                               + @T1 * 100000000 + @T2 * 1000000 + @T3 * 10000 + @T4 * 100 + @T5;

                    INSERT @ShowResults (SeatNum, PlayerName, Score, HandName)
                    VALUES (@cSeat, @cName, @Score, @HandName);

                    SELECT @Msg = CONCAT(@cName, N' shows ', c1.Display, N' ', c2.Display, N' - ', @HandName, N'.')
                    FROM #Cards c1 CROSS JOIN #Cards c2
                    WHERE c1.CardId = @cC1 AND c2.CardId = @cC2;
                    INSERT ##TexasHoldEm_Log (HandNumber, Message) VALUES (@GHand, @Msg);

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
                UPDATE p SET Chips = p.Chips + @Share + CASE WHEN w.rn <= @Rem THEN 1 ELSE 0 END
                FROM ##TexasHoldEm_Players p JOIN w ON w.SeatNum = p.SeatNum;

                IF @NumWinners = 1
                    INSERT ##TexasHoldEm_Log (HandNumber, Message)
                    SELECT @GHand, CONCAT(PlayerName, N' wins the pot (', @Pot, N') with ', HandName, N'!')
                    FROM @ShowResults WHERE Score = @BestScore;
                ELSE
                    INSERT ##TexasHoldEm_Log (HandNumber, Message)
                    SELECT @GHand, CONCAT(x.WinnerNames, N' split the pot (', @Pot, N').')
                    FROM (SELECT WinnerNames = STRING_AGG(PlayerName, N' and ')
                          FROM @ShowResults WHERE Score = @BestScore) x;

                UPDATE ##TexasHoldEm_Game SET Pot = 0, ShowdownShown = 1;
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
                JOIN #Cards c ON c.CardId = b.cid
                WHERE b.ord <= @BoardShown;

                INSERT ##TexasHoldEm_Log (HandNumber, Message)
                VALUES (@GHand, CONCAT(N'*** ', CASE @Round WHEN 1 THEN N'FLOP' WHEN 2 THEN N'TURN' ELSE N'RIVER' END,
                        N': ', @BoardDisp, N' *** (pot: ', @Pot, N')'));

                UPDATE ##TexasHoldEm_Game SET BettingRound = @Round, BoardShown = @BoardShown;

                SELECT @ActiveBettors = COUNT(*) FROM ##TexasHoldEm_Players
                 WHERE InHand = 1 AND Folded = 0 AND AllIn = 0;
                IF @ActiveBettors >= 2
                BEGIN
                    UPDATE ##TexasHoldEm_Players SET NeedsToAct = 1
                     WHERE InHand = 1 AND Folded = 0 AND AllIn = 0;
                    SET @NextSeat = NULL;
                    SELECT TOP (1) @NextSeat = SeatNum FROM ##TexasHoldEm_Players
                     WHERE InHand = 1 AND Folded = 0 AND AllIn = 0 AND NeedsToAct = 1
                     ORDER BY CASE WHEN SeatNum > @Dealer THEN 0 ELSE 1 END, SeatNum;
                    UPDATE ##TexasHoldEm_Game SET TurnSeat = @NextSeat, TurnStartedAt = SYSDATETIME();
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
            FROM ##TexasHoldEm_Players;
            INSERT ##TexasHoldEm_Log (HandNumber, Message) VALUES (@GHand, @Msg);

            INSERT ##TexasHoldEm_Log (HandNumber, Message)
            SELECT @GHand, CONCAT(PlayerName, N' is out of chips and leaves the table.')
            FROM ##TexasHoldEm_Players WHERE Chips <= 0;
            DELETE ##TexasHoldEm_Players WHERE Chips <= 0;

            INSERT ##TexasHoldEm_Log (HandNumber, Message)
            SELECT @GHand, CONCAT(PlayerName, N' cashes out ', Chips, N' chips and leaves.')
            FROM ##TexasHoldEm_Players WHERE WantsToLeave = 1;
            DELETE ##TexasHoldEm_Players WHERE WantsToLeave = 1;

            SELECT @NumPlayers = COUNT(*),
                   @HumansLeft = ISNULL(SUM(CASE WHEN IsBot = 0 THEN 1 ELSE 0 END), 0)
            FROM ##TexasHoldEm_Players;

            IF @NumPlayers = 0
            BEGIN
                INSERT ##TexasHoldEm_Log (HandNumber, Message) VALUES (@GHand, N'Everyone''s gone home. GAME OVER.');
                UPDATE ##TexasHoldEm_Game SET GameState = 'GameOver', TurnSeat = NULL;
            END
            ELSE IF @HumansLeft = 0
            BEGIN
                INSERT ##TexasHoldEm_Log (HandNumber, Message)
                VALUES (@GHand, N'No humans remain. The machines win. GAME OVER.');
                UPDATE ##TexasHoldEm_Game SET GameState = 'GameOver', TurnSeat = NULL;
            END
            ELSE IF @NumPlayers = 1
            BEGIN
                INSERT ##TexasHoldEm_Log (HandNumber, Message)
                SELECT @GHand, CONCAT(N'*** ', PlayerName, N' WINS IT ALL with ', Chips, N' chips! GAME OVER. ***')
                FROM ##TexasHoldEm_Players;
                UPDATE ##TexasHoldEm_Game SET GameState = 'GameOver', TurnSeat = NULL;
            END
            ELSE
            BEGIN
                INSERT ##TexasHoldEm_Log (HandNumber, Message)
                VALUES (@GHand, CONCAT(N'Next hand in ', @BetweenHandsSeconds,
                        N' seconds. (If your query already finished, run EXEC sp_TexasHoldEm to keep playing.)'));
                UPDATE ##TexasHoldEm_Game
                   SET GameState = 'BetweenHands', TurnSeat = NULL,
                       NextHandStartsAt = DATEADD(second, @BetweenHandsSeconds, SYSDATETIME());
            END
            CONTINUE;
        END

        /* ===== Somebody owes the table a decision. ===== */
        SET @ActorSeat = NULL;
        SELECT @ActorSeat = SeatNum, @ActorBot = IsBot, @ActorName = PlayerName,
               @ActorChips = Chips, @ActorBet = BetThisRound, @ActorStrikes = TimeoutStrikes
        FROM ##TexasHoldEm_Players
        WHERE SeatNum = @TurnSeat AND InHand = 1 AND Folded = 0 AND AllIn = 0 AND NeedsToAct = 1;

        IF @ActorSeat IS NULL
        BEGIN
            /* Stale turn pointer (someone folded out of turn, etc.) - repoint it. */
            SET @NextSeat = NULL;
            SELECT TOP (1) @NextSeat = SeatNum FROM ##TexasHoldEm_Players
             WHERE InHand = 1 AND Folded = 0 AND AllIn = 0 AND NeedsToAct = 1
             ORDER BY CASE WHEN SeatNum > ISNULL(@TurnSeat, @Dealer) THEN 0 ELSE 1 END, SeatNum;
            UPDATE ##TexasHoldEm_Game SET TurnSeat = @NextSeat, TurnStartedAt = SYSDATETIME();
            CONTINUE;
        END

        SET @Owed = @BetToCall - @ActorBet;
        SET @Unit = CASE WHEN @Round <= 1 THEN @SmallBet ELSE @BigBet END;
        SET @NewBet = CASE WHEN @BetToCall = 0 THEN @Unit ELSE @BetToCall + @Unit END;

        IF @ActorBot = 1
        BEGIN
            /* The robot "brain": mostly calls, sometimes raises, occasionally
               remembers it has feelings and folds. Do not study this for GTO. */
            SET @r = ABS(CONVERT(bigint, CHECKSUM(NEWID()))) % 100;
            IF @Owed <= 0
            BEGIN
                IF @r < 70 OR @RaiseCount >= @MaxRaises OR @ActorChips < (@NewBet - @ActorBet)
                    SET @BotMove = 'Check';
                ELSE
                    SET @BotMove = 'Raise';
            END
            ELSE
            BEGIN
                IF @r < 55 SET @BotMove = 'Call';
                ELSE IF @r < 78 AND @RaiseCount < @MaxRaises AND @ActorChips >= (@NewBet - @ActorBet)
                    SET @BotMove = 'Raise';
                ELSE IF @r < 82 SET @BotMove = 'Call';
                ELSE SET @BotMove = 'Fold';
            END

            IF @BotMove = 'Check'
            BEGIN
                UPDATE ##TexasHoldEm_Players SET NeedsToAct = 0 WHERE SeatNum = @ActorSeat;
                INSERT ##TexasHoldEm_Log (HandNumber, Message) VALUES (@GHand, CONCAT(@ActorName, N' checks.'));
            END
            ELSE IF @BotMove = 'Call'
            BEGIN
                SET @Pay = CASE WHEN @ActorChips < @Owed THEN @ActorChips ELSE @Owed END;
                UPDATE ##TexasHoldEm_Players
                   SET Chips = Chips - @Pay, BetThisRound = BetThisRound + @Pay,
                       AllIn = CASE WHEN @ActorChips <= @Owed THEN 1 ELSE 0 END, NeedsToAct = 0
                 WHERE SeatNum = @ActorSeat;
                INSERT ##TexasHoldEm_Log (HandNumber, Message)
                VALUES (@GHand, CONCAT(@ActorName, N' calls ', @Pay,
                        CASE WHEN @ActorChips <= @Owed THEN N' and is ALL IN.' ELSE N'.' END));
            END
            ELSE IF @BotMove = 'Raise'
            BEGIN
                SET @Pay = @NewBet - @ActorBet;
                UPDATE ##TexasHoldEm_Players
                   SET Chips = Chips - @Pay, BetThisRound = @NewBet,
                       AllIn = CASE WHEN @ActorChips = @Pay THEN 1 ELSE 0 END, NeedsToAct = 0
                 WHERE SeatNum = @ActorSeat;
                UPDATE ##TexasHoldEm_Players SET NeedsToAct = 1
                 WHERE InHand = 1 AND Folded = 0 AND AllIn = 0 AND SeatNum <> @ActorSeat;
                UPDATE ##TexasHoldEm_Game SET BetToCall = @NewBet, RaiseCount = RaiseCount + 1;
                INSERT ##TexasHoldEm_Log (HandNumber, Message)
                VALUES (@GHand, CONCAT(@ActorName,
                        CASE WHEN @BetToCall = 0 THEN N' bets ' ELSE N' raises to ' END, @NewBet, N'.'));
            END
            ELSE
            BEGIN
                UPDATE ##TexasHoldEm_Players SET Folded = 1, NeedsToAct = 0 WHERE SeatNum = @ActorSeat;
                INSERT ##TexasHoldEm_Log (HandNumber, Message) VALUES (@GHand, CONCAT(@ActorName, N' folds.'));
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
                    INSERT ##TexasHoldEm_Log (HandNumber, Message) VALUES (@GHand, @Msg);
            END

            SET @NextSeat = NULL;
            SELECT TOP (1) @NextSeat = SeatNum FROM ##TexasHoldEm_Players
             WHERE InHand = 1 AND Folded = 0 AND AllIn = 0 AND NeedsToAct = 1
             ORDER BY CASE WHEN SeatNum > @ActorSeat THEN 0 ELSE 1 END, SeatNum;
            UPDATE ##TexasHoldEm_Game SET TurnSeat = @NextSeat, TurnStartedAt = SYSDATETIME();
            CONTINUE;
        END

        /* A human's turn: enforce the shot clock. */
        IF DATEDIFF(second, @TurnStartedAt, SYSDATETIME()) >= @TurnSeconds
        BEGIN
            IF @Owed > 0
            BEGIN
                UPDATE ##TexasHoldEm_Players SET Folded = 1, NeedsToAct = 0, TimeoutStrikes = TimeoutStrikes + 1
                 WHERE SeatNum = @ActorSeat;
                INSERT ##TexasHoldEm_Log (HandNumber, Message)
                VALUES (@GHand, CONCAT(@ActorName, N' took too long and folds.'));
            END
            ELSE
            BEGIN
                UPDATE ##TexasHoldEm_Players SET NeedsToAct = 0, TimeoutStrikes = TimeoutStrikes + 1
                 WHERE SeatNum = @ActorSeat;
                INSERT ##TexasHoldEm_Log (HandNumber, Message)
                VALUES (@GHand, CONCAT(@ActorName, N' took too long and checks.'));
            END

            IF @ActorStrikes + 1 >= @MaxTimeoutStrikes
            BEGIN
                UPDATE ##TexasHoldEm_Players SET WantsToLeave = 1 WHERE SeatNum = @ActorSeat;
                INSERT ##TexasHoldEm_Log (HandNumber, Message)
                VALUES (@GHand, CONCAT(@ActorName, N' has timed out ', @MaxTimeoutStrikes,
                        N' times and will be removed after this hand.'));
            END

            SET @NextSeat = NULL;
            SELECT TOP (1) @NextSeat = SeatNum FROM ##TexasHoldEm_Players
             WHERE InHand = 1 AND Folded = 0 AND AllIn = 0 AND NeedsToAct = 1
             ORDER BY CASE WHEN SeatNum > @ActorSeat THEN 0 ELSE 1 END, SeatNum;
            UPDATE ##TexasHoldEm_Game SET TurnSeat = @NextSeat, TurnStartedAt = SYSDATETIME();
            CONTINUE;
        END

        BREAK; /* A live human is thinking. Nothing for the engine to do. */
    END /* engine */

    /* ================================================================
       Snapshot the world for this session, then let go of the lock.
       ================================================================ */
    SELECT @GState = GameState, @GHand = HandNumber, @TurnSeat = TurnSeat,
           @TurnStartedAt = TurnStartedAt, @Round = BettingRound, @Pot = Pot,
           @BetToCall = BetToCall, @RaiseCount = RaiseCount, @BoardShown = BoardShown
    FROM ##TexasHoldEm_Game;

    SET @SeatExists = 0; SET @CurOwner = NULL; SET @MyNeedsToAct = 0; SET @MyFolded = 0;
    SET @MyInHand = 0; SET @MyC1 = NULL; SET @MyC2 = NULL; SET @MyChips = NULL; SET @MyBet = 0;
    IF @MySeat IS NOT NULL
        SELECT @SeatExists = 1, @CurOwner = SessionId, @MyNeedsToAct = NeedsToAct,
               @MyFolded = Folded, @MyInHand = InHand, @MyC1 = Card1, @MyC2 = Card2,
               @MyChips = Chips, @MyBet = BetThisRound
        FROM ##TexasHoldEm_Players WHERE SeatNum = @MySeat;

    DELETE @NewLog;
    INSERT @NewLog (LogId, Message)
    SELECT LogId, Message FROM ##TexasHoldEm_Log WHERE LogId > @LastLogId;
    SELECT @LastLogId = ISNULL(MAX(LogId), @LastLogId) FROM @NewLog;

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
        FROM #Cards c1 CROSS JOIN #Cards c2 WHERE c1.CardId = @MyC1 AND c2.CardId = @MyC2;
        SET @Msg = CONCAT(N'>>> Your hole cards, ', @PlayerName, N': ', @MyCards, N' <<<');
        RAISERROR(N'%s', 0, 1, @Msg) WITH NOWAIT;
        SET @CardsShownForHand = @GHand;
    END

    IF @Notice IS NOT NULL
    BEGIN
        RAISERROR(N'%s', 0, 1, @Notice) WITH NOWAIT;
        SET @Notice = NULL;
    END

    /* Is there a reason to give this session its results back? */
    IF @ReturnNow = 1 BREAK;
    IF @GState = 'GameOver' BREAK;
    IF @IsObserver = 0 AND @MySeat IS NOT NULL AND @SeatExists = 1 AND @CurOwner <> @@SPID
    BEGIN
        SET @SeatStolen = 1;
        BREAK;
    END
    IF @IsObserver = 0 AND @MySeat IS NOT NULL AND @SeatExists = 0 BREAK;      /* busted or removed */
    IF @GState = 'InHand' AND @SeatExists = 1 AND @TurnSeat = @MySeat
       AND @MyNeedsToAct = 1 AND @MyFolded = 0 BREAK;                          /* your move! */
    IF @GState = 'BetweenHands' AND @GHand >= @TargetHand BREAK;               /* hand's over */
    IF DATEDIFF(minute, @WaitStart, SYSDATETIME()) >= @MaxWaitMinutes
    BEGIN
        SET @GaveUp = 1;
        BREAK;
    END

    IF @ToldWaiting = 0
    BEGIN
        RAISERROR(N'(Waiting for the action - watch this Messages tab. Your query finishes when you need to do something.)', 0, 1) WITH NOWAIT;
        SET @ToldWaiting = 1;
    END

    WAITFOR DELAY '00:00:02';
END /* main wait loop */

/* ================================================================
   Show this session everything: the table, the players, the action,
   and exactly what to run next.
   ================================================================ */
IF @GameGone = 1 OR OBJECT_ID('tempdb..##TexasHoldEm_Game') IS NULL
BEGIN
    SELECT [House Fire] = N'The game vanished! Global temp tables disappear when the session that created the game disconnects. Run EXEC sp_TexasHoldEm to start a new one.';
    RETURN;
END

SELECT @GState = GameState, @GHand = HandNumber, @Dealer = DealerSeat,
       @SBSeat = SmallBlindSeat, @BBSeat = BigBlindSeat, @Round = BettingRound,
       @BoardShown = BoardShown, @ShowdownShown = ShowdownShown, @Pot = Pot,
       @BetToCall = BetToCall, @RaiseCount = RaiseCount, @TurnSeat = TurnSeat,
       @TurnStartedAt = TurnStartedAt, @JoinEnds = JoinWindowEndsAt,
       @B1 = Board1, @B2 = Board2, @B3 = Board3, @B4 = Board4, @B5 = Board5
FROM ##TexasHoldEm_Game;

SET @SeatExists = 0; SET @MyNeedsToAct = 0; SET @MyFolded = 0; SET @MyInHand = 0;
SET @MyC1 = NULL; SET @MyC2 = NULL; SET @MyChips = NULL; SET @MyBet = 0; SET @MyCards = NULL;
IF @MySeat IS NOT NULL
    SELECT @SeatExists = 1, @MyNeedsToAct = NeedsToAct, @MyFolded = Folded, @MyInHand = InHand,
           @MyC1 = Card1, @MyC2 = Card2, @MyChips = Chips, @MyBet = BetThisRound
    FROM ##TexasHoldEm_Players WHERE SeatNum = @MySeat;
IF @MyC1 IS NOT NULL
    SELECT @MyCards = CONCAT(c1.Display, N' ', c2.Display)
    FROM #Cards c1 CROSS JOIN #Cards c2 WHERE c1.CardId = @MyC1 AND c2.CardId = @MyC2;

SET @BoardDisp = NULL;
SELECT @BoardDisp = STRING_AGG(c.Display, N' ') WITHIN GROUP (ORDER BY b.ord)
FROM (VALUES (1, @B1), (2, @B2), (3, @B3), (4, @B4), (5, @B5)) b(ord, cid)
JOIN #Cards c ON c.CardId = b.cid
WHERE b.ord <= @BoardShown;

SET @PotDisp = @Pot + ISNULL((SELECT SUM(BetThisRound) FROM ##TexasHoldEm_Players WHERE InHand = 1), 0);

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
       [Cards] = CASE WHEN p.SeatNum = @MySeat THEN ISNULL(@MyCards, N'')
                      WHEN p.InHand = 1 AND p.Folded = 0 AND @ShowdownShown = 1
                           AND @GState IN ('BetweenHands', 'GameOver')
                           THEN (SELECT CONCAT(c1.Display, N' ', c2.Display)
                                 FROM #Cards c1 CROSS JOIN #Cards c2
                                 WHERE c1.CardId = p.Card1 AND c2.CardId = p.Card2)
                      WHEN p.InHand = 1 AND p.Folded = 0 AND p.Card1 IS NOT NULL THEN N'[hidden]'
                      ELSE N'' END,
       [Status] = CASE WHEN p.Folded = 1 THEN N'Folded'
                       WHEN p.AllIn = 1 THEN N'ALL IN'
                       WHEN @GState = 'InHand' AND p.SeatNum = @TurnSeat THEN N'<<< deciding'
                       WHEN @GState = 'InHand' AND p.InHand = 0 THEN N'Sitting out this hand'
                       ELSE N'' END
FROM ##TexasHoldEm_Players p
ORDER BY p.SeatNum;

/* Result 3: the recent action. */
SELECT [What Happened] = x.Message
FROM (SELECT TOP (25) LogId, Message FROM ##TexasHoldEm_Log ORDER BY LogId DESC) x
ORDER BY x.LogId;

/* Result 4: what to do now. */
SET @NameArg = CASE WHEN @PlayerName IS NOT NULL
                    THEN CONCAT(N', @PlayerName = ''', REPLACE(@PlayerName, N'''', N''''''), N'''')
                    ELSE N'' END;
DELETE @Prompt;

IF @SeatStolen = 1
    INSERT @Prompt (Line) VALUES
        (N'Another session reconnected using your player name and took over your seat.'),
        (N'If that wasn''t you, pick a sneakier name next game.');
ELSE IF @GaveUp = 1
    INSERT @Prompt (Line) VALUES
        (CONCAT(N'Waited ', @MaxWaitMinutes, N' minutes with nothing to do, so this query is giving up. Run EXEC sp_TexasHoldEm to resume.'));
ELSE IF @LeftTable = 1
    INSERT @Prompt (Line) VALUES
        (N'You''ve left the game. Thanks for playing! Run EXEC sp_TexasHoldEm any time to get back in.');
ELSE IF @GState = 'GameOver'
    INSERT @Prompt (Line) VALUES
        (N'GAME OVER. Run EXEC sp_TexasHoldEm to start a new game.');
ELSE IF @GState = 'InHand' AND @SeatExists = 1 AND @TurnSeat = @MySeat
     AND @MyNeedsToAct = 1 AND @MyFolded = 0
BEGIN
    SET @Owed = @BetToCall - @MyBet;
    SET @Unit = CASE WHEN @Round <= 1 THEN @SmallBet ELSE @BigBet END;
    SET @NewBet = CASE WHEN @BetToCall = 0 THEN @Unit ELSE @BetToCall + @Unit END;
    SET @SecondsLeft = @TurnSeconds - DATEDIFF(second, @TurnStartedAt, SYSDATETIME());
    IF @SecondsLeft < 0 SET @SecondsLeft = 0;

    INSERT @Prompt (Line) VALUES
        (CONCAT(N'>>> YOUR TURN, ', @PlayerName, N'! You have ', @MyCards, N'. Pot: ', @PotDisp, N'. ',
                CASE WHEN @Owed > 0 THEN CONCAT(N'It costs ', @Owed, N' to call. ') ELSE N'Nothing to call. ' END,
                N'About ', @SecondsLeft, N' seconds on the shot clock:'));

    IF @Owed <= 0
        INSERT @Prompt (Line) VALUES
            (CONCAT(N'EXEC sp_TexasHoldEm @Action = ''Check''', @NameArg, N';'));
    ELSE
        INSERT @Prompt (Line) VALUES
            (CONCAT(N'EXEC sp_TexasHoldEm @Action = ''Call''', @NameArg, N';',
                    CASE WHEN @MyChips < @Owed THEN CONCAT(N'   -- ALL IN for your last ', @MyChips)
                         ELSE CONCAT(N'   -- costs ', @Owed) END));

    IF @RaiseCount < @MaxRaises AND @MyChips >= (@NewBet - @MyBet)
        INSERT @Prompt (Line) VALUES
            (CONCAT(N'EXEC sp_TexasHoldEm @Action = ''Raise''', @NameArg, N';',
                    CASE WHEN @BetToCall = 0 THEN N'   -- bet ' ELSE N'   -- raise to ' END, @NewBet));

    INSERT @Prompt (Line) VALUES
        (CONCAT(N'EXEC sp_TexasHoldEm @Action = ''Fold''', @NameArg, N';'));
END
ELSE IF @IsObserver = 1
    INSERT @Prompt (Line) VALUES
        (N'You''re watching from the rail. Run EXEC sp_TexasHoldEm @Action = ''Watch'' to keep watching,'),
        (N'or EXEC sp_TexasHoldEm to grab a seat when one opens up.');
ELSE IF @MySeat IS NOT NULL AND @SeatExists = 0
    INSERT @Prompt (Line) VALUES
        (N'You''re out - busted or removed. Run EXEC sp_TexasHoldEm to buy back in if a seat is open,'),
        (N'or EXEC sp_TexasHoldEm @Action = ''Watch'' to spectate with dignity.');
ELSE IF @GState = 'WaitingForPlayers'
    INSERT @Prompt (Line) VALUES
        (CONCAT(N'Waiting for players until ', CONVERT(nvarchar(8), @JoinEnds, 108),
                N' (UTC-ish server time). Run EXEC sp_TexasHoldEm in other sessions to join, then run it again here.'));
ELSE IF @SeatExists = 1
    INSERT @Prompt (Line) VALUES
        (CONCAT(N'Hand #', @GHand, N' is done. Run EXEC sp_TexasHoldEm', REPLACE(@NameArg, N', ', N' '), N' to play the next hand.'));
ELSE
    INSERT @Prompt (Line) VALUES
        (N'Run EXEC sp_TexasHoldEm to join the game.');

SELECT [What Now] = Line FROM @Prompt ORDER BY LineId;

END TRY
BEGIN CATCH
    IF @@TRANCOUNT > 0 ROLLBACK;
    THROW;
END CATCH
END
GO

/* Quick demo:

   Window 1:  EXEC sp_TexasHoldEm @PlayerName = 'Brent';
   Window 2:  EXEC sp_TexasHoldEm @PlayerName = 'Erika';   (within 60 seconds)
   Window 3:  EXEC sp_TexasHoldEm @Action = 'Status';      (instant peek, never blocks)

   Then just do what the [What Now] result set tells you.

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
