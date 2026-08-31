// Pure-converter tests for the Safari extension's cyberoro adapter (ADR 0016).
//
// `giboToSgf` is the one piece of that adapter with no page in it: text in,
// SGF out. It is reached through page-hook.js's Node hatch — the hook detects
// the absent `window`, installs nothing and exports the converters instead.
//
//   cd "ios/KataGo iOS" && node --test SafariExtTests
//
// These fixtures are SYNTHETIC and deliberately ASCII-only. The live records
// are Korean, and a test that pins a real one would pin a page's content as
// much as our parser; every rule below is instead traceable to a line of the
// site's own reader (main_new.js DecodeSGFFile) recorded in the page-hook
// comments.

"use strict";

const test = require("node:test");
const assert = require("node:assert/strict");

const { giboToSgf } = require("../KataGoAnytimeSafariExt/Resources/page-hook.js");

/// The dialect's actual opening: "(" then CRLF then a bare property block with
/// no root ";". A literal "(TE[" never appears, which is why the adapter tests
/// the shape with a regex rather than a prefix.
const HEADER = "(\r\nTE[Test Cup]\r\nRD[2026-01-02]\r\nPC[Seoul]\r\nTM[2 hours]\r\n"
    + "LT[60]\r\nLC[5]\r\nKO[6.5]\r\nRE[B+R]\r\nPB[Black Player]\r\nBR[9d]\r\n"
    + "PW[White Player]\r\nWR[9d]\r\nHD[0]\r\n";

test("the header is rewritten into real SGF and the moves survive", () => {
    const out = giboToSgf(HEADER + ";B[pd];W[dp];B[qp])");
    assert.ok(out, "a gibo record must parse");
    assert.match(out.sgf, /^\(;GM\[1\]FF\[4\]CA\[UTF-8\]SZ\[19\]/);
    // TE is the event, RD the date, KO the komi.
    assert.match(out.sgf, /EV\[Test Cup\]/);
    assert.match(out.sgf, /DT\[2026-01-02\]/);
    assert.match(out.sgf, /KM\[6\.5\]/);
    assert.match(out.sgf, /PB\[Black Player\]BR\[9d\]PW\[White Player\]WR\[9d\]/);
    assert.match(out.sgf, /RE\[B\+R\]/);
    // TM holds prose where SGF's TM is a Real, and LT/LC are not SGF at all.
    assert.ok(!/TM\[/.test(out.sgf), "TM must not be emitted");
    assert.ok(!/LT\[|LC\[/.test(out.sgf), "LT/LC must not be emitted");
    assert.ok(out.sgf.endsWith(";B[pd];W[dp];B[qp])"));
    assert.equal(out.moves.length, 3);
    // Wire coordinates: 0-based, x from the left and y from the TOP.
    assert.deepEqual(out.moves[0], { color: "b", pass: false, x: 15, y: 3 });
});

test("text that is not a gibo record is refused", () => {
    assert.equal(giboToSgf(""), null);
    assert.equal(giboToSgf("`a`b`c"), null, "openReference's coordinate dump");
    assert.equal(giboToSgf("not a record"), null);
});

test("LN sets the board size and bounds the move validator", () => {
    const out = giboToSgf("(\r\nTE[Small]\r\nLN[13]\r\nHD[0]\r\n;B[dd];W[jj])");
    assert.equal(out.boardSize, 13);
    assert.match(out.sgf, /SZ\[13\]/);
    assert.equal(out.moves.length, 2);
    // A point outside a 13x13 board is malformed for THIS record and dropped.
    const clipped = giboToSgf("(\r\nLN[13]\r\n;B[dd];W[ss];B[jj])");
    assert.equal(clipped.moves.length, 2);
    assert.ok(!/W\[ss\]/.test(clipped.sgf));
});

test("an RN reference block is removed whole, including its moves", () => {
    const out = giboToSgf(HEADER
        + ";B[pd];W[dp]RN[a reference]PT[3];B[dd];W[pp]C[commentary])"
        + ";B[qp];W[dq])");
    // The reference's own moves must not reach the main line.
    assert.equal(out.moves.length, 4);
    assert.ok(!/RN\[|PT\[/.test(out.sgf), "no dialect-only tag may survive");
    assert.ok(!/commentary/.test(out.sgf), "the reference's comment goes with it");
    assert.ok(out.sgf.endsWith(";B[pd];W[dp];B[qp];W[dq])"));
});

test("a nested reference block is bracketed by its own paren count", () => {
    const out = giboToSgf(HEADER + ";B[pd]RN[outer];B[dd](;W[pp]);B[qq])" + ";W[dp])");
    assert.equal(out.moves.length, 2);
    assert.ok(out.sgf.endsWith(";B[pd];W[dp])"));
});

test("HD becomes HA plus the site's own handicap stones", () => {
    const out = giboToSgf("(\r\nTE[Handicap]\r\nHD[2]\r\n;W[dd];B[pp])");
    assert.match(out.sgf, /HA\[2\]AB\[pd\]\[dp\]/);
    assert.equal(out.handicap, 2);
    const four = giboToSgf("(\r\nHD[4]\r\n;W[dd])");
    assert.match(four.sgf, /HA\[4\]AB\[pd\]\[dp\]\[pp\]\[dd\]/);
    // The site's 13x13 branch reads an undeclared global and throws before a
    // stone is placed, so a smaller board gets no handicap stones from us
    // either: the SGF has to show the board the reader is looking at.
    const small = giboToSgf("(\r\nLN[13]\r\nHD[2]\r\n;W[dd])");
    assert.ok(!/HA\[|AB\[/.test(small.sgf));
});

test("a backtick pair is a pass", () => {
    const out = giboToSgf(HEADER + ";B[pd];W[``];B[dp])");
    assert.equal(out.moves.length, 3);
    assert.deepEqual(out.moves[1], { color: "w", pass: true, x: null, y: null });
    assert.ok(out.sgf.endsWith(";B[pd];W[];B[dp])"));
});

test("a malformed move is dropped rather than poisoning the line", () => {
    const out = giboToSgf(HEADER + ";B[pd];W[p];B[dp];W[pdq])");
    assert.equal(out.moves.length, 2);
    assert.ok(out.sgf.endsWith(";B[pd];B[dp])"));
});

test("the //AI trailer is cut, with or without a paren inside a comment", () => {
    const plain = giboToSgf(HEADER + ";B[pd];W[dp])\r\n//AI\r\n2\r\n0,50.0%,50.0%,1,pd\r\n");
    assert.ok(plain.sgf.endsWith(";B[pd];W[dp])"));
    assert.ok(!/AI|50\.0/.test(plain.sgf));
    assert.equal(plain.moves.length, 2);

    // A ")" inside a C[...] body must not become the record's closing paren,
    // and the trailer must still go.
    const withParen = giboToSgf(HEADER
        + ";B[pd]C[a joseki (see the corner) here];W[dp])\r\n//AI\r\n1\r\n0,50.0%,50.0%,0,\r\n");
    assert.equal(withParen.moves.length, 2);
    assert.match(withParen.sgf, /C\[a joseki \(see the corner\) here\]/);
    assert.ok(withParen.sgf.endsWith(";W[dp])"));
});

test("a comment lands on the node it followed", () => {
    const out = giboToSgf(HEADER + ";B[pd]C[opening];W[dp];B[qp]C[a fight])");
    assert.match(out.sgf, /;B\[pd\]C\[opening\];W\[dp\];B\[qp\]C\[a fight\]\)$/);
});

test("PC and LC do not masquerade as a C comment", () => {
    // Tokens are maximal runs of uppercase letters, exactly as the site reads
    // them; a prefix match on "C[" would swallow PC[...] and LC[...].
    const out = giboToSgf("(\r\nPC[Seoul]\r\nLC[5]\r\n;B[pd])");
    assert.match(out.sgf, /PC\[Seoul\]/);
    assert.ok(!/C\[5\]/.test(out.sgf));
});

test("KO is only emitted when it is a number", () => {
    assert.match(giboToSgf("(\r\nKO[0]\r\n;B[pd])").sgf, /KM\[0\]/);
    assert.ok(!/KM\[/.test(giboToSgf("(\r\nKO[none]\r\n;B[pd])").sgf));
});
