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
    const requestTimeoutMilliseconds = 25000;
    const canvasWidth = 1340;
    const canvasHeight = 820;
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

    function fit(viewer) {
        const scaler = viewer.querySelector('[data-role="scaler"]');
        const table = viewer.querySelector('[data-role="table"]');
        const scale = Math.min(1, scaler.clientWidth / canvasWidth);
        table.style.transform = 'scale(' + scale + ')';
        scaler.style.height = Math.round(canvasHeight * scale) + 'px';
        return scale;
    }

    function statusText(game, stale) {
        const hand = game.handNumber === null ? 'Waiting' : 'Hand ' + game.handNumber;
        if (stale) {
            return 'Last good snapshot · ' + hand + ' · ' + game.street + ' · retrying in 10s';
        }
        return hand + ' · ' + game.street + ' · refresh in 10s';
    }

    function updateStatus(viewer, game, state) {
        const status = viewer.querySelector('[data-role="status"]');
        const dot = viewer.querySelector('[data-role="status-dot"]');

        if (state === 'error') {
            status.textContent = 'Dealer went missing · retrying in 10s';
            dot.dataset.state = 'error';
            return;
        }

        const stale = state === 'stale';
        status.textContent = statusText(game, stale);
        dot.dataset.state = stale ? 'stale' : 'live';
    }

    function start(viewer, windowObject) {
        if (viewer.dataset.pokerViewerStarted === 'true') {
            return;
        }
        viewer.dataset.pokerViewerStarted = 'true';

        const endpoint = viewer.dataset.endpoint;
        let lastGame = null;
        let etag = null;

        const fitTable = function () {
            fit(viewer);
        };
        if (typeof windowObject.ResizeObserver === 'function') {
            const observer = new windowObject.ResizeObserver(fitTable);
            observer.observe(viewer.querySelector('[data-role="scaler"]'));
        } else {
            windowObject.addEventListener('resize', fitTable);
        }
        fitTable();

        async function refresh() {
            const controller = new windowObject.AbortController();
            const timeout = windowObject.setTimeout(function () {
                controller.abort();
            }, requestTimeoutMilliseconds);

            try {
                const response = await windowObject.fetch(endpoint, {
                    cache: 'no-cache',
                    headers: requestHeaders(etag),
                    signal: controller.signal
                });
                if (response.status === 304) {
                    if (lastGame) {
                        updateStatus(viewer, lastGame, lastGame.stale ? 'stale' : 'live');
                    } else {
                        throw new Error('API returned HTTP 304 before the first snapshot.');
                    }
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
                lastGame = render(viewer, snapshot);
                updateStatus(viewer, lastGame, snapshot.stale === true ? 'stale' : 'live');
                fitTable();
            } catch (error) {
                updateStatus(viewer, lastGame, 'error');
                windowObject.console.error('Texas Hold Em viewer refresh failed.', error);
            } finally {
                windowObject.clearTimeout(timeout);
                windowObject.setTimeout(refresh, pollIntervalMilliseconds);
            }
        }

        refresh();
    }

    function boot(documentObject, windowObject) {
        documentObject.querySelectorAll('[data-texas-holdem-viewer]').forEach(function (viewer) {
            start(viewer, windowObject);
        });
    }

    return {
        boot: boot,
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
