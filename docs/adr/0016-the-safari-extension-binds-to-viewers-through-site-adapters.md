# 0016 — The Safari extension binds to viewers through site adapters

Date: 2026-08-31
Status: Accepted

The extension has always claimed, in `ios/KataGo iOS/README.md`, to be "not
tied to particular sites". That was never quite true: it was tied to one
*library*. This ADR keeps the promise it was really making — no URL matching,
ever — and names the thing it was actually doing, so a second and third viewer
cost an adapter rather than a rewrite.

## Context

Both appexes match `<all_urls>` with no `host_permissions` and no per-site URL
patterns, and they decide "is this a supported game page" purely by capability:
`page-hook.js` traps `window.WGo.BasicPlayer` construction and separately scans
`[data-wgo]` elements for the instance WGo's declarative path stamps on them.
That is one adapter — "the page embeds WGo.js" — with its site-specific
knowledge (where the SGF lives, how to follow a move, how to draw on the board)
spread flat through the file.

The first request for another site was cyberoro's `giboviewer.asp`, and it
shares nothing with WGo:

- The record is not SGF. It is a private dialect that opens with a bare `(`,
  spells the event `TE`, the date `RD`, the komi `KO` and the handicap `HD`,
  omits `SZ` and `CA`, writes a pass as a pair of backticks, embeds reference
  variations in `RN[...]` blocks terminated by an unmatched `)`, and appends
  the site's own engine output after a `//AI` line. KataGo's parser rejects it
  on the very first token (`cpp/dataio/sgf.cpp:1450-1455` requires a `;` after
  `(`).
- There is no SGF URL to fetch either: the file at `open.cyberoro.com` is
  EUC-KR, is served with no `Access-Control-Allow-Origin`, and `Response.text()`
  always decodes as UTF-8 — so a fetch would buy a cross-origin problem in
  exchange for mojibake. The page already inlines a UTF-8 copy.
- There is no event and no seek API. The current move exists only as the page
  global `GoBoard.NowSeqNo()`, and moving the board means driving the viewer's
  own `Retract()`/`Progress()` in a loop.
- There is nowhere to draw. The board is a bare `<canvas id="board">` the
  extension does not own, and there is nowhere to put a panel either: the whole
  page is `position: fixed`, so the content script's body-end fallback lands
  underneath a full-viewport white surface.

Adding all of that inline would have smeared four site-specific mechanisms
through a file whose only structure was "WGo".

## Decision

1. **`page-hook.js` holds a list of adapters, and WGo is the first one.** An
   adapter is `{ id, detect(), attach(host) }`. `detect()` is a cheap,
   synchronous, side-effect-free test, re-run as the document fills in so a
   DOM-shaped adapter may answer "not yet"; the WGo adapter's `detect()` is
   unconditional, because the whole point of its property trap is to be in place
   before the page assigns `window.WGo`.

2. **A page may hold several viewers, so `attach` takes the host rather than
   returning a viewer.** The WGo adapter registers one viewer per `BasicPlayer`
   it traps, and did so before this seam existed. A viewer is
   `{ describe(), goTo(n, mainline), draw(state), clear(), detach() }`, and the
   hook keeps the registry, the tokened message channel and the command
   dispatch it always had.

3. **A dialect is rewritten in JS, next to the scrape.** `giboToSgf` turns the
   gibo text into SGF inside the adapter, so the wire contract ("the JS side
   sends an SGF string"), the native side, the App Group cache, the `sgfHash`
   and "Open in app" all keep working unchanged. Teaching the C++ parser one
   Korean site's dialect would have been a change to shared engine code for one
   web page.

4. **The panel says where it wants to sit.** `describe()` gained an `anchor`
   hint. Absent — every WGo page — keeps today's insertion after
   `.wgo-player-main`. `"floating"` tells both content scripts to dock a
   collapsible card into the viewport instead, for pages whose layout leaves no
   flow to insert into. `"after"` and `"prepend"` name, through the CSS
   selector `anchorAt`, an element in a page that does flow: the panel goes
   right after it, or into it as its first child. A single-page app can take
   that element away and bring it back, so the content scripts look it up
   again once a second. Once it has been gone for a second the panel docks,
   and it goes back into the flow when the element returns. A docked card
   covers whatever is under it, so an adapter asks for it only where there is
   no flow. Any panel an adapter placed, docked or in the flow, collapses to
   its bar. cyberoro docks on its desktop skin, which is `position: fixed`
   throughout; on the mobile skin an iPhone is served, the panel goes
   `"after"` the transport row. On OGS it goes `"prepend"` into the game's
   main panel, which heads the column of panels: under the board in
   portrait, scrolling with it, and in a sidebar beside it otherwise. OGS
   swaps the two layouts when the viewport changes shape, and hides the main
   panel, and so the panel with it, while Settings or another takeover is
   open. A game in progress gets only the line saying why KataGo is off (ADR
   0017), so there the panel goes last in the main panel instead, below the
   clocks and the play buttons OGS puts in it when the board is beside the
   column. The selector names the game page only; OGS's puzzle and joseki
   pages keep the dock.

5. **A viewer that owns no drawable surface gets an overlay canvas.** The
   cyberoro adapter inserts a transparent, `pointer-events: none` canvas as a
   sibling of the site's board and mirrors its width/height attributes. It is
   seated on the board by the two boxes' on-screen delta, never by its
   containing block: the mobile skin cyberoro serves an iPhone leaves every
   ancestor of the board static, so `left:0; top:0` alone lands on the document
   origin, and its top banner moves the board by changing the body's padding.
   Painting
   into the site's own context would fight its redraws and leave stale marks
   when the reader steps back. The painter itself is shared: one function draws
   ownership squares under candidate circles with AnalysisView's constants, for
   WGo's custom object and for an overlay alike.

6. **No URL matching, in any adapter.** The manifests keep `<all_urls>` and
   `nativeMessaging`, and no adapter may test `location`. What a page *is* is
   decided by what it exposes.

## Consequences

- A new site is an adapter plus its converter, and nothing else moves.
- `page-hook.js` and `background.js` stay byte-identical between the two
  appexes — now enforced by
  `KataGo iOSTests/SafariExtensionResourceParityTests.swift`, because an
  adapter added to one copy and not the other is a site that silently works on
  a Mac and does nothing on a phone. The two `content.js` files remain
  deliberately different and remain hand-synced.
- The hook grew a Node hatch: with no `window` it installs nothing and exports
  its pure converters, so `SafariExtTests` can test a dialect rewrite without a
  browser. Everything those converters reach has to be a hoisted function
  declaration, because the hatch returns before any `const` in the file
  initializes.
- The README's promise is restated honestly: not tied to particular *URLs*, and
  supporting a named list of *viewers*.
- cyberoro ships its own engine output (per-move win rates and suggested moves,
  drawn on the site's own graph). We do not read it and do not compare against
  it. Two win-rate curves side by side — one from an 18-block net on macOS or a
  4.8 MB net on iOS, one from whatever the site ran — invite a comparison this
  product cannot explain, and a comparison feature would need its own
  vocabulary. Site support must not wait on it.
- macOS is where this adapter is developed and QA'd (`refresh_safari_ext.sh` is
  the fast loop). The shared hook means iOS Safari lights up too, but an iPhone
  is served a different, mobile skin, not the desktop page laid out small. The
  first iPhone QA (2026-09-23) found two problems caused by that skin. Every
  mark was drawn rows above its intersection; decision 5's delta seating fixes
  that. The docked panel, once it grew, covered the lower-right of the board and
  the forward buttons; decision 4's `"after"` anchor fixes that. On OGS the
  same card covered the move row in both layouts on an iPhone and an iPad
  mini, and the board as well in portrait; decision 4's `"prepend"` fixes
  that.
