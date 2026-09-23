# SafariExtTests

Node tests for the pure functions inside the Safari extension's page-world
hook — the parts of a site adapter that can run without a page (ADR 0016).

```sh
cd "ios/KataGo iOS"
node --test SafariExtTests/*.test.js
```

Nothing here is wired into Xcode. `xcodebuild` never runs it and Xcode Cloud
never runs it, so it is an **on-demand** check: run it after touching
`page-hook.js`, alongside the usual builds.

## Why they can run at all

`page-hook.js` opens with a Node hatch. On a page `window` exists, the hook
installs its adapters and the hatch is dead code; under Node there is no
`window`, so the file installs nothing and publishes its converters through
`module.exports` instead. That hatch returns before any `const` in the file
initializes, which is why everything the converters reach is a hoisted
function declaration.

There is no `package.json`, no dependency and no build step: `node:test` and
`node:assert` ship with Node.

## What is covered

- `giboToSgf.test.js` — the cyberoro gibo dialect to SGF rewrite: the header
  tags (TE to EV, RD to DT, KO to KM), `LN` to `SZ`, `HD` to `HA` plus the
  site's own handicap stones, the backtick pass, malformed moves, `RN[...]`
  reference blocks stripped by paren count, and the `//AI` trailer cut.
- `overlayAlignment.test.js` — `alignOverlay`, which seats the cyberoro
  adapter's overlay canvas on the site's board by the two boxes' on-screen
  delta. The mobile skin an iPhone is served leaves every ancestor of the board
  static, so the overlay's `left:0; top:0` alone lands on the document origin.
  The fakes model an absolutely positioned box as its containing block's
  origin plus its own `left`/`top`; there is no DOM here either.
- `panelAnchor.test.js` — `cyberoroPanelAnchor`, which chooses where the
  panel sits on a giboviewer page. On the mobile skin it goes into the page's
  flow right after the transport row. On the desktop skin, or wherever the row
  is out of the flow, it docks into the viewport. The fakes model one
  `querySelector` answer, the parent chain and each element's computed
  `position`.

Fixtures are synthetic and **ASCII-only** on purpose. The live records are
Korean; pinning one would pin a page's content as much as our parser, and every
rule in the converter is already traceable to a line of the site's own reader
(`main_new.js` `DecodeSGFFile`) quoted in the page-hook comments.

## The other half of the contract

`page-hook.js` and `background.js` are **byte-identical** between the two
appexes and must stay so. `KataGo iOSTests/SafariExtensionResourceParityTests`
is what enforces that, and it runs under the ordinary
`xcodebuild test -scheme "KataGo Anytime"` suite.
