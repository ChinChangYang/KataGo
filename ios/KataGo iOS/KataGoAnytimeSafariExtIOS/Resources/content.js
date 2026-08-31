// Isolated-world content script (iOS): bridges the page hook, owns the
// analysis panel (shadow DOM) and the session with the native side.
//
// Differs from the macOS content script in three ways, all forced by the
// platform or the product decision:
//
//  1. NO SWEEP. The iOS appex is launched per native message and torn down
//     when idle, so it cannot hold a warm worker sweeping a whole game. Each
//     position is requested on demand with `query` and the reply is complete
//     in itself. The chart therefore fills LAZILY — every position the reader
//     scrubs to gets analyzed anyway, so plotting it is nearly free — plus an
//     optional user-run "Scan game" that walks the remaining moves.
//  2. WINRATE ONLY. The bundled tiny net has no reliable score head and its
//     ownership is fragile in fights, so neither is displayed.
//  3. TOUCH. No hover on a phone: the chart seeks on tap (pointer events) and
//     the panel is laid out to wrap on narrow screens.

"use strict";

(() => {
    if (window.__kgaContent) { return; }
    window.__kgaContent = true;

    let token = null;                 // learned from the hook's first message
    const players = new Map();        // playerId → PanelSession

    // ---- fallback page-hook injection (idempotent with manifest MAIN world)
    try {
        const script = document.createElement("script");
        script.src = browser.runtime.getURL("page-hook.js");
        script.async = false;
        (document.head || document.documentElement).appendChild(script);
        script.addEventListener("load", () => script.remove());
    } catch (e) { /* MAIN-world manifest copy still covers us */ }

    function postToPage(type, payload) {
        window.postMessage({ kga: token, dir: "c2p", type, payload }, "*");
    }

    window.addEventListener("message", (event) => {
        if (event.source !== window || !event.data || event.data.dir !== "p2c") { return; }
        const { type, payload } = event.data;
        if (token === null) { token = event.data.kga; }
        if (event.data.kga !== token) { return; }
        switch (type) {
            case "hello":
                for (const found of (payload && payload.players) || []) { onPlayerFound(found); }
                break;
            case "playerFound":
                onPlayerFound(payload);
                break;
            case "kifuLoaded":
                sessionFor(payload)?.onKifuLoaded(payload);
                break;
            case "playerUpdate":
                sessionFor(payload)?.onPlayerUpdate(payload);
                break;
        }
    });
    // Tell the hook we are listening (it buffers until this arrives).
    window.postMessage({ dir: "c2p", type: "bridge-ready" }, "*");

    function sessionFor(payload) {
        return (payload && players.get(payload.playerId)) || null;
    }

    function onPlayerFound(info) {
        if (!info || typeof info.playerId !== "string" || players.has(info.playerId)) { return; }
        if (players.size >= 4) { return; }   // sanity cap for hostile pages
        players.set(info.playerId, new PanelSession(info));
    }

    // ---- surface-matched theming -----------------------------------------
    //
    // The panel is injected INTO someone else's page, so its palette has to
    // agree with the PAGE, not with the OS. `prefers-color-scheme` reports the
    // OS preference, and a light-only site stays white through it: katagotraining
    // is Bulma (`html{background-color:#fff}`, `body` transparent) declaring no
    // `color-scheme` at all, so Safari paints it white even on a dark-mode
    // phone. Keying off the OS therefore dropped a near-black panel onto a white
    // page. Sample the surface the panel actually sits on instead.

    const LIGHT_BG = { r: 255, g: 255, b: 255 };   // --kga-bg, light palette
    const DARK_BG = { r: 28, g: 28, b: 30 };       // --kga-bg, dark palette

    function parseColor(value) {
        const m = /^rgba?\(([^)]+)\)$/.exec((value || "").trim());
        if (!m) { return null; }
        // Covers both `rgb(1, 2, 3)` and the modern `rgb(1 2 3 / 0.5)` syntax.
        const parts = m[1].split(/[,\s/]+/).filter(Boolean).map(Number);
        if (parts.length < 3 || parts.slice(0, 3).some(Number.isNaN)) { return null; }
        const a = parts.length > 3 && !Number.isNaN(parts[3]) ? parts[3] : 1;
        return { r: parts[0], g: parts[1], b: parts[2], a };
    }

    function compositeOver(front, back) {
        const a = front.a + back.a * (1 - front.a);
        if (a === 0) { return { r: 0, g: 0, b: 0, a: 0 }; }
        const mix = (f, b) => (f * front.a + b * back.a * (1 - front.a)) / a;
        return {
            r: mix(front.r, back.r), g: mix(front.g, back.g), b: mix(front.b, back.b), a,
        };
    }

    // CIE L*, so "which palette is closer" is a perceptual question rather than
    // a linear-luminance one — mid tones land where the eye puts them.
    function lightness(c) {
        const channel = (v) => {
            v /= 255;
            return v <= 0.03928 ? v / 12.92 : Math.pow((v + 0.055) / 1.055, 2.4);
        };
        const y = 0.2126 * channel(c.r) + 0.7152 * channel(c.g) + 0.0722 * channel(c.b);
        return y <= 216 / 24389 ? y * 24389 / 27 : 116 * Math.cbrt(y) - 16;
    }

    // Walk outward from the panel, compositing each ancestor's background behind
    // what we have until it is effectively opaque. Pages usually paint the
    // surface on `html` or `body` rather than near the player, so the walk
    // normally runs to the top: on katagotraining `body` is transparent and
    // `html` is #fff.
    function sampleSurface(start) {
        let acc = { r: 0, g: 0, b: 0, a: 0 };
        for (let el = start; el; el = el.parentElement) {
            const style = getComputedStyle(el);
            const layer = parseColor(style.backgroundColor);
            if (layer && layer.a > 0) {
                acc = compositeOver(acc, layer);
                if (acc.a >= 0.95) { return acc; }
            }
            // A background IMAGE hides whatever is behind it, and its luminance
            // is unknowable from computed style. Stop: what we already have is
            // the best answer, and continuing would composite onto a surface
            // that is not actually visible.
            if (style.backgroundImage && style.backgroundImage !== "none") { break; }
        }
        return acc;
    }

    // Safari paints a dark canvas only for a page that OPTS IN via
    // `color-scheme`. A page declaring nothing is white even in dark mode —
    // precisely the case this whole mechanism exists for.
    function pageOptedIntoDark() {
        let declared = "";
        try {
            declared = getComputedStyle(document.documentElement).colorScheme || "";
        } catch (e) { /* no <html> yet, or a hostile page */ }
        return /dark/.test(declared) &&
            window.matchMedia("(prefers-color-scheme: dark)").matches;
    }

    function themeFor(host) {
        const surface = sampleSurface(host);
        // Nothing opaque anywhere up the chain: fall back to what the page says
        // about itself, and to light when it says nothing.
        if (surface.a < 0.5) { return pageOptedIntoDark() ? "dark" : "light"; }
        // Pick whichever palette's own background is nearer in perceived
        // lightness. Deriving the boundary from the palettes beats a hand-picked
        // threshold: it stays correct if either palette is ever retuned.
        const l = lightness(surface);
        return Math.abs(l - lightness(DARK_BG)) < Math.abs(l - lightness(LIGHT_BG))
            ? "dark" : "light";
    }

    // One watcher per page, fanned out to every panel: up to four sessions can
    // exist, and N observers would cost N times the same events.
    const themeListeners = new Set();

    function notifyThemeChange() {
        for (const listener of themeListeners) {
            try { listener(); } catch (e) { /* one bad panel must not stop the rest */ }
        }
    }

    (function watchPageTheme() {
        // Sites implement a dark-mode toggle by flipping an attribute on <html>
        // or <body>. Nothing else needs watching, so no subtree — this stays
        // cheap even while a Scan game is rewriting the board.
        const observeAttributes = (node) => {
            if (!node) { return; }
            new MutationObserver(notifyThemeChange).observe(node, {
                attributes: true,
                subtree: false,
                attributeFilter: ["class", "style", "data-theme", "data-bs-theme",
                                  "data-color-scheme"],
            });
        };
        const start = () => {
            observeAttributes(document.documentElement);
            observeAttributes(document.body);
        };
        // This script runs at document_start, so <body> may not exist yet.
        if (document.body) { start(); }
        else { document.addEventListener("DOMContentLoaded", start, { once: true }); }

        window.matchMedia("(prefers-color-scheme: dark)")
            .addEventListener("change", notifyThemeChange);
        // `load`: the constructor-trap path can mount a panel before stylesheets
        // have settled. `pageshow`: a bfcache restore can return to a page whose
        // theme changed while we were frozen.
        window.addEventListener("load", notifyThemeChange);
        window.addEventListener("pageshow", notifyThemeChange);
    })();

    async function native(message) {
        // A native message can fail transiently on iOS when the non-persistent
        // background page was torn down between calls; one retry absorbs it.
        try {
            const reply = await browser.runtime.sendMessage({ kgaNative: message });
            // Safari RESOLVES this promise with `undefined` rather than
            // rejecting it when the non-persistent background page is unloaded
            // mid-call (WebKit fires the completion handler with default
            // arguments as it tears down). Converting that to a throw is what
            // lets the retry below cover it; left alone, `undefined` flows on as
            // a successful reply and the session dies on the first property
            // access — the failure mode looks like a permanent engine error.
            if (reply == null) { throw new Error("the extension did not reply"); }
            if (reply.kgaError) { throw new Error(reply.kgaError); }
            return reply;
        } catch (first) {
            await new Promise((resolve) => setTimeout(resolve, 300));
            const reply = await browser.runtime.sendMessage({ kgaNative: message });
            if (reply == null) { throw new Error("the extension did not reply"); }
            if (reply.kgaError) { throw new Error(reply.kgaError); }
            return reply;
        }
    }

    async function sha256Hex(text) {
        const digest = await crypto.subtle.digest("SHA-256", new TextEncoder().encode(text));
        return Array.from(new Uint8Array(digest), (b) => b.toString(16).padStart(2, "0")).join("");
    }

    // GTP vertex ("Q16") → WGo board coords (x: 0-left, y: 0-TOP).
    const COLUMNS = "ABCDEFGHJKLMNOPQRSTUVWXYZ";
    function vertexToBoard(vertex, size) {
        if (!vertex || vertex.toLowerCase() === "pass") { return null; }
        const column = COLUMNS.indexOf(vertex[0].toUpperCase());
        const row = parseInt(vertex.slice(1), 10);
        if (column < 0 || !Number.isFinite(row)) { return null; }
        return { x: column, y: size - row };
    }

    // SGF coordinate alphabet: index 0 is "a".
    const SGF_COORD = "abcdefghijklmnopqrstuvwxyz";

    // WGo board coords → GTP vertex. Inverse of vertexToBoard.
    function boardToVertex(x, y, size) {
        return COLUMNS[x] + String(size - y);
    }

    /// The line the reader is on, as GTP move strings ("b q16", "w pass").
    /// Colors come from the node, never from alternation — handicap and PL[]
    /// break that — and a pass carries no coordinates.
    function lineToGtp(line, size) {
        return (line && line.moves || []).map((m) => m.pass
            ? `${m.color} pass`
            : `${m.color} ${boardToVertex(m.x, m.y, size)}`);
    }

    // Stamp the page title into the SGF's GN (Game Name) property so the app
    // can name the imported game after the game you were looking at, instead
    // of a generic literal. GN is the SGF property for exactly this, so the
    // saved/exported file stays valid and other Go tools show the same name.
    // An SGF that already carries a GN keeps it — the site knows better.
    function withGameName(sgf, title) {
        // Truncate by CODE POINTS: slicing UTF-16 units can split a surrogate
        // pair and leave a lone surrogate that makes the native message
        // undecodable.
        const clean = Array.from(String(title || "")
            .replace(/[\u0000-\u001f\u007f]/g, " ")   // control characters
            .replace(/\s+/g, " ")
            .trim()).slice(0, 120).join("");
        // Always stamp SOMETHING: the drain uses GN's presence to tell a Safari
        // hand-off from an iMessage one, so a titleless page must still be
        // marked. Fall back to the site's hostname.
        const name = clean || (location && location.hostname) || "";
        if (!name) { return sgf; }
        // SGF property values escape "]" and "\\" with a backslash.
        const escaped = name.replace(/([\]\\])/g, "\\$1");
        const existing = sgf.match(/(^|[^A-Z])GN\[([^\]]*)\]/);
        if (existing) {
            // A node may not carry the same property twice, so fill an empty
            // GN[] in place rather than injecting a duplicate; a GN that
            // already has a value wins (the site knows its own game).
            if (existing[2].trim()) { return sgf; }
            return sgf.replace(/(^|[^A-Z])GN\[\]/, `$1GN[${escaped}]`);
        }
        const root = sgf.indexOf(";");
        if (root < 0) { return sgf; }
        return sgf.slice(0, root + 1) + `GN[${escaped}]` + sgf.slice(root + 1);
    }

    // 1:1 port of the app's AnalysisColor.analysisBaseHue: discretized hue
    // 0 (red, rare) … 0.5 (cyan, most visited) from the visits ratio.
    function analysisBaseHue(visits, maxVisits) {
        const ratio = Math.min(1, Math.max(0.01, visits) / Math.max(0.01, maxVisits));
        const fraction = 2 / (Math.pow((1 / ratio) - 1, 0.9) + 1);
        const hue = fraction < 1 ? Math.cbrt(fraction * fraction) / 2
                                 : 1 - (Math.sqrt(2 - fraction) / 2);
        return Math.round(hue * 10) / 10 / 2;
    }

    // App parity: hiddenAnalysisVisitRatio (candidates below this fraction of
    // max visits dim to 0.2 alpha and lose their text).
    const HIDDEN_VISIT_RATIO = 0.03125;

    // Depth tiers, which double as the wire's budget names:
    //   "fast" → a fixed 16 visits    (the survey — uniform depth, comparable)
    //   "deep" → a fixed ~3 s search  (the cursor — predictable wait, any device)
    //
    // Fixed DEPTH for the sweep is load-bearing twice over. It is the only
    // thing bounding a sweep position's search at all — `kata-set-param
    // maxVisits` is inert for kata-analyze, so the appex's read loop breaks on
    // visits, and that break is what holds the process inside its 80 MB jetsam
    // cap across a whole-game scan. It also keeps the curve honest: adjacent
    // points searched to wildly different depths differ by more than many real
    // swings, which reads as a kink in the line that no move actually caused.
    // Fixed TIME for the position you are looking at is what keeps the wait from
    // depending on how fast your phone is: a slower device returns fewer visits
    // in the same three seconds rather than making you wait longer. Measured on
    // an M3 Max the engine runs ~180 ms of fixed overhead then ~108 visits/s, so
    // three seconds buys roughly 300 visits there and 120–200 on a phone.
    const DWELL_MS = 400;   // stillness required before the deep pass starts

    // ---- one panel + native session per detected player ------------------

    class PanelSession {
        constructor(info) {
            this.playerId = info.playerId;
            this.sgfInline = info.sgfInline;
            this.sgfFile = info.sgfFile;
            this.hasJson = info.hasJson;
            this.sgf = null;
            this.sgfHash = null;
            this.boardSize = 19;
            this.moveCount = 0;
            this.currentIndex = 0;
            this.onMainline = true;
            // TWO TIERS, kept apart deliberately.
            //
            // `survey` is the uniform 16-visit sweep: every point was searched
            // to the same depth, and that visit bound is what keeps a full-game
            // scan inside the appex's memory cap.
            //
            // `deep` is the ~3 s pass on whichever position the reader settled
            // on. Its depth varies with the device, the position and thermals,
            // so it is the better number to LOOK at and a useless one to
            // COMPARE. It overrides the survey for display.
            this.survey = new Map();      // moveIndex → 16-visit result
            this.deep = new Map();        // moveIndex → time-budgeted result
            // Positions inside a variation, keyed by the line itself rather than
            // a move number — two different branches share move numbers, and the
            // main line shares them with both. Kept OUT of survey/deep so a
            // branch result can never reach the chart: a branch winrate stamped
            // at index N would be bridged into the main-line curve by
            // contiguousRuns and render as a smooth, entirely wrong game.
            this.branch = new Map();      // "<line>|<tier>" → result
            this.currentLine = null;      // last line payload from the page
            this.currentNodeDepth = 0;    // WGo node depth, for seeking back
            // Positions whose analysis failed retryably. Kept so a scan steps
            // PAST them instead of re-requesting the same index forever — the
            // scan advances on `survey`, which a failed position never enters.
            this.failedIndexes = new Set();
            this.dwellTimer = null;
            this.deepPending = false;     // a deep pass is in flight
            this.pending = null;          // { index, tier } parked during a request
            this.stopInFlight = null;     // outstanding cancel; blocks new analyses
            // Bumped whenever a pass is abandoned, so its eventual reply can be
            // told apart from a genuine failure and discarded quietly.
            this.cancelGeneration = 0;
            // Lifecycle only. Whether analysis is ON and whether a scan is
            // running are ORTHOGONAL to it (and to each other): the Analyze
            // toggle governs per-scrub analysis + board marks, while Scan game
            // fills the chart independently.
            this.state = "idle";          // idle|starting|ready|error
            this.analysisEnabled = false;
            this.scanning = false;
            this.inFlight = false;        // one native analyze at a time
            this.scanIndex = 0;
            this.showCandidates = true;
            // Engine identity, learned from replies. Version stays null until an
            // engine has actually booted — it is never persisted, so the panel
            // cannot claim a version for an engine that never ran.
            this.engineVersion = null;
            this.engineModel = null;
            this.theme = null;            // "light"|"dark", from the page's surface
            // Where the adapter wants the panel to sit (ADR 0016). Read BEFORE
            // buildPanel(), which is the only thing that consumes it.
            this.anchor = info.anchor || null;
            this.buildPanel();
            window.addEventListener("pagehide", () => this.teardown());
        }

        // ---- panel DOM ---------------------------------------------------

        buildPanel() {
            const host = document.createElement("katago-anytime-panel");
            host.style.display = "block";
            if (this.anchor === "floating") {
                // Some viewers leave no flow to insert into: cyberoro's
                // giboviewer is position:fixed from <body> down, so the branch
                // below would drop the panel underneath a full-viewport white
                // surface. Dock into the viewport instead — the site's own
                // right rail, above its transport controls, never over the
                // board. The z-index clears the rail (100), the board (110)
                // and the info strip (120).
                host.style.position = "fixed";
                host.style.right = "13px";
                host.style.bottom = "44px";
                host.style.width = "274px";
                host.style.maxWidth = "calc(100vw - 26px)";
                host.style.zIndex = "130";
                document.body.appendChild(host);
            } else {
                const anchor = document.querySelector(".wgo-player-main") || document.body;
                (anchor.parentNode || document.body).insertBefore(host, anchor.nextSibling);
            }
            this.host = host;

            const root = host.attachShadow({ mode: "closed" });
            root.innerHTML = `
<style>
:host { all: initial; display: block; margin: 12px 0; }
.kga-root {
  --kga-bg: #ffffff; --kga-ink: #1d1d1f; --kga-ink-muted: #6e6e73;
  --kga-grid: #e5e5ea; --kga-accent: #0a84ff; --kga-winrate: #0a84ff;
  --kga-score: #bf5af2; --kga-badge: #ff453a; --kga-cursor: #1d1d1f;
  --kga-hatch: rgba(110,110,115,0.12);
  font: 13px/1.45 -apple-system, system-ui, sans-serif;
  color: var(--kga-ink); background: var(--kga-bg);
  border: 1px solid var(--kga-grid); border-radius: 10px;
  padding: 10px 12px; max-width: 640px;
}
/* Applied by applyTheme() from the surface behind the panel — NOT from
   prefers-color-scheme, which reports the OS and left this panel near-black
   on light-only sites like katagotraining. See themeFor(). */
.kga-root.kga-dark {
  --kga-bg: #1c1c1e; --kga-ink: #f2f2f7; --kga-ink-muted: #98989d;
  --kga-grid: #3a3a3c; --kga-winrate: #409cff; --kga-score: #da8fff;
  --kga-cursor: #f2f2f7; --kga-hatch: rgba(152,152,157,0.14);
}
.kga-bar { display: flex; align-items: center; gap: 8px; flex-wrap: wrap; }
.kga-logo {
  font: inherit; font-weight: 600; color: inherit; background: none;
  border: 0; padding: 0; cursor: pointer; display: inline-flex;
  align-items: center; gap: 3px; min-height: 32px;
}
.kga-logo .kga-chev { font-size: 9px; color: var(--kga-ink-muted); }
.kga-details {
  margin-top: 8px; padding: 8px 10px; border: 1px solid var(--kga-grid);
  border-radius: 8px; color: var(--kga-ink-muted); font-size: 12px;
  display: grid; grid-template-columns: auto 1fr; gap: 2px 10px;
  overflow-wrap: anywhere;
}
.kga-details[hidden] { display: none; }
.kga-details dt { font-weight: 600; }
.kga-details dd { margin: 0; font-variant-numeric: tabular-nums; }
.kga-winrate-readout { font-variant-numeric: tabular-nums; color: var(--kga-ink-muted); }
/* Touch targets: 32px min height, and controls wrap instead of overflowing. */
.kga-bar button {
  font: inherit; min-height: 32px; border-radius: 7px;
}
.kga-bar button {
  color: var(--kga-accent); background: transparent;
  border: 1px solid var(--kga-accent); padding: 4px 12px; cursor: pointer;
}
.kga-bar button.kga-primary { color: #fff; background: var(--kga-accent); }
.kga-controls { display: flex; align-items: center; gap: 8px; margin-left: auto; flex-wrap: wrap; }
.kga-toggle { display: inline-flex; align-items: center; gap: 4px; color: var(--kga-ink-muted); cursor: pointer; }
.kga-toggle input { accent-color: var(--kga-accent); width: 18px; height: 18px; }
.kga-pass { display: inline-flex; align-items: center; gap: 4px; color: var(--kga-ink-muted); font-variant-numeric: tabular-nums; }
.kga-pass-dot { width: 12px; height: 12px; border-radius: 6px; display: inline-block; }
.kga-progress { color: var(--kga-ink-muted); font-variant-numeric: tabular-nums; }
.kga-chart-wrap { position: relative; margin-top: 10px; }
.kga-chart-wrap[hidden] { display: none; }
.kga-chart { display: block; width: 100%; height: 120px; touch-action: none; cursor: crosshair; }
.kga-axis { display: flex; justify-content: space-between; color: var(--kga-ink-muted); font-size: 11px; }
.kga-tip {
  position: absolute; pointer-events: none; background: var(--kga-bg);
  border: 1px solid var(--kga-grid); border-radius: 6px; padding: 4px 8px;
  font-size: 11px; white-space: nowrap; transform: translate(-50%, -100%);
  top: 0; box-shadow: 0 2px 8px rgba(0,0,0,0.12);
}
.kga-msg { margin-top: 8px; color: var(--kga-ink-muted); }
.kga-msg.kga-error { color: var(--kga-badge); }
/* A site-anchored ("floating") panel: docked into the viewport because the page
   left no flow to insert into. Bounded and scrollable so it can never outgrow
   the site's own rail, and collapsible to a single bar. */
.kga-root.kga-floating { max-height: min(46vh, 420px); overflow: auto;
  box-shadow: 0 6px 20px rgba(0,0,0,0.20); }
.kga-root.kga-floating.kga-collapsed { max-height: none; overflow: visible; }
.kga-root.kga-floating.kga-collapsed > *:not(.kga-bar) { display: none; }
.kga-collapse { display: none; }
.kga-root.kga-floating .kga-collapse { display: inline-flex; }
/* Narrow phones: stack the controls under the buttons. */
@media (max-width: 420px) {
  .kga-controls { margin-left: 0; width: 100%; }
  .kga-chart { height: 100px; }
}
</style>
<div class="kga-root">
  <div class="kga-bar">
    <button class="kga-collapse" type="button" aria-expanded="true"
            aria-label="Collapse the KataGo panel">▾</button>
    <button class="kga-logo" type="button" aria-expanded="false"
            aria-label="Engine details">◉ KataGo<span class="kga-chev">▾</span></button>
    <button class="kga-analyze kga-primary">Analyze</button>
    <span class="kga-winrate-readout"></span>
    <span class="kga-progress" hidden></span>
    <div class="kga-controls">
      <label class="kga-toggle"><input type="checkbox" class="kga-cands" checked>Marks</label>
      <span class="kga-pass" hidden></span>
      <button class="kga-scan">Scan game</button>
      <button class="kga-open">Open in app</button>
    </div>
  </div>
  <div class="kga-chart-wrap" hidden>
    <canvas class="kga-chart"></canvas>
    <div class="kga-axis"><span>0</span><span class="kga-axis-max"></span></div>
    <div class="kga-tip" hidden></div>
  </div>
  <dl class="kga-details" hidden>
    <dt>Version</dt><dd class="kga-ver"></dd>
    <dt>Model</dt><dd class="kga-model"></dd>
  </dl>
  <div class="kga-msg" hidden></div>
</div>`;
            this.el = {
                rootEl: root.querySelector(".kga-root"),
                collapse: root.querySelector(".kga-collapse"),
                logo: root.querySelector(".kga-logo"),
                details: root.querySelector(".kga-details"),
                ver: root.querySelector(".kga-ver"),
                model: root.querySelector(".kga-model"),
                analyze: root.querySelector(".kga-analyze"),
                readout: root.querySelector(".kga-winrate-readout"),
                progress: root.querySelector(".kga-progress"),
                candsToggle: root.querySelector(".kga-cands"),
                pass: root.querySelector(".kga-pass"),
                scan: root.querySelector(".kga-scan"),
                open: root.querySelector(".kga-open"),
                chartWrap: root.querySelector(".kga-chart-wrap"),
                canvas: root.querySelector(".kga-chart"),
                axisMax: root.querySelector(".kga-axis-max"),
                tip: root.querySelector(".kga-tip"),
                msg: root.querySelector(".kga-msg"),
            };
            this.chart = new KGAChart(this.el.canvas, {
                showScore: false,           // winrate-only on iOS
                // The chart plots the MAIN LINE, so seeking from it must land
                // there. A plain move-number seek would not: WGo clones the
                // current path, branch keys included, and follows _last_selected
                // at unkeyed forks — so from inside a variation you come back to
                // the variation.
                onSeek: (index) => postToPage("goTo", {
                    playerId: this.playerId, moveIndex: index, mainline: true,
                }),
                onHover: (index) => this.showTip(index),
            });
            new ResizeObserver(() => this.chart.draw()).observe(this.el.canvas);
            this.applyTheme();
            themeListeners.add(() => this.applyTheme());
            if (this.anchor === "floating") {
                this.el.rootEl.classList.add("kga-floating");
                this.el.collapse.addEventListener("click", () => this.toggleCollapsed());
            }

            this.el.logo.addEventListener("click", () => this.toggleDetails());
            this.el.analyze.addEventListener("click", () => this.toggleAnalysis());
            this.el.scan.addEventListener("click", () => {
                if (this.scanning) { this.stopScan(); } else { this.startScan(); }
            });
            this.el.open.addEventListener("click", () => this.openInApp());
            this.el.candsToggle.addEventListener("change", () => {
                this.showCandidates = this.el.candsToggle.checked;
                this.pushOverlays();
            });
        }

        /// A floating panel sits OVER the page, so it has to be dismissable
        /// without losing the session: collapse to the bar, keep whatever is
        /// running running, expand again from the same button.
        toggleCollapsed() {
            const collapsed = this.el.rootEl.classList.toggle("kga-collapsed");
            this.el.collapse.textContent = collapsed ? "▸" : "▾";
            this.el.collapse.setAttribute("aria-expanded", collapsed ? "false" : "true");
        }

        /// Re-point the palette at whatever the panel is currently sitting on.
        /// Cheap and idempotent, so every theme signal can just call it.
        applyTheme() {
            const theme = themeFor(this.host);
            if (theme === this.theme) { return; }
            this.theme = theme;
            this.el.rootEl.classList.toggle("kga-dark", theme === "dark");
            // Match the UA widget scheme too, or the "Marks" checkbox keeps
            // rendering against the OS preference the panel no longer follows.
            this.host.style.colorScheme = theme;
            // KGAChart re-reads the --kga-* vars on every draw, but only when
            // something asks it to draw.
            this.chart.draw();
        }

        /// Session-constant engine identity lives behind a tap on the logo:
        /// it is diagnostic, not something to spend panel height on. Tapping
        /// never starts the engine — whatever the last reply reported is what
        /// is shown.
        toggleDetails() {
            const show = this.el.details.hidden;
            this.el.details.hidden = !show;
            this.el.logo.setAttribute("aria-expanded", show ? "true" : "false");
            this.el.logo.querySelector(".kga-chev").textContent = show ? "▴" : "▾";
            this.renderDetails();
            // The version is captured when the engine boots, but a reply may
            // never carry it: once a game is in the native cache every position
            // is served from disk without touching the engine, so no message
            // follows the boot. Ask directly on open. `ping` is a pure status
            // read — it cannot start an engine.
            if (show && !this.engineVersion) {
                native({ cmd: "ping" })
                    .then((reply) => this.noteEngineInfo(reply))
                    .catch(() => {});
            }
        }

        renderDetails() {
            this.el.ver.textContent = this.engineVersion || "after first analysis";
            this.el.model.textContent = this.engineModel || "—";
        }

        /// Engine identity arrives on the side of ordinary replies.
        noteEngineInfo(reply) {
            if (!reply) { return; }
            if (reply.engineModel) { this.engineModel = reply.engineModel; }
            if (reply.engineVersion) { this.engineVersion = reply.engineVersion; }
            if (!this.el.details.hidden) { this.renderDetails(); }
        }

        message(text, isError) {
            this.el.msg.hidden = !text;
            this.el.msg.textContent = text || "";
            this.el.msg.classList.toggle("kga-error", !!isError);
        }

        showTip(index) {
            const r = index === null ? null
                                     : (this.deep.get(index) || this.survey.get(index));
            if (!r) { this.el.tip.hidden = true; return; }
            this.el.tip.textContent =
                `Move ${index} · Black ${(r.winrateB * 100).toFixed(1)}% · ${r.visits} visits`;
            this.el.tip.hidden = false;
            this.el.tip.style.left = this.chart.xFor(index, this.chart.layout()) + "px";
        }

        // ---- page events -------------------------------------------------

        onKifuLoaded(payload) {
            if (Number.isFinite(payload.size)) { this.boardSize = payload.size; }
            if (Number.isFinite(payload.moveCount)) { this.moveCount = payload.moveCount; }
        }

        onPlayerUpdate(payload) {
            const path = payload.path || { m: 0, onMainline: true };
            const line = payload.line || null;
            // Index by MOVE COUNT, not WGo's node depth: a setup-only node
            // inflates the depth and would shift every cached position by one.
            // Depth is kept only for talking back to WGo.
            this.currentIndex = line ? line.moveCount : path.m;
            this.currentNodeDepth = line ? line.nodeDepth : path.m;
            this.onMainline = line ? line.onMainline : path.onMainline;
            this.currentLine = line;
            this.chart.setCursor(this.currentIndex, this.onMainline);
            this.message("");
            // Whatever was being deepened is no longer what the reader is
            // looking at. Abandon it — a three-second search nobody is waiting
            // on only delays the one they are.
            this.cancelDeepen();
            this.pushOverlays();
            // Lazy fill: the position the reader just moved to is the one we
            // analyze, and plotting it is what grows the chart over time. With
            // analysis off this is skipped entirely — no engine work, no marks.
            if (this.state === "ready" && this.analysisEnabled) {
                this.requestPosition(this.currentIndex, "fast", this.lineOpts());
            }
        }

        /// The explicit line for the position on screen, main line included.
        ///
        /// The moves are always shipped, because addressing a position by move
        /// number is not reliable even on the main line: `loadsgf <file> <n>`
        /// resolves n against KataGo's idea of the main line, which takes the
        /// DEEPEST child at every fork, while the page takes the FIRST. On a
        /// file whose variation outruns the main line those are different games,
        /// and the wrong one would be charted with nothing looking amiss.
        ///
        /// `lineKey` identifies a VARIATION and is null on the main line, whose
        /// results stay in survey/deep under bare move numbers — the chart and
        /// the persisted cache are both keyed that way.
        lineOpts() {
            if (!this.currentLine) { return undefined; }
            const moves = lineToGtp(this.currentLine, this.boardSize);
            return { moves, lineKey: this.onMainline ? null : moves.join(",") };
        }

        /// Abandon any deep pass, pending or in flight.
        ///
        /// Bumping the generation is what lets the eventual reply be recognised
        /// as ours-and-unwanted instead of reported to the reader as a failure —
        /// an abandoned search comes back as a retryable error, which would
        /// otherwise flash "analysis unavailable" on every scrub.
        cancelDeepen() {
            if (this.dwellTimer !== null) {
                clearTimeout(this.dwellTimer);
                this.dwellTimer = null;
            }
            // A deep pass PARKED behind an in-flight request never reached the
            // line that sets `deepPending` — it exists only in `pending`, so
            // clearing the timer is not enough: the drain would still issue a
            // full 3 s search for a position the reader has left. Only the deep
            // entry is dropped; a parked "fast" belongs to the scan or the
            // current scrub and must survive. No `stop` for this case — nothing
            // of ours is searching yet.
            if (this.pending && this.pending.tier === "deep") { this.pending = null; }
            if (!this.deepPending) { return; }
            this.deepPending = false;
            this.cancelGeneration += 1;
            this.sendStop();
        }

        /// Send the native cancel and hold its promise so no analysis starts
        /// while it is outstanding.
        ///
        /// `stop` never takes the native engine lock, so it reaches the running
        /// search rather than queuing behind it. The native side scopes the
        /// cancel to this game — that is what keeps one panel or tab from
        /// abandoning another's search — but WITHIN a game nothing on the wire
        /// says which pass was meant, so the ordering has to be real rather than
        /// assumed: a stop delivered late would otherwise abandon the request
        /// issued after it.
        sendStop() {
            if (!this.sgfHash) { return; }
            const stop = native({ cmd: "stop", gameId: this.sgfHash }).catch(() => {});
            this.stopInFlight = stop;
            stop.finally(() => {
                if (this.stopInFlight === stop) { this.stopInFlight = null; }
            });
        }

        /// Start the dwell clock for `index`; the deep pass fires only if the
        /// reader is still on that position when it expires.
        scheduleDeepen(index, opts) {
            const lineKey = (opts && opts.lineKey) || null;   // null == main line
            // Only the position ON SCREEN owns the single dwell slot. A scan
            // reply for the same move number in a different line shares that
            // index by design, so an index match is not an identity match —
            // clearing the timer here would destroy the live position's dwell
            // and nothing would re-arm it.
            const onScreen = this.lineOpts();
            if (this.currentIndex !== index
                || ((onScreen && onScreen.lineKey) || null) !== lineKey) { return; }
            const store = lineKey ? this.branch : this.deep;
            const key = lineKey ? `${lineKey}|deep` : index;
            if (!this.analysisEnabled || store.has(key)) { return; }
            if (this.dwellTimer !== null) { clearTimeout(this.dwellTimer); }
            this.dwellTimer = setTimeout(() => {
                this.dwellTimer = null;
                // Fire only if the reader is still on the SAME position — same
                // move number AND same line, since a variation and the main line
                // share move numbers.
                const now = this.lineOpts();
                const nowKey = (now && now.lineKey) || null;
                if (this.analysisEnabled && this.currentIndex === index && nowKey === lineKey) {
                    this.requestPosition(index, "deep", opts);
                }
            }, DWELL_MS);
        }

        // ---- SGF acquisition ---------------------------------------------

        async obtainSgf() {
            if (this.sgf) { return this.sgf; }
            if (this.sgfInline) { this.sgf = this.sgfInline; return this.sgf; }
            if (this.sgfFile) {
                const response = await fetch(this.sgfFile, { credentials: "include" });
                if (!response.ok) { throw new Error(`SGF fetch failed (${response.status})`); }
                this.sgf = await response.text();
                return this.sgf;
            }
            throw new Error(this.hasJson ? "unsupported game source (JSON kifu)"
                                         : "no SGF source on this player");
        }

        // ---- session driver ----------------------------------------------

        /// The Analyze button is a toggle, never a dead label: tapping it while
        /// analyzing turns analysis OFF (board marks clear, no further engine
        /// work on scrub) and tapping again turns it back on at the current
        /// position. The chart is deliberately left alone — it is the record of
        /// what was analyzed, and stays tappable for seeking.
        async toggleAnalysis() {
            if (this.state === "starting") { return; }
            if (this.analysisEnabled) { return this.disableAnalysis(); }
            if (!(await this.ensureStarted())) { return; }
            this.analysisEnabled = true;
            this.el.analyze.textContent = "Analyzing";
            this.message("");
            this.requestPosition(this.currentIndex, "fast", this.lineOpts());
        }

        disableAnalysis() {
            this.analysisEnabled = false;
            this.pending = null;
            this.cancelDeepen();
            this.el.analyze.textContent = "Analyze";
            this.message("");
            this.pushOverlays();   // clears the board marks
        }

        /// Register the game natively (idempotent). Both the Analyze toggle and
        /// Scan game need it, and either may be the first to run.
        async ensureStarted() {
            if (this.state === "ready") { return true; }
            // Single-flight: the toggle and Scan can both call this, and a
            // losing concurrent attempt would otherwise stamp state="error"
            // over an already-healthy session.
            if (this.startPromise) { return this.startPromise; }
            this.startPromise = this.performStart().finally(() => {
                this.startPromise = null;
            });
            return this.startPromise;
        }

        async performStart() {
            try {
                this.state = "starting";
                this.el.analyze.textContent = "Starting…";
                this.message("");
                const sgf = await this.obtainSgf();
                this.sgfHash = this.sgfHash || await sha256Hex(sgf);
                const accepted = await native({
                    cmd: "start", sgf, sgfHash: this.sgfHash,
                    currentMoveIndex: this.onMainline ? this.currentIndex : 0,
                });
                this.noteEngineInfo(accepted);
                if (accepted.type === "error") { this.onWireError(accepted); return false; }
                this.moveCount = accepted.moveCount;
                this.boardSize = accepted.boardWidth;
                if (!this.survey.size) { this.chart.setGame(accepted.moveCount); }
                this.el.axisMax.textContent = String(accepted.moveCount);
                this.el.chartWrap.hidden = false;
                this.chart.setCursor(this.currentIndex, this.onMainline);
                this.state = "ready";
                // Restore the toggle's label — startScan() can reach here with
                // analysis off, and "Starting…" must not stick.
                this.el.analyze.textContent = this.analysisEnabled ? "Analyzing" : "Analyze";
                return true;
            } catch (error) {
                this.state = "error";
                this.analysisEnabled = false;
                this.el.analyze.textContent = "Analyze";
                this.message(String(error && error.message || error), true);
                return false;
            }
        }

        /// Analyze one position. Serialized: a scrub during a request is
        /// remembered and issued when the current one lands, so fast scrubbing
        /// collapses to "analyze wherever the reader ended up".
        async requestPosition(index, tier, opts) {
            if (this.state !== "ready") { return; }
            // Engine work happens only for an enabled toggle or a running scan.
            if (!this.analysisEnabled && !this.scanning) { return; }
            const moves = (opts && opts.moves) || null;      // set only in a variation
            const lineKey = (opts && opts.lineKey) || null;
            const afterStaleStop = !!(opts && opts.afterStaleStop);
            // Keyed off lineKey, NOT off "did a line come with it" — the main
            // line sends one too now.
            const store = lineKey ? this.branch
                                  : (tier === "deep" ? this.deep : this.survey);
            const key = lineKey ? `${lineKey}|${tier}` : index;
            // Already known AT THIS TIER: render locally, never spend an appex
            // round-trip. Tier matters — a position covered by the survey is
            // still worth deepening, which the old single-store check made
            // impossible (anything cached could never be re-analyzed deeper).
            if (store.has(key)) {
                this.pushOverlays();
                if (tier === "fast" && index === this.currentIndex) {
                    this.scheduleDeepen(index, opts);
                }
                // Keep a scan moving if this call came from a scrub; when a
                // request is already out its own drain advances the scan.
                if (this.scanning && !this.inFlight) { this.scanStep(); }
                return;
            }
            if (this.inFlight) { this.pending = { index, tier, opts }; return; }

            this.inFlight = true;
            if (tier === "deep") { this.deepPending = true; }
            const generation = this.cancelGeneration;
            let deferred = false;   // a retry owns inFlight; skip the drain
            let staleStopRisk = false;   // a cancel we could not wait out
            try {
                // Never start an analysis while a cancel is still in flight.
                // The native cancel is global — it abandons whatever is
                // searching when it arrives — and messages are dispatched
                // concurrently, so a `stop` delivered late (or re-sent by
                // native()'s own retry after Safari resolves with undefined)
                // would abandon THIS request instead of the one it was meant
                // for. That surfaced as "analysis unavailable" on an ordinary
                // scrub, and during a scan it blacklisted the index for good.
                // Waiting costs one round trip and makes the ordering real.
                if (this.stopInFlight) {
                    // Bounded. The `.catch(() => {})` guarantees the promise
                    // never REJECTS — not that it ever settles. Nothing in the
                    // sendNativeMessage chain has a timeout, so a channel severed
                    // mid-call (frozen into bfcache, or the appex jetsammed with
                    // the connection half-open) leaves it pending forever. This
                    // await sits AFTER `inFlight = true`, so the finally would
                    // never run: every later request parks silently and both
                    // buttons go dead with no user-reachable reset. A stale stop
                    // landing late is recoverable; a wedged panel is not.
                    const outstanding = this.stopInFlight;
                    const TIMED_OUT = "kga-stop-timeout";
                    const winner = await Promise.race([
                        outstanding.then(() => "settled"),
                        new Promise((resolve) => setTimeout(() => resolve(TIMED_OUT), 1000)),
                    ]);
                    if (winner === TIMED_OUT) {
                        // We gave up waiting, so that stop may still land on the
                        // query below. Remember it, and drop the slot — a promise
                        // that never settles would otherwise make EVERY later
                        // request in this session pay the full second.
                        staleStopRisk = true;
                        if (this.stopInFlight === outstanding) { this.stopInFlight = null; }
                    }
                }
                // Re-check abandonment after the wait, exactly as the restart
                // path below does. Without it, a scrub that lands while we are
                // parked here is cancelled by cancelDeepen — which clears
                // `deepPending`, so no later cancel can reach us — and this pass
                // then runs its full 3 s for the position the reader just left,
                // holding the board empty until it finishes.
                if (this.abandoned(generation)) { return; }
                const reply = await native({
                    cmd: "query", gameId: this.sgfHash, moveIndex: index,
                    want: ["candidates"], budget: tier,
                    // The engine replays this rather than seeking by number.
                    ...(moves ? { line: moves, mainline: !lineKey } : {}),
                });
                this.noteEngineInfo(reply);
                if (reply.type === "error") {
                    if (reply.code === "warmingUp") {
                        // Keep ownership of inFlight across the wait: releasing
                        // it here AND in the finally drain would let a second
                        // analysis start concurrently. Re-drive from CURRENT
                        // state on wake, so a toggle during warm-up neither
                        // resurrects a stopped session nor drops a live one.
                        deferred = true;
                        this.message("Starting the analysis engine…");
                        setTimeout(() => {
                            this.inFlight = false;
                            if (this.abandoned(generation)) {
                                this.drainPending();
                                return;
                            }
                            this.resume(index, tier, opts);
                        }, 1000);
                        return;
                    }
                    if (reply.code === "unknownGame") {
                        // Fresh appex process: re-`start` is idempotent and the
                        // native cache still holds prior results.
                        this.state = "idle";
                        deferred = true;
                        this.inFlight = false;
                        // Restart unconditionally — the session is unusable
                        // until it is registered again, and every later request
                        // would park on the not-ready guard.
                        const restarted = await this.ensureStarted();
                        // Re-check abandonment AFTER the await, not only before
                        // it. A restart re-fetches the SGF and can boot the
                        // engine, so seconds pass; a reader who scrubs away in
                        // that window would otherwise get a full 3 s search for
                        // the position they left — and it would carry a FRESH
                        // generation, so it could no longer be abandoned at all.
                        if (!restarted || this.abandoned(generation)) {
                            // Release the flag on the exits that neither retry
                            // nor reach the finally drain: a stale deepPending
                            // makes the next cancel send a `stop` for nothing.
                            this.deepPending = false;
                            // The reader's own scrub was dropped while the
                            // session was restarting (onPlayerUpdate requires
                            // state "ready"), so nothing is parked for it and
                            // the board would simply never update.
                            if (!this.pending && restarted && this.analysisEnabled) {
                                this.pending = { index: this.currentIndex, tier: "fast",
                                                 opts: this.lineOpts() };
                            }
                            this.drainPending();
                            return;
                        }
                        this.resume(index, tier, opts);
                        return;
                    }
                    // A deep pass WE abandoned comes back as a retryable error.
                    // That is the expected outcome of scrubbing away, not a
                    // fault — reporting it would flash "analysis unavailable"
                    // every time the reader moves.
                    if (this.abandoned(generation)) { return; }
                    // The wire distinguishes a failure of THIS request from a
                    // failure of the session, and until now nothing read that
                    // flag: one transient engine hiccup killed a whole scan and
                    // switched analysis off. Honor it — skip the position, keep
                    // the session alive.
                    if (reply.retryable) {
                        // A stop we could not wait out may have killed this
                        // query rather than the pass it was meant for — the
                        // native cancel had already bumped its counter before it
                        // was sent, so `abandoned()` cannot see it. Retry once
                        // instead of reporting a fault that never happened, and
                        // never blacklist on this path: a scan would skip the
                        // position for the rest of the session and leave a
                        // permanent hole in the chart.
                        if (staleStopRisk && !afterStaleStop) {
                            deferred = true;
                            this.inFlight = false;
                            this.message("");
                            if (this.analysisEnabled || this.scanning) {
                                this.requestPosition(index, tier,
                                    Object.assign({}, opts, { afterStaleStop: true }));
                            } else {
                                if (tier === "deep") { this.deepPending = false; }
                                this.drainPending();
                            }
                            return;
                        }
                        // Main line only. `failedIndexes` holds MAIN-LINE move
                        // numbers and is consulted by scanStep, while a
                        // variation's `index` is its own move count —
                        // blacklisting that would skip an unrelated main-line
                        // position for the rest of the session, leaving a
                        // permanent hole in the chart.
                        if (this.scanning && !lineKey) { this.failedIndexes.add(index); }
                        this.message(this.friendlyError(reply), true);
                        return;
                    }
                    this.onWireError(reply);
                    return;
                }
                this.message("");
                // Merge unconditionally — the result is pure data that was
                // already computed and cached natively, and pushOverlays()
                // declines to draw marks while analysis is off. (A deep result
                // that landed just as the reader moved on is still valid data
                // for its own position, so it is kept.)
                this.mergeResults(reply.moves, tier, lineKey);
                // Survey marks for the position under the cursor are on screen
                // now; start the clock that sharpens them if the reader stays.
                if (tier === "fast" && index === this.currentIndex) {
                    this.scheduleDeepen(index, opts);
                }
            } catch (error) {
                // A transport failure on a scan would otherwise retry the same
                // index forever; stop the scan and let the user restart it.
                if (this.scanning) { this.stopScan(); }
                if (this.analysisEnabled) { this.disableAnalysis(); }
                this.message("Analysis stopped — tap Analyze to try again.", true);
            } finally {
                if (!deferred) {
                    this.inFlight = false;
                    if (tier === "deep") { this.deepPending = false; }
                    this.drainPending();
                }
            }
        }

        /// True when this reply belongs to a pass WE cancelled.
        ///
        /// Tier-agnostic on purpose. Teardown cancels whatever is in flight,
        /// which is often a fast pass, and reporting that as a fault leaves a red
        /// error on a page the reader merely navigated away from — and, mid-scan,
        /// blacklists that position for the life of the session.
        abandoned(generation) {
            return generation !== this.cancelGeneration;
        }

        /// ALWAYS drain: a parked request is a position request, not
        /// analysis-toggle state. Gating this on a generation token stalled any
        /// running scan (and left the button reading "Analyzing" with nothing
        /// running) whenever the toggle moved.
        drainPending() {
            const next = this.pending;
            this.pending = null;
            if (next) { this.resume(next.index, next.tier, next.opts); }
            else if (this.scanning) { this.scanStep(); }
        }

        /// Re-enter requestPosition only if the session still wants work.
        /// requestPosition's own guards would reject it anyway; this keeps the
        /// intent explicit at every deferred/scheduled re-entry point.
        resume(index, tier, opts) {
            if (this.analysisEnabled || this.scanning) {
                this.requestPosition(index, tier, opts);
            }
        }

        // ---- optional whole-game scan --------------------------------------

        /// Independent of the Analyze toggle: a scan fills the CHART, so it is
        /// useful whether or not board marks are being shown. It still needs the
        /// game registered, so it starts the session itself if needed.
        async startScan() {
            if (this.scanning) { return; }
            // Claim the flag before awaiting: a second tap during the start
            // must stop the scan, not launch a second driver.
            this.scanning = true;
            this.scanIndex = 0;
            this.el.scan.textContent = "Stop scan";
            this.el.progress.hidden = false;
            if (!(await this.ensureStarted())) { this.stopScan(); return; }
            if (!this.scanning) { return; }   // stopped while starting
            this.scanStep();
        }

        stopScan() {
            this.scanning = false;
            this.el.scan.textContent = "Scan game";
            this.el.progress.hidden = true;
        }

        scanStep() {
            if (!this.scanning) { return; }
            while (this.scanIndex <= this.moveCount
                   && (this.survey.has(this.scanIndex)
                       || this.failedIndexes.has(this.scanIndex))) {
                this.scanIndex += 1;
            }
            this.el.progress.textContent = `${this.survey.size} / ${this.moveCount + 1}`;
            if (this.scanIndex > this.moveCount) { return this.stopScan(); }
            this.requestPosition(this.scanIndex, "fast");
        }

        /// Deepest result available per position: the deep pass overrides the
        /// survey wherever one has been run. The merge is DISPLAY ONLY and
        /// never writes back, so `survey` stays the uniform-depth record that
        /// scan progress counts.
        displayResults() {
            const merged = new Map(this.survey);
            for (const [index, result] of this.deep) { merged.set(index, result); }
            return merged;
        }

        mergeResults(moves, tier, lineKey) {
            if (lineKey) {
                // A branch result stops here. Stamped into the chart at its bare
                // move number it would be bridged into the main-line curve by
                // contiguousRuns and render as a smooth, entirely wrong game.
                for (const move of moves || []) {
                    this.branch.set(`${lineKey}|${tier}`, move);
                }
                this.pushOverlays();
                return;
            }
            const store = tier === "deep" ? this.deep : this.survey;
            for (const move of moves || []) { store.set(move.moveIndex, move); }
            this.chart.merge(Array.from(this.displayResults().values()));
            this.pushOverlays();
        }

        pushOverlays() {
            let current;
            if (this.onMainline) {
                current = this.deep.get(this.currentIndex)
                    || this.survey.get(this.currentIndex);
            } else {
                // Inside a variation the position is identified by its line, not
                // by a move number two different branches would share.
                const opts = this.lineOpts();
                current = opts ? (this.branch.get(`${opts.lineKey}|deep`)
                                  || this.branch.get(`${opts.lineKey}|fast`))
                               : undefined;
            }
            const payload = { playerId: this.playerId, candidates: null, ownership: null };
            let passMark = null;

            // With analysis off the board returns to its un-annotated state
            // (a null candidate list clears the custom object's marks). The
            // chart is intentionally NOT cleared — it is the record of what was
            // analyzed and stays tappable for seeking.
            if (this.analysisEnabled && this.showCandidates && current && current.candidates.length) {
                const maxVisits = Math.max(...current.candidates.map((c) => c.visits));
                const maxLcb = Math.max(...current.candidates.map((c) => c.utilityLcb));
                payload.candidates = [];
                for (const candidate of current.candidates) {
                    const dimmed = candidate.visits < HIDDEN_VISIT_RATIO * maxVisits;
                    // Winrate only, side-to-move perspective (what the app shows).
                    const winrate = current.toMove === "w" ? 1 - candidate.winrateB
                                                           : candidate.winrateB;
                    const mark = {
                        hue: analysisBaseHue(candidate.visits, maxVisits),
                        dimmed,
                        isBest: candidate.utilityLcb === maxLcb,
                        lines: dimmed ? [] : [Math.round(winrate * 100) + "%"],
                    };
                    const point = vertexToBoard(candidate.move, this.boardSize);
                    if (point) {
                        payload.candidates.push({ ...mark, x: point.x, y: point.y });
                    } else if (candidate.move.toLowerCase() === "pass" && !dimmed) {
                        passMark = mark;   // the board has no pass point — panel chip
                    }
                }
            }
            postToPage("drawAnalysis", payload);

            // Position readout, always Black's perspective (matches the chart).
            this.el.readout.textContent = (this.analysisEnabled && current)
                ? `Black ${(current.winrateB * 100).toFixed(1)}% · ${current.visits} visits`
                : "";

            this.el.pass.hidden = !passMark;
            if (passMark) {
                this.el.pass.innerHTML = "";
                const dot = document.createElement("span");
                dot.className = "kga-pass-dot";
                dot.style.background = `hsla(${Math.round(passMark.hue * 360)},100%,50%,0.8)`;
                if (passMark.isBest) { dot.style.boxShadow = "0 0 0 2px #007aff inset"; }
                this.el.pass.append(dot, "pass " + passMark.lines.join(" · "));
            }
        }

        async openInApp() {
            try {
                const sgf = await this.obtainSgf();
                const reply = await native({
                    cmd: "openInApp",
                    sgf: withGameName(this.onMainline ? sgf : this.linearizedSgf(sgf),
                                      document.title),
                });
                // Hand-off failures are their own surface: they must not stop
                // analysis or clear the board the way a wire error does.
                if (reply.type === "error") {
                    this.message(reply.message || "Could not open KataGo Anytime.", true);
                    return;
                }
                // iOS extensions cannot open URLs themselves; the native side
                // spooled the SGF and handed back the deep link to navigate to.
                if (reply.url) {
                    this.message("Opening KataGo Anytime…");
                    window.location.href = reply.url;
                } else {
                    this.message("Opened in KataGo Anytime.");
                }
            } catch (error) {
                this.message(String(error && error.message || error), true);
            }
        }

        friendlyError(reply) {
            const friendly = {
                boardTooLarge: "Boards larger than 19×19 aren't supported in Safari.",
                warmingUp: "Starting the analysis engine…",
                sgfParse: "This game's SGF could not be read.",
                engineDown: "Analysis is unavailable — tap Analyze to retry.",
                unknownGame: "Restarting analysis…",
            };
            return friendly[reply.code] || reply.message || "Analysis failed.";
        }

        /// Session-fatal errors only. Per-position failures that the wire marks
        /// retryable are handled at the call site and must NOT come here — this
        /// tears the whole session down.
        /// The line on screen as its own SGF: the original's root node — SZ,
        /// KM, RU, handicap stones, everything the position depends on —
        /// followed by the moves actually being displayed.
        ///
        /// A variation may not exist in the file at all: moves played on the
        /// board in WGo's edit mode live only in the page, so handing over the
        /// downloaded file would silently drop exactly what the reader wanted a
        /// deeper look at.
        linearizedSgf(sgf) {
            const line = this.currentLine;
            if (!line || !line.moves.length) { return sgf; }
            const open = sgf.indexOf("(");
            const rootStart = sgf.indexOf(";", open < 0 ? 0 : open);
            if (rootStart < 0) { return sgf; }
            // The root node runs until the next node or subtree begins. Property
            // values are skipped wholesale, since "]" and "\\" are escaped
            // inside them and a stray ";" or "(" in a comment is otherwise
            // indistinguishable from structure.
            let end = rootStart + 1;
            while (end < sgf.length) {
                const ch = sgf[end];
                if (ch === "[") {
                    end += 1;
                    while (end < sgf.length && sgf[end] !== "]") {
                        if (sgf[end] === "\\") { end += 1; }
                        end += 1;
                    }
                } else if (ch === ";" || ch === "(" || ch === ")") {
                    break;
                }
                end += 1;
            }
            const root = sgf.slice(rootStart, end);
            const body = line.moves.map((m) => {
                const tag = m.color === "b" ? "B" : "W";
                // A pass is the empty value.
                return m.pass ? `;${tag}[]`
                              : `;${tag}[${SGF_COORD[m.x]}${SGF_COORD[m.y]}]`;
            }).join("");
            return `(${root}${body})`;
        }

        onWireError(reply) {
            this.state = "error";
            this.analysisEnabled = false;
            this.scanning = false;
            this.el.analyze.textContent = "Analyze";
            this.el.scan.textContent = "Scan game";
            this.el.progress.hidden = true;
            this.message(this.friendlyError(reply), reply.code !== "warmingUp");
        }

        teardown() {
            if (this.dwellTimer !== null) {
                clearTimeout(this.dwellTimer);
                this.dwellTimer = null;
            }
            if (this.pending && this.pending.tier === "deep") { this.pending = null; }
            this.deepPending = false;
            // Bump regardless of which tier is in flight, and route the stop
            // through the same slot as any other cancel.
            //
            // On iOS a `pagehide` is usually a bfcache freeze, not a death: the
            // SAME PanelSession comes back on the way in, because the content
            // script is not re-injected (`__kgaContent` guards that). So a pass
            // killed by this stop returns to a live panel, and without the bump
            // it reads as a genuine fault — a red "analysis unavailable" nobody
            // caused, and mid-scan that position skipped for the whole session.
            this.cancelGeneration += 1;
            this.sendStop();
        }
    }
})();
