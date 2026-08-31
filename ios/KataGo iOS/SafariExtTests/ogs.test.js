// Pure-converter tests for the Safari extension's OGS adapter (ADR 0017).
//
// Two things in that adapter have no page in them: the access rule that keeps
// KataGo off ongoing games, and the walk that turns an OGS move tree into SGF.
// Both are reached through page-hook.js's Node hatch.
//
//   cd "ios/KataGo iOS" && node --test SafariExtTests/*.test.js
//
// The engine fixtures below are the smallest object shape the walk reads. They
// are deliberately hand-built rather than imported from `goban`: this suite has
// no dependencies, and what matters is that our reader keeps agreeing with the
// fields it was written against (goban src/engine/MoveTree.ts:113-127,
// src/engine/GobanEngine.ts:328-347).

"use strict";

const test = require("node:test");
const assert = require("node:assert/strict");

const { gobanToSgf, ogsAccess } = require("../KataGoAnytimeSafariExt/Resources/page-hook.js");

// ---- the access rule -------------------------------------------------------

const OFF = { liveSpectatingEnabled: false };

test("a demo board has no source game and is always allowed", () => {
    assert.deepEqual(ogsAccess(Object.assign({ hasSourceGame: false, phase: "play" }, OFF)),
                     { allowed: true, reason: "demo" });
});

test("a finished game is allowed, signed in or not", () => {
    for (const signedIn of [true, false]) {
        const verdict = ogsAccess(Object.assign(
            { hasSourceGame: true, phase: "finished", signedIn }, OFF));
        assert.deepEqual(verdict, { allowed: true, reason: "finished" });
    }
});

test("an ongoing game is refused for everyone, including a signed-in spectator", () => {
    const cases = [
        { phase: "play", signedIn: true, isPlayer: false },
        { phase: "play", signedIn: false, isPlayer: false },
        { phase: "play", signedIn: true, isPlayer: true },
        { phase: "stone removal", signedIn: true, isPlayer: false },
    ];
    for (const one of cases) {
        const verdict = ogsAccess(Object.assign({ hasSourceGame: true }, one, OFF));
        assert.deepEqual(verdict, { allowed: false, reason: "ongoing" },
                         JSON.stringify(one));
    }
});

test("the live-spectating rule is implemented and reachable only when enabled", () => {
    const ON = { liveSpectatingEnabled: true, hasSourceGame: true, phase: "play" };
    assert.deepEqual(ogsAccess(Object.assign({}, ON, { signedIn: false })),
                     { allowed: false, reason: "anonymous" });
    assert.deepEqual(ogsAccess(Object.assign({}, ON, { signedIn: true, isPlayer: true })),
                     { allowed: false, reason: "participant" });
    assert.deepEqual(
        ogsAccess(Object.assign({}, ON, { signedIn: true, analysisDisabled: true })),
        { allowed: false, reason: "analysisDisabled" });
    assert.deepEqual(ogsAccess(Object.assign({}, ON, { signedIn: true })),
                     { allowed: true, reason: "spectating" });
});

// ---- the move tree to SGF --------------------------------------------------

/// Builds a chain of trunk nodes from `[x, y, player]` triples, so a test reads
/// as the game it means.
function trunk(moves, options) {
    const root = { x: -1, y: -1, player: 0, edited: false, parent: null };
    let node = root;
    for (const [x, y, player, edited] of moves) {
        const next = { x, y, player, edited: !!edited, parent: node };
        node.trunk_next = next;
        node = next;
    }
    return Object.assign({
        width: 19,
        height: 19,
        komi: 6.5,
        rules: "japanese",
        handicap: 0,
        initial_state: { black: "", white: "" },
        players: { black: { username: "Kuro" }, white: { username: "Shiro" } },
        config: {},
        move_tree: root,
    }, options || {});
}

test("a plain game becomes an SGF main line", () => {
    const out = gobanToSgf(trunk([[15, 3, 1], [3, 15, 2], [15, 15, 1]]));
    assert.equal(out.moveCount, 3);
    assert.equal(
        out.sgf,
        "(;GM[1]FF[4]CA[UTF-8]SZ[19]PB[Kuro]PW[Shiro]KM[6.5]RU[japanese]"
        + ";B[pd];W[dp];B[pp])");
});

test("a rectangular board uses SGF's width:height form", () => {
    const out = gobanToSgf(trunk([[0, 0, 1]], { width: 19, height: 13 }));
    assert.match(out.sgf, /SZ\[19:13\]/);
});

test("a pass is the empty value", () => {
    const out = gobanToSgf(trunk([[15, 3, 1], [-1, -1, 2], [3, 15, 1]]));
    assert.equal(out.moveCount, 3);
    assert.ok(out.sgf.endsWith(";B[pd];W[];B[dp])"));
});

test("a variation is never emitted", () => {
    const engine = trunk([[15, 3, 1], [3, 15, 2]]);
    const first = engine.move_tree.trunk_next;
    // A branch hanging off move 1, longer than the trunk: KataGo would follow
    // the deepest child at this fork and analyse a game the reader never saw.
    first.branches = [{ x: 2, y: 2, player: 2, edited: false, parent: first,
                        trunk_next: { x: 4, y: 4, player: 1, edited: false } }];
    const out = gobanToSgf(engine);
    assert.equal(out.moveCount, 2);
    assert.ok(!/cc|ee/.test(out.sgf));
});

test("a demo board has no trunk, so its first branch is its main line", () => {
    const root = { x: -1, y: -1, player: 0, edited: false, parent: null };
    const one = { x: 15, y: 3, player: 1, edited: false, parent: root };
    const two = { x: 3, y: 15, player: 2, edited: false, parent: one };
    root.branches = [one];
    one.branches = [two];
    const out = gobanToSgf(Object.assign(trunk([]), { move_tree: root }));
    assert.equal(out.moveCount, 2);
    assert.ok(out.sgf.endsWith(";B[pd];W[dp])"));
});

test("leading edited nodes fold into the root setup, later ones truncate", () => {
    const out = gobanToSgf(trunk([
        [15, 3, 1, true],    // setup: black
        [3, 15, 2, true],    // setup: white
        [15, 15, 1],         // the first real move
        [3, 3, 2],
        [9, 9, 1, true],     // an edit mid-game: nothing past here is playable
        [0, 0, 2],
    ]));
    assert.match(out.sgf, /AB\[pd\]/);
    assert.match(out.sgf, /AW\[dp\]/);
    assert.equal(out.moveCount, 2);
    assert.ok(out.sgf.endsWith(";B[pp];W[dd])"));
    assert.ok(!/jj|aa/.test(out.sgf));
});

test("initial_state stones join the root setup", () => {
    const out = gobanToSgf(trunk([[3, 3, 2]], {
        initial_state: { black: "pddp", white: "pp" },
        handicap: 2,
        config: { initial_player: "white" },
    }));
    assert.match(out.sgf, /HA\[2\]/);
    assert.match(out.sgf, /PL\[W\]/);
    assert.match(out.sgf, /AB\[pd\]\[dp\]/);
    assert.match(out.sgf, /AW\[pp\]/);
    assert.ok(out.sgf.endsWith(";W[dd])"));
});

test("a missing engine is refused rather than guessed at", () => {
    assert.equal(gobanToSgf(null), null);
    assert.equal(gobanToSgf({}), null);
});
