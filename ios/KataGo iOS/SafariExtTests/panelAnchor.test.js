// Tests for where the cyberoro adapter asks for the panel (ADR 0016,
// decision 4).
//
// `cyberoroPanelAnchor` chooses between docking the panel into the viewport
// ("floating") and putting it into the page's flow right after the transport
// row ("after"). cyberoro's MOBILE skin, which is what an iPhone is served, is
// an ordinary scrolling page, and a docked panel there covered the lower-right
// of the board and the row's forward buttons as soon as it grew. It is reached
// through page-hook.js's Node hatch.
//
//   cd "ios/KataGo iOS" && node --test SafariExtTests/*.test.js
//
// The fakes model only what the function reads: one querySelector answer,
// the parent chain, and each element's computed `position`. The shapes are
// the ones read off the live pages: the mobile skin's wrapper holds
// `div#board_div` and then `div.con1` as siblings, all static; the desktop skin
// has `#con1` as an id and no `.con1` class at all.

"use strict";

const test = require("node:test");
const assert = require("node:assert/strict");

const { cyberoroPanelAnchor } = require("../KataGoAnytimeSafariExt/Resources/page-hook.js");

const ROW = "#board_div ~ .con1";

function element(position, parentElement) {
    return { position, parentElement };
}

/// `<html>` and `<body>`, both static unless a test says otherwise.
function root() {
    const html = element("static", null);
    return { html, body: element("static", html) };
}

/// A document whose only answer is `row`, for the transport-row selector. The
/// content script re-queries with whatever selector comes back, so the
/// selector this function RETURNS must be the one that found the row.
function doc({ html, body }, row) {
    return {
        documentElement: html,
        body,
        querySelector: (selector) => (selector === ROW ? row : null),
    };
}

const styleOf = (el) => ({ position: el.position });

test("mobile skin: the panel goes into the flow right after the transport row", () => {
    const page = root();
    const row = element("static", element("static", page.body));
    assert.deepEqual(cyberoroPanelAnchor(doc(page, row), styleOf),
                     { anchor: "after", anchorAt: ROW });
});

test("a relatively positioned ancestor still flows", () => {
    const page = root();
    const row = element("static", element("relative", page.body));
    assert.equal(cyberoroPanelAnchor(doc(page, row), styleOf).anchor, "after");
});

test("desktop skin: no .con1 row, so the panel docks", () => {
    assert.deepEqual(cyberoroPanelAnchor(doc(root(), null), styleOf),
                     { anchor: "floating", anchorAt: null });
});

for (const position of ["fixed", "absolute", "sticky"]) {
    test(`a row under a ${position}-positioned ancestor has no flow to push, so the panel docks`, () => {
        const page = root();
        const row = element("static", element(position, page.body));
        assert.deepEqual(cyberoroPanelAnchor(doc(page, row), styleOf),
                         { anchor: "floating", anchorAt: null });
    });
}

// The walk has to reach every ancestor, not just the nearest: the desktop
// skin's fixed layer sits several levels above anything inside it.
test("a fixed ancestor several levels up still makes the panel dock", () => {
    const page = root();
    const layer = element("fixed", page.body);
    const row = element("static", element("static", element("static", layer)));
    assert.equal(cyberoroPanelAnchor(doc(page, row), styleOf).anchor, "floating");
});

test("a fixed <body> counts too", () => {
    const page = root();
    page.body.position = "fixed";
    const row = element("static", element("static", page.body));
    assert.equal(cyberoroPanelAnchor(doc(page, row), styleOf).anchor, "floating");
});

test("a row that is itself out of the flow makes the panel dock", () => {
    const page = root();
    const row = element("absolute", element("static", page.body));
    assert.equal(cyberoroPanelAnchor(doc(page, row), styleOf).anchor, "floating");
});
