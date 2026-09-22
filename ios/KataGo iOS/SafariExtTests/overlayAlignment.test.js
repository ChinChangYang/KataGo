// Tests for how the cyberoro adapter seats its overlay canvas on the site's
// board (ADR 0016, decision 5).
//
// `alignOverlay` moves an absolutely positioned overlay by the distance
// between its on-screen box and the board's. It exists because cyberoro's
// MOBILE skin — what an iPhone is served — leaves every ancestor of the board
// `position: static`, so the overlay's `left:0; top:0` resolved against the
// document origin and every mark landed rows above its intersection. It is
// reached through page-hook.js's Node hatch.
//
//   cd "ios/KataGo iOS" && node --test SafariExtTests/*.test.js
//
// The fakes model the one thing the function reads: an absolutely positioned
// box sits at its containing block's origin plus its own `left`/`top`. The
// numbers are the ones measured on an iPhone 17 simulator: the board at
// (11, 52) in the viewport and the document scrolled 387 px, the height of the
// banner's body padding at the time.

"use strict";

const test = require("node:test");
const assert = require("node:assert/strict");

const { alignOverlay } = require("../KataGoAnytimeSafariExt/Resources/page-hook.js");

function board(left, top) {
    return { getBoundingClientRect: () => ({ left, top, width: 380, height: 380 }) };
}

/// An absolutely positioned overlay whose containing block's padding box
/// starts at `origin` on screen. `origin` is live so a test can move the page.
function overlay(origin) {
    const style = { left: "0", top: "0" };
    return {
        style,
        getBoundingClientRect: () => ({
            left: origin.x + (parseFloat(style.left) || 0),
            top: origin.y + (parseFloat(style.top) || 0),
            width: 380,
            height: 380,
        }),
    };
}

test("mobile skin: an overlay seated at the document origin moves onto the board", () => {
    const layer = overlay({ x: 0, y: -387 });
    alignOverlay(board(11, 52), layer);
    assert.equal(layer.style.left, "11px");
    assert.equal(layer.style.top, "439px");
    const box = layer.getBoundingClientRect();
    assert.equal(box.left, 11);
    assert.equal(box.top, 52);
});

test("a second call on an aligned overlay changes nothing", () => {
    const layer = overlay({ x: 0, y: -387 });
    const target = board(11, 52);
    alignOverlay(target, layer);
    const once = Object.assign({}, layer.style);
    alignOverlay(target, layer);
    assert.deepEqual(layer.style, once);
});

test("a delta under half a pixel is left alone", () => {
    const layer = overlay({ x: 11.3, y: 51.8 });
    alignOverlay(board(11, 52), layer);
    assert.deepEqual(layer.style, { left: "0", top: "0" });
});

test("the overlay follows a board the banner moved without resizing it", () => {
    // Banner open: body padding 387, so the document origin sits 387 px above
    // the viewport and the board 439 px below it.
    const origin = { x: 0, y: -387 };
    const layer = overlay(origin);
    alignOverlay(board(11, 52), layer);
    // Banner collapsed to its 30 px tab. The board moves up by 357 px in the
    // document, the page stops scrolling, and the overlay (anchored to the
    // document) stays where it was until it is re-seated.
    origin.y = 0;
    alignOverlay(board(11, 82), layer);
    assert.equal(layer.style.left, "11px");
    assert.equal(layer.style.top, "82px");
    assert.equal(layer.getBoundingClientRect().top, 82);
});

test("desktop skin: an overlay already on the board's corner is untouched", () => {
    // #board_div2 is absolutely positioned there and the canvas is its only
    // content, so the containing block starts exactly at the board.
    const layer = overlay({ x: 240, y: 90 });
    alignOverlay(board(240, 90), layer);
    assert.deepEqual(layer.style, { left: "0", top: "0" });
});
