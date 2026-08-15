(function (root, factory) {
    'use strict';

    const viewerApi = factory();

    if (typeof module === 'object' && module.exports) {
        module.exports = viewerApi;
    }

    if (root && root.document) {
        const start = function () {
            viewerApi.boot(root.document, root);
        };

        if (root.document.readyState === 'loading') {
            root.document.addEventListener('DOMContentLoaded', start, { once: true });
        } else {
            start();
        }
    }
}(typeof window === 'undefined' ? null : window, function () {
    'use strict';

    const pollIntervalMilliseconds = 10000;
    /* A dealer that's been missing for two minutes is not coming back in ten
       seconds. Back off rather than hammering a known-dead endpoint for as
       long as somebody leaves the tab open. */
    const maxPollIntervalMilliseconds = 120000;
    const requestTimeoutMilliseconds = 25000;
    /* How often the pill redraws its own countdown. Only ever repaints text -
       it never fetches, and it never schedules a poll. */
    const countdownIntervalMilliseconds = 1000;
    /* The fixed canvas the table is drawn on, then scaled down to fit. The
       matching height lives in the scaler's CSS aspect-ratio (1340 / 820);
       change one and you must change the other. */
    const canvasWidth = 1340;
    const tableCenterX = 670;
    const tableCenterY = 410;
    const seatRadiusX = 500;
    const seatRadiusY = 271;
    const avatarColors = [
        '#ffd45e',
        '#7bd66a',
        '#f0a3c8',
        '#8fd8ef',
        '#f5b04a',
        '#c8a8f0',
        '#9fe0c0',
        '#f08a6a'
    ];
    const chipColors = ['#e0453c', '#3b7fd4', '#2f2f2f', '#7bd66a', '#ffd45e'];
    const suitSymbols = {
        s: '♠',
        h: '♥',
        d: '♦',
        c: '♣'
    };
    const statusDetails = {
        acting: { label: 'Thinking real hard', color: 'var(--poker-gold)' },
        in: { label: 'Still in it', color: 'var(--poker-mint)' },
        folded: { label: 'Went for snacks', color: 'var(--poker-muted-dark)' },
        allin: { label: 'All in, zero regrets', color: 'var(--poker-coral)' },
        waiting: { label: 'Waiting', color: 'var(--poker-muted)' }
    };

    function finiteNumber(value) {
        const parsed = Number(value);
        return Number.isFinite(parsed) ? parsed : 0;
    }

    function formatMoney(value) {
        return '$' + Math.max(0, finiteNumber(value)).toLocaleString('en-US');
    }

    function requestHeaders(etag) {
        const headers = { Accept: 'application/json' };
        if (typeof etag === 'string' && etag.trim()) {
            headers['If-None-Match'] = etag;
        }
        return headers;
    }

    function parseCard(value) {
        if (value === null || value === undefined) {
            return null;
        }

        const match = String(value).trim().match(/^(10|[2-9tjqka])([shdc♠♥♦♣])$/i);
        if (!match) {
            return null;
        }

        const rank = match[1].toUpperCase();
        const rawSuit = match[2].toLowerCase();
        const suit = suitSymbols[rawSuit] || match[2];
        return {
            rank: rank,
            suit: suit,
            red: suit === '♥' || suit === '♦'
        };
    }

    function parseCards(value, expectedCount) {
        let candidates = [];

        if (Array.isArray(value)) {
            candidates = value;
        } else if (typeof value === 'string') {
            /* Whitespace-delimited on purpose. The procedure sends prose when
               it has no cards to show - '(nothing dealt yet)' for an undealt
               board - and an unanchored scan finds the 't' + 'h' inside
               'nothing' and deals a phantom ten of hearts. parseCard trims,
               so the captured leading space doesn't matter. */
            candidates = value.match(/(?:^|\s)(?:10|[2-9tjqka])[shdc♠♥♦♣](?=\s|$)/gi) || [];
        }

        const cards = candidates.map(parseCard).filter(function (card) {
            return card !== null;
        }).slice(0, expectedCount);

        while (cards.length < expectedCount) {
            cards.push(null);
        }

        return cards;
    }

    function normalizeStage(value) {
        const original = String(value || '').trim();
        const stage = original.toLowerCase();

        if (stage.includes('pre-flop')) {
            return 'Pre-Flop';
        }
        if (stage.includes('flop')) {
            return 'The Flop';
        }
        if (stage.includes('turn')) {
            return 'The Turn';
        }
        if (stage.includes('river')) {
            return 'The River';
        }
        if (stage.includes('showdown')) {
            return 'Showdown';
        }
        if (stage.includes('between')) {
            return 'Between Hands';
        }
        if (stage.includes('game over')) {
            return 'Game Over';
        }
        if (stage.includes('waiting')) {
            return 'Waiting for Players';
        }

        return original || 'Waiting for Players';
    }

    function normalizeStatus(value, stage) {
        const status = String(value || '').toLowerCase();
        const normalizedStage = String(stage || '').toLowerCase();

        if (status.includes('deciding')) {
            return 'acting';
        }
        if (status.includes('folded')) {
            return 'folded';
        }
        if (status.includes('all in') || status.includes('all-in')) {
            return 'allin';
        }
        if (status.includes('sitting out')) {
            return 'waiting';
        }
        if (
            normalizedStage.includes('waiting')
            || normalizedStage.includes('between')
            || normalizedStage.includes('game over')
        ) {
            return 'waiting';
        }

        return 'in';
    }

    function normalizeSnapshot(snapshot) {
        const safeSnapshot = snapshot && typeof snapshot === 'object' ? snapshot : {};
        const hand = safeSnapshot.hand && typeof safeSnapshot.hand === 'object'
            ? safeSnapshot.hand
            : {};
        const stage = normalizeStage(hand.stage);
        const seats = Array.isArray(safeSnapshot.seats) ? safeSnapshot.seats : [];
        const players = seats.slice(0, 8).map(function (seat, index) {
            const safeSeat = seat && typeof seat === 'object' ? seat : {};
            const seatNumber = finiteNumber(safeSeat.seat) || index + 1;
            const position = String(safeSeat.position || '').trim();

            return {
                seat: seatNumber,
                name: String(safeSeat.player || '').trim() || 'Seat ' + seatNumber,
                position: position,
                cards: parseCards(safeSeat.cards, 2),
                stack: finiteNumber(safeSeat.chips),
                bet: finiteNumber(safeSeat.thisRound),
                status: normalizeStatus(safeSeat.status, stage)
            };
        }).sort(function (left, right) {
            return left.seat - right.seat;
        });

        return {
            generatedAt: safeSnapshot.generatedAt,
            stale: safeSnapshot.stale === true,
            handNumber: hand.handNumber === null || hand.handNumber === undefined
                ? null
                : finiteNumber(hand.handNumber),
            street: stage,
            pot: finiteNumber(hand.pot),
            board: parseCards(hand.board, 5),
            players: players
        };
    }

    function element(documentObject, tagName, className, content) {
        const result = documentObject.createElement(tagName);
        if (className) {
            result.className = className;
        }
        if (content !== undefined && content !== null) {
            result.textContent = String(content);
        }
        return result;
    }

    function cardColor(card) {
        return card.red ? 'var(--poker-suit-red)' : 'var(--poker-suit-black)';
    }

    function cardDescription(card) {
        const rankNames = {
            A: 'Ace',
            K: 'King',
            Q: 'Queen',
            J: 'Jack',
            T: 'Ten',
            10: 'Ten'
        };
        const suitNames = {
            '♠': 'spades',
            '♥': 'hearts',
            '♦': 'diamonds',
            '♣': 'clubs'
        };
        return (rankNames[card.rank] || card.rank) + ' of ' + suitNames[card.suit];
    }

    function largeCard(documentObject, card) {
        if (!card) {
            const slot = element(
                documentObject,
                'div',
                'texas-holdem-viewer__card-slot',
                'SOON™'
            );
            slot.setAttribute('role', 'img');
            slot.setAttribute('aria-label', 'Community card not yet dealt');
            return slot;
        }

        const cardElement = element(documentObject, 'div', 'texas-holdem-viewer__card-large');
        cardElement.style.color = cardColor(card);
        cardElement.setAttribute('role', 'img');
        cardElement.setAttribute('aria-label', cardDescription(card));
        cardElement.append(
            element(documentObject, 'div', 'texas-holdem-viewer__card-large-rank', card.rank),
            element(documentObject, 'div', 'texas-holdem-viewer__card-large-suit', card.suit),
            element(
                documentObject,
                'div',
                'texas-holdem-viewer__card-large-rank texas-holdem-viewer__card-large-rank--bottom',
                card.rank
            )
        );
        return cardElement;
    }

    function smallCard(documentObject, card, folded) {
        let cardElement;

        if (!card) {
            cardElement = element(documentObject, 'div', 'texas-holdem-viewer__card-back');
            cardElement.append(element(
                documentObject,
                'span',
                'texas-holdem-viewer__card-back-mark'
            ));
            cardElement.setAttribute('role', 'img');
            cardElement.setAttribute('aria-label', 'Hidden card');
        } else {
            cardElement = element(documentObject, 'div', 'texas-holdem-viewer__card-small');
            cardElement.style.color = cardColor(card);
            cardElement.setAttribute('role', 'img');
            cardElement.setAttribute('aria-label', cardDescription(card));
            cardElement.append(
                element(documentObject, 'div', 'texas-holdem-viewer__card-small-rank', card.rank),
                element(documentObject, 'div', 'texas-holdem-viewer__card-small-suit', card.suit)
            );
        }

        if (folded) {
            cardElement.classList.add('texas-holdem-viewer__card--mucked');
        }
        return cardElement;
    }

    function initials(name) {
        return String(name || '')
            .split(/\s+/)
            .filter(Boolean)
            .map(function (word) {
                return word.charAt(0);
            })
            .join('')
            .replace(/[^a-z0-9]/gi, '')
            .slice(0, 2)
            .toUpperCase() || '?';
    }

    function playerPanel(documentObject, player, index) {
        const folded = player.status === 'folded';
        const details = statusDetails[player.status] || statusDetails.waiting;
        let panelClass = 'texas-holdem-viewer__panel';
        if (player.status === 'acting') {
            panelClass += ' texas-holdem-viewer__panel--acting';
        }
        if (folded) {
            panelClass += ' texas-holdem-viewer__panel--folded';
        }

        const panel = element(documentObject, 'div', panelClass);
        const identity = element(documentObject, 'div', 'texas-holdem-viewer__identity');
        const avatar = element(
            documentObject,
            'div',
            'texas-holdem-viewer__avatar',
            initials(player.name)
        );
        avatar.style.background = folded ? '#7d7161' : avatarColors[index % avatarColors.length];
        avatar.setAttribute('aria-hidden', 'true');

        const identityCopy = element(documentObject, 'div', 'texas-holdem-viewer__identity-copy');
        const playerName = element(
            documentObject,
            'div',
            'texas-holdem-viewer__player-name',
            player.name
        );
        playerName.title = player.name;
        const statusLine = element(
            documentObject,
            'div',
            'texas-holdem-viewer__player-status-line'
        );
        const playerStatus = element(
            documentObject,
            'span',
            'texas-holdem-viewer__player-status',
            details.label
        );
        playerStatus.style.color = details.color;
        statusLine.append(playerStatus);
        if (player.position) {
            statusLine.append(element(
                documentObject,
                'span',
                'texas-holdem-viewer__position',
                '· ' + player.position
            ));
        }
        identityCopy.append(playerName, statusLine);
        identity.append(avatar, identityCopy);

        const holeCards = element(documentObject, 'div', 'texas-holdem-viewer__hole-cards');
        player.cards.forEach(function (card) {
            holeCards.append(smallCard(documentObject, card, folded));
        });

        const moneyRow = element(documentObject, 'div', 'texas-holdem-viewer__money-row');
        const stackCell = element(documentObject, 'div', 'texas-holdem-viewer__money-cell');
        stackCell.append(
            element(documentObject, 'div', 'texas-holdem-viewer__money-label', 'Stack'),
            element(
                documentObject,
                'div',
                'texas-holdem-viewer__money-value',
                formatMoney(player.stack)
            )
        );
        const positionCell = element(
            documentObject,
            'div',
            'texas-holdem-viewer__money-cell texas-holdem-viewer__money-cell--right'
        );
        positionCell.append(
            element(
                documentObject,
                'div',
                'texas-holdem-viewer__money-label',
                player.position ? 'Position' : 'Seat'
            ),
            element(
                documentObject,
                'div',
                'texas-holdem-viewer__money-value texas-holdem-viewer__money-value--position',
                player.position || '#' + player.seat
            )
        );
        moneyRow.append(stackCell, positionCell);
        panel.append(identity, holeCards, moneyRow);

        if (player.bet > 0) {
            const bet = element(documentObject, 'div', 'texas-holdem-viewer__bet');
            const betChips = element(documentObject, 'div', 'texas-holdem-viewer__bet-chips');
            const chipCount = Math.min(5, 1 + Math.floor(Math.log10(Math.max(10, player.bet))));
            for (let chipIndex = 0; chipIndex < chipCount; chipIndex += 1) {
                const chip = element(documentObject, 'span', 'texas-holdem-viewer__bet-chip');
                chip.style.background = chipColors[chipIndex % chipColors.length];
                betChips.append(chip);
            }
            bet.append(
                betChips,
                element(
                    documentObject,
                    'div',
                    'texas-holdem-viewer__bet-value',
                    formatMoney(player.bet)
                )
            );
            bet.setAttribute('aria-label', formatMoney(player.bet) + ' bet this round');
            panel.append(bet);
        }

        return panel;
    }

    function render(viewer, snapshot) {
        const game = normalizeSnapshot(snapshot);
        const documentObject = viewer.ownerDocument;
        viewer.querySelector('[data-role="street"]').textContent = game.street;
        viewer.querySelector('[data-role="pot"]').textContent = formatMoney(game.pot);

        const board = viewer.querySelector('[data-role="board"]');
        board.replaceChildren.apply(board, game.board.map(function (card) {
            return largeCard(documentObject, card);
        }));

        const seats = viewer.querySelector('[data-role="seats"]');
        const playerCount = game.players.length;
        const seatElements = game.players.map(function (player, index) {
            const angle = Math.PI / 2 + index * 2 * Math.PI / playerCount;
            const crowded = playerCount >= 7;
            const radiusX = crowded ? 520 : seatRadiusX;
            const radiusY = crowded ? 285 : seatRadiusY;
            let seatClass = 'texas-holdem-viewer__seat';
            if (playerCount === 7) {
                seatClass += ' texas-holdem-viewer__seat--seven';
            } else if (playerCount >= 8) {
                seatClass += ' texas-holdem-viewer__seat--eight';
            }
            const seat = element(documentObject, 'div', seatClass);
            seat.style.left = (tableCenterX + radiusX * Math.cos(angle)).toFixed(1) + 'px';
            seat.style.top = (tableCenterY + radiusY * Math.sin(angle)).toFixed(1) + 'px';
            seat.append(playerPanel(documentObject, player, index));
            return seat;
        });
        seats.replaceChildren.apply(seats, seatElements);
        return game;
    }

    /* Writes the transform and nothing else. The scaler's height comes from
       its CSS aspect-ratio, so this never affects layout - which is what
       lets the ResizeObserver below watch the very element being scaled
       without its own callback re-triggering it. */
    function fit(viewer) {
        const scaler = viewer.querySelector('[data-role="scaler"]');
        const table = viewer.querySelector('[data-role="table"]');
        const scale = Math.min(1, scaler.clientWidth / canvasWidth);
        table.style.transform = 'scale(' + scale + ')';
        return scale;
    }

    /* Doubling, capped. Zero failures means the happy path, so the very first
       retry after a failure is still the ordinary ten seconds. */
    function backoffDelay(consecutiveFailures) {
        if (!(consecutiveFailures > 0)) {
            return pollIntervalMilliseconds;
        }
        return Math.min(
            pollIntervalMilliseconds * Math.pow(2, consecutiveFailures - 1),
            maxPollIntervalMilliseconds
        );
    }

    /* Exact, because the pill is a promise about when the table refreshes.
       Rounding to whole minutes turned the 80-second backoff step into "1m",
       which is a shorter wait than the one actually scheduled. */
    function describeDelay(milliseconds) {
        /* Ceiling, not rounding: every delay today is a whole number of
           seconds so the two agree, but rounding is the one that could
           quietly break the promise this function is making. */
        const seconds = Math.ceil(
            (milliseconds === undefined ? pollIntervalMilliseconds : milliseconds) / 1000
        );
        if (seconds < 60) {
            return seconds + 's';
        }

        const minutes = Math.floor(seconds / 60);
        const remainder = seconds % 60;
        return remainder === 0 ? minutes + 'm' : minutes + 'm ' + remainder + 's';
    }

    /* The pill counts down, so zero doesn't mean "due in no time at all" - it
       means the wait is over and the request is already out. Saying "refresh
       in 0s" for as long as the fetch takes is how a live page looks stuck. */
    function waitLabel(prefix, activeText, delayMilliseconds) {
        const milliseconds = delayMilliseconds === undefined
            ? pollIntervalMilliseconds
            : delayMilliseconds;
        return milliseconds <= 0 ? activeText : prefix + describeDelay(milliseconds);
    }

    function statusText(game, stale, delayMilliseconds) {
        const hand = game.handNumber === null ? 'Waiting' : 'Hand ' + game.handNumber;
        if (stale) {
            return 'Last good snapshot · ' + hand + ' · ' + game.street + ' · '
                + waitLabel('retrying in ', 'retrying now', delayMilliseconds);
        }
        return hand + ' · ' + game.street + ' · '
            + waitLabel('refresh in ', 'refreshing', delayMilliseconds);
    }

    function updateStatus(viewer, game, state, delayMilliseconds) {
        const status = viewer.querySelector('[data-role="status"]');
        const dot = viewer.querySelector('[data-role="status-dot"]');

        if (state === 'error') {
            status.textContent = 'Dealer went missing · '
                + waitLabel('retrying in ', 'retrying now', delayMilliseconds);
            dot.dataset.state = 'error';
            return;
        }

        const stale = state === 'stale';
        status.textContent = statusText(game, stale, delayMilliseconds);
        dot.dataset.state = stale ? 'stale' : 'live';
    }

    function start(viewer, windowObject) {
        if (viewer.dataset.pokerViewerStarted === 'true') {
            return null;
        }
        viewer.dataset.pokerViewerStarted = 'true';

        const endpoint = viewer.dataset.endpoint;
        let lastGame = null;
        let etag = null;
        let consecutiveFailures = 0;
        let timerId = null;
        let observer = null;
        let stopped = false;
        let paused = false;
        /* Bumped whenever the loop is torn down or suspended. A refresh
           captures it on entry and stands down if it no longer matches, so a
           request that was already in flight when the page was hidden can't
           render or reschedule after a resume has started a newer one. */
        let generation = 0;
        let activeController = null;
        /* The pill promises a time, so it has to tick. Everything needed to
           redraw it between polls: what was last shown, and how much of the
           scheduled wait is left. Counted down rather than read off a clock,
           so a throttled tab drifts instead of lying, and every completed
           poll resets it to the real scheduled delay anyway. */
        let statusPainted = false;
        let statusGame = null;
        let statusState = 'live';
        let remainingMilliseconds = 0;
        let countdownId = null;

        const fitTable = function () {
            fit(viewer);
        };
        if (typeof windowObject.ResizeObserver === 'function') {
            observer = new windowObject.ResizeObserver(fitTable);
            observer.observe(viewer.querySelector('[data-role="scaler"]'));
        } else {
            windowObject.addEventListener('resize', fitTable);
        }
        fitTable();

        if (typeof windowObject.setInterval === 'function') {
            countdownId = windowObject.setInterval(tickCountdown, countdownIntervalMilliseconds);
        }

        /* Every status write goes through here so the ticker below can redraw
           the same line a second later without re-deriving it. */
        function showStatus(game, state, delayMilliseconds) {
            statusPainted = true;
            statusGame = game;
            statusState = state;
            remainingMilliseconds = delayMilliseconds;
            updateStatus(viewer, game, state, delayMilliseconds);
        }

        function tickCountdown() {
            if (stopped || paused || !statusPainted) {
                return;
            }
            remainingMilliseconds = Math.max(0, remainingMilliseconds - countdownIntervalMilliseconds);
            updateStatus(viewer, statusGame, statusState, remainingMilliseconds);
        }

        /* Retires whatever is in flight: cancels the pending poll, aborts an
           open request, and invalidates any refresh already past its await. */
        function retireCurrentWork() {
            generation += 1;
            if (timerId !== null) {
                windowObject.clearTimeout(timerId);
                timerId = null;
            }
            if (activeController !== null) {
                activeController.abort();
                activeController = null;
            }
        }

        /* Idempotent: an explicit caller and the detached-element check below
           can both land on it. Permanent - use pause/resume for a page that
           might come back. */
        function stop() {
            if (stopped) {
                return;
            }
            stopped = true;
            retireCurrentWork();
            if (countdownId !== null) {
                windowObject.clearInterval(countdownId);
                countdownId = null;
            }
            if (observer !== null) {
                observer.disconnect();
            } else {
                windowObject.removeEventListener('resize', fitTable);
            }
            windowObject.removeEventListener('pagehide', handlePageHide);
            windowObject.removeEventListener('pageshow', handlePageShow);
            delete viewer.dataset.pokerViewerStarted;
        }

        /* Navigating away isn't the same as being finished: the back/forward
           cache can restore this exact page, listeners and closures intact.
           Stopping outright would leave the visitor staring at a table frozen
           at whatever it showed when they left, so pause instead. */
        function handlePageHide() {
            if (stopped || paused) {
                return;
            }
            paused = true;
            retireCurrentWork();
        }

        function handlePageShow() {
            if (stopped || !paused) {
                return;
            }
            paused = false;
            retireCurrentWork();
            refresh();
        }

        async function refresh() {
            timerId = null;
            if (stopped || paused) {
                return;
            }
            /* The wait is over and the request is about to go out. */
            remainingMilliseconds = 0;

            /* This refresh's claim on the loop. Checked after every await:
               state alone isn't enough, because a hide/show pair leaves
               paused false again while this request is still outstanding. */
            const myGeneration = generation;
            const isCurrent = function () {
                return !stopped && !paused && myGeneration === generation;
            };

            /* Same question, plus: is the element still on the page? A viewer
               detached while this request was in flight would otherwise get
               one more render and one more scheduled poll before the next
               tick noticed. Tear down here instead of a tick later. */
            const stillLive = function () {
                if (!isCurrent()) {
                    return false;
                }
                if (viewer.isConnected === false) {
                    stop();
                    return false;
                }
                return true;
            };

            /* The host page can swap the viewer out from under us - a
               client-side route change, a block editor re-render - and a
               detached element will never show another snapshot. Polling on
               its behalf just keeps it, and this closure, alive. */
            if (viewer.isConnected === false) {
                stop();
                return;
            }

            const controller = new windowObject.AbortController();
            activeController = controller;
            const timeout = windowObject.setTimeout(function () {
                controller.abort();
            }, requestTimeoutMilliseconds);

            try {
                const response = await windowObject.fetch(endpoint, {
                    cache: 'no-cache',
                    headers: requestHeaders(etag),
                    signal: controller.signal
                });
                /* Everything past the await can land after a stop(), or after
                   a hide/show pair that already started a newer refresh. A
                   retired refresh must not write to the DOM - the element may
                   be detached, and its response is older than the live one. */
                if (!stillLive()) {
                    return;
                }
                if (response.status === 304) {
                    if (!lastGame) {
                        throw new Error('API returned HTTP 304 before the first snapshot.');
                    }
                    consecutiveFailures = 0;
                    showStatus(
                        lastGame,
                        lastGame.stale ? 'stale' : 'live',
                        pollIntervalMilliseconds
                    );
                    return;
                }
                if (!response.ok) {
                    throw new Error('API returned HTTP ' + response.status);
                }

                const responseEtag = response.headers.get('ETag');
                if (responseEtag) {
                    etag = responseEtag;
                }
                const snapshot = await response.json();
                if (!stillLive()) {
                    return;
                }
                consecutiveFailures = 0;
                lastGame = render(viewer, snapshot);
                showStatus(
                    lastGame,
                    snapshot.stale === true ? 'stale' : 'live',
                    pollIntervalMilliseconds
                );
                fitTable();
            } catch (error) {
                /* An abort from retireCurrentWork lands here too, and that's
                   not a dealer that went missing. */
                if (!stillLive()) {
                    return;
                }
                consecutiveFailures += 1;
                showStatus(lastGame, 'error', backoffDelay(consecutiveFailures));
                windowObject.console.error('Texas Hold Em viewer refresh failed.', error);
            } finally {
                windowObject.clearTimeout(timeout);
                if (activeController === controller) {
                    activeController = null;
                }
                if (stillLive()) {
                    const delay = backoffDelay(consecutiveFailures);
                    remainingMilliseconds = delay;
                    timerId = windowObject.setTimeout(refresh, delay);
                }
            }
        }

        windowObject.addEventListener('pagehide', handlePageHide);
        windowObject.addEventListener('pageshow', handlePageShow);
        refresh();
        return stop;
    }

    function boot(documentObject, windowObject) {
        const stops = [];
        documentObject.querySelectorAll('[data-texas-holdem-viewer]').forEach(function (viewer) {
            const stop = start(viewer, windowObject);
            if (stop) {
                stops.push(stop);
            }
        });
        return stops;
    }

    return {
        backoffDelay: backoffDelay,
        boot: boot,
        describeDelay: describeDelay,
        fit: fit,
        formatMoney: formatMoney,
        normalizeSnapshot: normalizeSnapshot,
        normalizeStage: normalizeStage,
        normalizeStatus: normalizeStatus,
        parseCard: parseCard,
        parseCards: parseCards,
        requestHeaders: requestHeaders,
        render: render,
        statusText: statusText
    };
}));
