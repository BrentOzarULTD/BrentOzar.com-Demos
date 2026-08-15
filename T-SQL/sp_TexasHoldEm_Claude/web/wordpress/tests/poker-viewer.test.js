'use strict';

const test = require('node:test');
const assert = require('node:assert/strict');
const viewer = require('../texas-holdem-viewer/assets/poker-viewer.js');

test('parseCards understands the stored procedure Unicode format', function () {
    assert.deepEqual(viewer.parseCards('Q♥ 10♠ A♦', 5), [
        { rank: 'Q', suit: '♥', red: true },
        { rank: '10', suit: '♠', red: false },
        { rank: 'A', suit: '♦', red: true },
        null,
        null
    ]);
});

test('parseCards understands design codes and turns hidden text into card backs', function () {
    assert.deepEqual(viewer.parseCards(['Ah', 'Kc'], 2), [
        { rank: 'A', suit: '♥', red: true },
        { rank: 'K', suit: '♣', red: false }
    ]);
    assert.deepEqual(viewer.parseCards('[hidden]', 2), [null, null]);
});

test('parseCards ignores the procedure placeholders that are prose, not cards', function () {
    // '(nothing dealt yet)' hides a 't' followed by an 'h' inside 'nothing',
    // which an unanchored scan reads as the ten of hearts.
    assert.deepEqual(viewer.parseCards('(nothing dealt yet)', 5), [null, null, null, null, null]);
    assert.deepEqual(viewer.parseCards('(none yet)', 2), [null, null]);
    assert.deepEqual(viewer.parseCards('(observer)', 2), [null, null]);
    assert.deepEqual(viewer.parseCards('', 2), [null, null]);
});

test('parseCards still reads a partly dealt board', function () {
    assert.deepEqual(viewer.parseCards('A♠ K♥ Q♦', 5), [
        { rank: 'A', suit: '♠', red: false },
        { rank: 'K', suit: '♥', red: true },
        { rank: 'Q', suit: '♦', red: true },
        null,
        null
    ]);
});

test('requestHeaders adds the last server ETag only after one is available', function () {
    assert.deepEqual(viewer.requestHeaders(null), { Accept: 'application/json' });
    assert.deepEqual(viewer.requestHeaders('"snapshot-47"'), {
        Accept: 'application/json',
        'If-None-Match': '"snapshot-47"'
    });
});

test('normalizeStage translates procedure stages into table labels', function () {
    assert.equal(viewer.normalizeStage('Pre-flop betting'), 'Pre-Flop');
    assert.equal(viewer.normalizeStage('Flop betting'), 'The Flop');
    assert.equal(viewer.normalizeStage('Turn betting'), 'The Turn');
    assert.equal(viewer.normalizeStage('River betting'), 'The River');
    assert.equal(viewer.normalizeStage('Between hands'), 'Between Hands');
    assert.equal(viewer.normalizeStage('Waiting for players to join'), 'Waiting for Players');
});

test('normalizeStatus maps SQL labels to visual roles', function () {
    assert.equal(viewer.normalizeStatus('<<< deciding', 'The Flop'), 'acting');
    assert.equal(viewer.normalizeStatus('Folded', 'The Flop'), 'folded');
    assert.equal(viewer.normalizeStatus('ALL IN', 'The Flop'), 'allin');
    assert.equal(viewer.normalizeStatus('Sitting out this hand', 'The Flop'), 'waiting');
    assert.equal(viewer.normalizeStatus('', 'The Flop'), 'in');
    assert.equal(viewer.normalizeStatus('', 'Between Hands'), 'waiting');
});

test('normalizeSnapshot adapts and sorts the live API response', function () {
    const normalized = viewer.normalizeSnapshot({
        generatedAt: '2026-08-14T08:00:00Z',
        stale: false,
        hand: {
            handNumber: 47,
            stage: 'Turn betting',
            board: 'Q♥ 9♠ 4♦ Q♣',
            pot: 1840
        },
        seats: [
            {
                seat: 3,
                player: 'Deadlock Debbie',
                position: '',
                chips: 5115,
                thisRound: 300,
                cards: '[hidden]',
                status: ''
            },
            {
                seat: 1,
                player: 'Brenda Ozarski',
                position: 'Dealer',
                chips: 6420,
                thisRound: 400,
                cards: 'A♥ K♥',
                status: '<<< deciding'
            }
        ]
    });

    assert.equal(normalized.handNumber, 47);
    assert.equal(normalized.street, 'The Turn');
    assert.equal(normalized.board.length, 5);
    assert.equal(normalized.board[4], null);
    assert.deepEqual(normalized.players.map(function (player) {
        return player.seat;
    }), [1, 3]);
    assert.equal(normalized.players[0].status, 'acting');
    assert.equal(normalized.players[0].bet, 400);
    assert.deepEqual(normalized.players[1].cards, [null, null]);
});

test('normalizeSnapshot safely handles an empty or malformed payload', function () {
    const normalized = viewer.normalizeSnapshot(null);

    assert.equal(normalized.handNumber, null);
    assert.equal(normalized.street, 'Waiting for Players');
    assert.equal(normalized.pot, 0);
    assert.deepEqual(normalized.board, [null, null, null, null, null]);
    assert.deepEqual(normalized.players, []);
});

test('statusText describes live and stale snapshots', function () {
    const game = { handNumber: 12, street: 'The River' };

    assert.equal(viewer.statusText(game, false), 'Hand 12 · The River · refresh in 10s');
    assert.equal(
        viewer.statusText(game, true),
        'Last good snapshot · Hand 12 · The River · retrying in 10s'
    );
});

test('statusText reports the delay the loop is actually waiting', function () {
    const game = { handNumber: 12, street: 'The River' };

    assert.equal(
        viewer.statusText(game, true, 120000),
        'Last good snapshot · Hand 12 · The River · retrying in 2m'
    );
});

test('backoffDelay doubles up to the cap and resets to the poll interval', function () {
    assert.equal(viewer.backoffDelay(0), 10000);
    assert.equal(viewer.backoffDelay(1), 10000);
    assert.equal(viewer.backoffDelay(2), 20000);
    assert.equal(viewer.backoffDelay(3), 40000);
    assert.equal(viewer.backoffDelay(4), 80000);
    assert.equal(viewer.backoffDelay(5), 120000);
    assert.equal(viewer.backoffDelay(50), 120000);
});

test('describeDelay reads as seconds under a minute and minutes above it', function () {
    assert.equal(viewer.describeDelay(10000), '10s');
    assert.equal(viewer.describeDelay(45000), '45s');
    assert.equal(viewer.describeDelay(120000), '2m');
});

test('describeDelay never promises a shorter wait than the one scheduled', function () {
    // 80s is a real backoff step; rounding it to '1m' under-reports the wait.
    assert.equal(viewer.describeDelay(80000), '1m 20s');
    assert.equal(viewer.describeDelay(90000), '1m 30s');
    assert.equal(viewer.describeDelay(60000), '1m');
});

/* ------------------------------------------------------------------ *
 * Poll-loop harness. Enough of a window and a viewer element to drive
 * the real refresh loop through its failure paths without a DOM.
 * ------------------------------------------------------------------ */

function drain() {
    return new Promise(function (resolve) {
        setImmediate(resolve);
    });
}

function fakeWindow(fetchImpl) {
    let nextTimerId = 1;
    const timers = new Map();
    const listeners = new Map();

    return {
        timers: timers,
        listeners: listeners,
        fetch: fetchImpl,
        console: { error: function () {} },
        AbortController: function AbortController() {
            this.signal = {};
            this.abort = function () {};
        },
        setTimeout: function (fn, delay) {
            const id = nextTimerId += 1;
            timers.set(id, { fn: fn, delay: delay });
            return id;
        },
        clearTimeout: function (id) {
            timers.delete(id);
        },
        addEventListener: function (type, fn) {
            if (!listeners.has(type)) {
                listeners.set(type, []);
            }
            listeners.get(type).push(fn);
        },
        removeEventListener: function (type, fn) {
            const registered = listeners.get(type) || [];
            const index = registered.indexOf(fn);
            if (index >= 0) {
                registered.splice(index, 1);
            }
        }
    };
}

function fakeViewer() {
    const nodes = {
        '[data-role="status"]': { textContent: '' },
        '[data-role="status-dot"]': { dataset: {} },
        '[data-role="scaler"]': { clientWidth: 1340, style: {} },
        '[data-role="table"]': { style: {} }
    };

    return {
        dataset: { endpoint: 'https://example.test/api/poker/state' },
        isConnected: true,
        nodes: nodes,
        querySelector: function (selector) {
            return nodes[selector] || null;
        }
    };
}

function fakeDocument(viewer) {
    return { querySelectorAll: function () { return [viewer]; } };
}

async function bootFailingViewer(viewer) {
    const win = fakeWindow(function () {
        return Promise.reject(new Error('the dealer is out'));
    });
    const stops = viewer_boot(viewer, win);
    await drain();
    return { win: win, stop: stops[0] };
}

function viewer_boot(element, win) {
    return viewer.boot(fakeDocument(element), win);
}

// Fires the single pending poll timer and returns the delay it waited.
async function fireNextPoll(win) {
    const entries = Array.from(win.timers.entries());
    assert.equal(entries.length, 1, 'exactly one poll timer should be pending');
    const [id, timer] = entries[0];
    win.timers.delete(id);
    timer.fn();
    await drain();
    return timer.delay;
}

test('the poll loop backs off while the API keeps failing', async function () {
    const element = fakeViewer();
    const booted = await bootFailingViewer(element);

    // First failure already scheduled a retry at the ordinary interval.
    assert.equal(await fireNextPoll(booted.win), 10000);
    assert.equal(await fireNextPoll(booted.win), 20000);
    assert.equal(await fireNextPoll(booted.win), 40000);
    assert.equal(await fireNextPoll(booted.win), 80000);
    assert.equal(await fireNextPoll(booted.win), 120000);
    assert.equal(await fireNextPoll(booted.win), 120000);

    assert.equal(
        element.nodes['[data-role="status"]'].textContent,
        'Dealer went missing · retrying in 2m'
    );
    assert.equal(element.nodes['[data-role="status-dot"]'].dataset.state, 'error');
});

test('stopping the viewer cancels the pending poll and stays stopped', async function () {
    const element = fakeViewer();
    const booted = await bootFailingViewer(element);

    assert.equal(booted.win.timers.size, 1);
    booted.stop();

    assert.equal(booted.win.timers.size, 0, 'the pending poll should be cleared');
    assert.equal(element.dataset.pokerViewerStarted, undefined);
    assert.deepEqual(booted.win.listeners.get('pagehide'), []);

    booted.stop();
    assert.equal(booted.win.timers.size, 0, 'stopping twice should be harmless');
});

test('a viewer detached from the document stops polling on its own', async function () {
    const element = fakeViewer();
    const booted = await bootFailingViewer(element);

    assert.equal(booted.win.timers.size, 1);
    element.isConnected = false;
    await fireNextPoll(booted.win);

    assert.equal(booted.win.timers.size, 0, 'a detached viewer should not reschedule');
});

function fire(win, type) {
    (win.listeners.get(type) || []).slice().forEach(function (fn) {
        fn();
    });
}

test('pagehide pauses the loop instead of killing it', async function () {
    const element = fakeViewer();
    const booted = await bootFailingViewer(element);

    assert.equal(booted.win.timers.size, 1);
    fire(booted.win, 'pagehide');

    assert.equal(booted.win.timers.size, 0, 'the pending poll should be cleared');
    // Still alive: the page may come back from the back/forward cache.
    assert.equal(element.dataset.pokerViewerStarted, 'true');
});

test('pageshow resumes a viewer restored from the back/forward cache', async function () {
    const element = fakeViewer();
    const booted = await bootFailingViewer(element);

    fire(booted.win, 'pagehide');
    assert.equal(booted.win.timers.size, 0);

    fire(booted.win, 'pageshow');
    await drain();

    assert.equal(booted.win.timers.size, 1, 'the loop should be polling again');
});

test('pageshow on an ordinary load does not start a second loop', async function () {
    const element = fakeViewer();
    const booted = await bootFailingViewer(element);

    assert.equal(booted.win.timers.size, 1);
    fire(booted.win, 'pageshow');
    await drain();

    assert.equal(booted.win.timers.size, 1, 'still exactly one pending poll');
});

test('a hide/show pair before the first fetch resolves leaves one poll loop', async function () {
    // pagehide only sets a flag; the request already awaiting fetch() keeps
    // going. pageshow clears the flag and starts another. If the old one is
    // still judged by state alone it looks current when it lands, renders,
    // and schedules a second timer - two loops, and an older response able to
    // overwrite a newer one.
    const element = fakeViewer();
    const pending = [];
    const win = fakeWindow(function () {
        return new Promise(function (_resolve, reject) {
            pending.push(reject);
        });
    });

    viewer_boot(element, win);
    await drain();
    assert.equal(pending.length, 1, 'the first request is in flight');

    fire(win, 'pagehide');
    fire(win, 'pageshow');
    await drain();
    assert.equal(pending.length, 2, 'resuming started a fresh request');

    // Land the resumed request first, then the retired one.
    pending[1](new Error('newer request failed'));
    await drain();
    pending[0](new Error('older request failed'));
    await drain();

    assert.equal(win.timers.size, 1, 'exactly one poll loop should survive');
    // Two loops would have counted two failures and backed off to 20s.
    assert.equal(
        element.nodes['[data-role="status"]'].textContent,
        'Dealer went missing · retrying in 10s'
    );
});

test('a stopped viewer ignores pagehide and pageshow', async function () {
    const element = fakeViewer();
    const booted = await bootFailingViewer(element);

    booted.stop();
    fire(booted.win, 'pageshow');
    await drain();

    assert.equal(booted.win.timers.size, 0, 'stop() is permanent');
});

test('a refresh that lands after stop() does not touch the DOM', async function () {
    const element = fakeViewer();
    let release = null;
    const win = fakeWindow(function () {
        return new Promise(function (resolve) {
            release = function () {
                resolve({
                    ok: true,
                    status: 304,
                    headers: { get: function () { return '"x"'; } },
                    json: function () { return Promise.resolve({}); }
                });
            };
        });
    });

    const stops = viewer_boot(element, win);
    await drain();
    element.nodes['[data-role="status"]'].textContent = 'UNTOUCHED';

    stops[0]();          // stop while the fetch is still in flight
    release();           // ...then let it resolve
    await drain();

    assert.equal(element.nodes['[data-role="status"]'].textContent, 'UNTOUCHED');
    assert.equal(win.timers.size, 0);
});

test('boot refuses to start the same viewer twice', function () {
    const element = fakeViewer();
    const win = fakeWindow(function () {
        return Promise.reject(new Error('the dealer is out'));
    });

    assert.equal(viewer_boot(element, win).length, 1);
    assert.equal(viewer_boot(element, win).length, 0);
});
