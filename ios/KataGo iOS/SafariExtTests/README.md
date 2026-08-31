# SafariExtTests

Node tests for the pure converters inside the Safari extension's page-world
hook — the parts of a site adapter that are text in, text out and have no page
in them (ADR 0016).

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

Fixtures are synthetic and **ASCII-only** on purpose. The live records are
Korean; pinning one would pin a page's content as much as our parser, and every
rule in the converter is already traceable to a line of the site's own reader
(`main_new.js` `DecodeSGFFile`) quoted in the page-hook comments.

## The other half of the contract

`page-hook.js` and `background.js` are **byte-identical** between the two
appexes and must stay so. `KataGo iOSTests/SafariExtensionResourceParityTests`
is what enforces that, and it runs under the ordinary
`xcodebuild test -scheme "KataGo Anytime"` suite.
