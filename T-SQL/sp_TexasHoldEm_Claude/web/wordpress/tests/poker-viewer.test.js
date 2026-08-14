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
