// Page-world hook (MAIN world, document_start). Binds the extension to a Go
// KIFU VIEWER through a small site-adapter seam (ADR 0016) — never to a URL.
// Adapter #1 is WGo.js: it traps WGo.BasicPlayer construction so the extension
// can reach player instances that pages keep in local variables
// (katagotraining.org's is created inside a load listener and never escapes).
// Adapter #2 is cyberoro's giboviewer, whose bespoke canvas player exposes no
// events, no SGF and no seek API, and whose record is a private dialect.
// Adapter #3 is OGS (online-go.com), a client-routed React app that publishes
// its live goban as window.global_goban and that KataGo stays off while a game
// is still being played (ADR 0017).
//
// Near-zero footprint on a page no adapter recognises: two property traps
// (window.WGo and window.global_goban) that must be in place before the page
// could possibly assign them, and one synchronous DOM read per DOM-shaped
// adapter. No timers, no DOM writes, no messages until a viewer is registered.
//
// Also injected as a fallback <script src> from the content script (Safari
// versions without manifest `world: "MAIN"`), so it must be idempotent.

(() => {
    "use strict";

    // ---- Node test hatch -------------------------------------------------
    //
    // `node --test SafariExtTests` loads this file to exercise the pure
    // converters below (see SafariExtTests/README.md). There is no `window`
    // there, so the hook installs nothing and only publishes them; function
    // declarations hoist, so the names are already bound at this point. Dead
    // in a page, where `window` always exists.
    if (typeof window === "undefined") {
        if (typeof module === "object" && module.exports) {
            module.exports = { giboToSgf, gobanToSgf, ogsAccess };
        }
        return;
    }

    if (window.__kgaHooked) { return; }
    Object.defineProperty(window, "__kgaHooked", { value: true });

    const registry = [];          // { id, viewer, adapterId }
    let nextPlayerNumber = 0;     // never reused, even after a removal
    let token = null;             // set on first outbound message
    let bridgeReady = false;
    const outQueue = [];

    function post(type, payload) {
        if (!token) { token = "kga-" + Math.random().toString(36).slice(2); }
        const message = { kga: token, dir: "p2c", type, payload };
        if (!bridgeReady && type !== "hello") { outQueue.push(message); return; }
        window.postMessage(message, "*");
    }

    window.addEventListener("message", (event) => {
        if (event.source !== window || !event.data || event.data.dir !== "c2p") { return; }
        const { type, payload } = event.data;
        if (type === "bridge-ready") {
            bridgeReady = true;
            post("hello", { players: registry.map(describe) });
            while (outQueue.length) { window.postMessage(outQueue.shift(), "*"); }
            return;
        }
        if (event.data.kga !== token) { return; }   // command channel is tokened
        try { handleCommand(type, payload); } catch (e) { /* never break the page */ }
    });

    // What the content script learns about a viewer. Every field is optional
    // for an adapter to supply; the shape is fixed so both content scripts
    // (which are independently maintained) keep reading one thing.
    function describe(entry) {
        const info = (entry.viewer && entry.viewer.describe && entry.viewer.describe()) || {};
        return {
            playerId: entry.id,
            sgfInline: typeof info.sgfInline === "string" ? info.sgfInline : null,
            sgfFile: typeof info.sgfFile === "string" ? info.sgfFile : null,
            hasJson: !!info.hasJson,
            // Where the panel should mount. Absent — the WGo default — means
            // the content script's own `.wgo-player-main` insertion; "floating"
            // means the page leaves no flow to insert into and the panel has to
            // dock itself into the viewport.
            anchor: info.anchor || null,
            // A STABLE session identity, for a viewer whose record grows under
            // it (ADR 0017): the native side keys its session on this rather
            // than on the SGF hash, which changes with every appended move.
            // Absent for a static kifu, where the hash IS the identity.
            gameId: typeof info.gameId === "string" ? info.gameId : null,
            // One line saying why this viewer is off limits, or null.
            refusal: typeof info.refusal === "string" ? info.refusal : null,
        };
    }

    // ---- the adapter seam -------------------------------------------------
    //
    // An ADAPTER is the code that knows how ONE KIND of kifu viewer exposes its
    // record, its current move and its board geometry (ADR 0016):
    //
    //   id          stable name, carried nowhere on the wire — diagnosis only.
    //   detect()    cheap, synchronous, side-effect free: could this page hold
    //               this kind of viewer? Re-run as the document fills in, so a
    //               DOM-shaped test is allowed to answer "not yet".
    //   attach(host) install; everything site-specific lives behind this call.
    //
    // `host` is the hook's half of the seam rather than the single viewer a
    // return value would be, because ONE PAGE MAY HOLD SEVERAL: the WGo adapter
    // registers one viewer per BasicPlayer it traps, and did so before this
    // seam existed. A viewer is:
    //
    //   describe()          { sgfInline, sgfFile, hasJson, anchor }
    //   goTo(n, mainline)   seek to move n, or a no-op where seeking is unsafe
    //   draw(state)         paint { ownership, candidates } for this viewer
    //   clear()             remove everything draw() painted
    //   detach()            release listeners and DOM
    const host = {
        register(viewer, adapterId) {
            // A MONOTONIC counter, not the registry length: a viewer can be
            // removed now (an SPA route change), and a reused id would attach a
            // dead panel to a live board.
            const id = "kga-p" + nextPlayerNumber;
            nextPlayerNumber += 1;
            registry.push({ id, viewer, adapterId });
            post("playerFound", describe(registry[registry.length - 1]));
            return id;
        },
        /// The viewer is gone: its board left the page. Both content scripts
        /// tear the session down on this.
        remove(playerId) {
            const at = registry.findIndex((entry) => entry.id === playerId);
            if (at < 0) { return; }
            registry.splice(at, 1);
            post("playerRemoved", { playerId });
        },
        /// The viewer became (or stopped being) off limits. `refusal` is the
        /// one line the panel shows, or null when analysis is allowed again.
        access(playerId, refusal) {
            post("playerAccess", { playerId, refusal: refusal || null });
        },
        /// The line on screen. `path` is only consulted when `line` is null.
        update(playerId, line, path) {
            post("playerUpdate", { playerId, path: sanitizePath(line, path), line: line || null });
        },
        /// A record was loaded (or reloaded, when a viewer's game grows).
        kifu(playerId, info) {
            post("kifuLoaded", Object.assign({ playerId }, info));
        },
    };

    function entryFor(playerId) {
        return registry.find((entry) => entry.id === playerId) || null;
    }

    function handleCommand(type, payload) {
        const entry = payload && entryFor(payload.playerId);
        if (!entry || !entry.viewer) { return; }
        switch (type) {
            case "goTo": {
                const move = Number(payload.moveIndex);
                if (!Number.isFinite(move)) { return; }
                entry.viewer.goTo(move, !!payload.mainline);
                return;
            }
            case "drawAnalysis":
                entry.viewer.draw({
                    ownership: Array.isArray(payload.ownership) ? payload.ownership : null,
                    candidates: Array.isArray(payload.candidates)
                        ? payload.candidates.slice(0, 50) : null,
                });
                return;
            case "clearOverlays":
                entry.viewer.clear();
                return;
        }
    }

    // Legacy shape, still posted alongside the line so the macOS content script
    // keeps working unchanged. Derived from the walk in the WGo adapter, so it
    // inherits that adapter's corrected `onMainline`.
    function sanitizePath(line, path) {
        if (line) { return { m: line.nodeDepth, onMainline: line.onMainline }; }
        if (!path || typeof path !== "object") { return { m: 0, onMainline: true }; }
        // An adapter may hand over the final shape already: a viewer that has
        // no branch keys to walk (cyberoro's variation mode, an OGS review)
        // knows the answer outright. WGo's own path object never carries this
        // key — its non-"m" keys are branch indices — so that path is untouched.
        if (typeof path.onMainline === "boolean") {
            return { m: Number(path.m) || 0, onMainline: path.onMainline };
        }
        let onMainline = true;
        for (const key of Object.keys(path)) {
            if (key !== "m" && Number(path[key])) { onMainline = false; break; }
        }
        return { m: Number(path.m) || 0, onMainline };
    }

    // ---- the shared analysis painter --------------------------------------
    //
    // Both analysis layers in AnalysisView's z-order: ownership squares first,
    // candidate circles on top. Visual constants mirror AnalysisView: full-cell
    // circles at 0.8 alpha (0.2 dimmed), a cell/16-wide systemBlue ring on the
    // best candidate, black bold monospaced text, grayscale ownership squares
    // sized by `scale`. `centreFor(x, y)` maps a wire point (x from the left,
    // y from the TOP, both 0-based) to a pixel centre in the target context.
    function paintAnalysis(ctx, state, cell, centreFor) {
        for (const own of (state && state.ownership) || []) {
            const side = cell * own.scale;
            if (!(side > 0)) { continue; }
            const v = Math.round(255 * Math.min(1, Math.max(0, own.whiteness)));
            ctx.fillStyle = `rgba(${v},${v},${v},${own.opacity})`;
            const c = centreFor(own.x, own.y);
            ctx.fillRect(c.cx - side / 2, c.cy - side / 2, side, side);
        }

        for (const mark of (state && state.candidates) || []) {
            const c = centreFor(mark.x, mark.y);
            const r = cell / 2;
            ctx.beginPath();
            ctx.arc(c.cx, c.cy, r, 0, 2 * Math.PI);
            // HSB(h,1,1) == HSL(h,100%,50%): the app's exact ramp.
            ctx.fillStyle = `hsla(${Math.round(mark.hue * 360)},100%,50%,${mark.dimmed ? 0.2 : 0.8})`;
            ctx.fill();
            if (mark.isBest) {
                ctx.beginPath();
                ctx.arc(c.cx, c.cy, r - cell / 32, 0, 2 * Math.PI);
                ctx.strokeStyle = "#007aff";
                ctx.lineWidth = cell / 16;
                ctx.stroke();
            }
            const lines = mark.dimmed ? [] : (mark.lines || []);
            if (lines.length) {
                ctx.fillStyle = "#000000";
                ctx.textAlign = "center";
                ctx.textBaseline = "middle";
                const size = lines.length > 1 ? cell * 0.26 : cell * 0.4;
                ctx.font = "700 " + size.toFixed(1) + "px ui-monospace, Menlo, monospace";
                const step = cell * 0.27;
                const y0 = c.cy - step * (lines.length - 1) / 2;
                lines.forEach((text, i) => ctx.fillText(text, c.cx, y0 + i * step));
            }
        }
    }

    // ---- adapter 1: WGo.js -------------------------------------------------

    const wgoAdapter = {
        id: "wgo",

        // Unconditional, and it has to be: the whole point of the trap is to be
        // in place BEFORE the page assigns window.WGo, which is long before any
        // DOM test could tell a WGo page from any other. The cost on a page that
        // never assigns it is one property descriptor.
        detect() { return true; },

        attach(hostApi) {
            function registerPlayer(player, elem, config) {
                // One custom object carries BOTH analysis layers so z-order
                // matches the app's AnalysisView (ownership under candidates) —
                // WGo draws obj_arr marks before obj_list customs, so split
                // layers would stack wrong. `analysisState` is mutated in place;
                // redraw() re-renders it.
                const analysisState = { ownership: null, candidates: null, registered: false };
                const viewer = {
                    describe() {
                        const c = config || {};
                        return {
                            sgfInline: typeof c.sgf === "string" ? c.sgf : null,
                            sgfFile: typeof c.sgfFile === "string"
                                ? new URL(c.sgfFile, location.href).href : null,
                            hasJson: !!c.json,
                        };
                    },
                    goTo(move, mainline) {
                        if (player.frozen) { return; }
                        // `mainline` means "move n OF THE GAME", which
                        // player.goTo(n) cannot do from inside a variation —
                        // see mainlinePath.
                        player.goTo(mainline ? mainlinePath(player, move) : move);
                    },
                    draw(state) {
                        const board = player && player.board;
                        if (!board || typeof board.addCustomObject !== "function") { return; }
                        analysisState.ownership = state.ownership;
                        analysisState.candidates = state.candidates;
                        if (!analysisState.registered) {
                            board.addCustomObject(analysisHandler, analysisState);
                            analysisState.registered = true;
                        } else {
                            try { board.redraw(); } catch (e) {}
                        }
                    },
                    clear() {
                        const board = player && player.board;
                        if (!board) { return; }
                        analysisState.ownership = null;
                        analysisState.candidates = null;
                        try { board.redraw(); } catch (e) {}
                    },
                    detach() { viewer.clear(); },
                };

                const id = hostApi.register(viewer, wgoAdapter.id);
                try {
                    player.addEventListener("update", (ev) => {
                        const line = readLine(player, ev && ev.node);
                        hostApi.update(id, line, ev && ev.path);
                    });
                    player.addEventListener("kifuLoaded", (ev) => {
                        const kifu = ev && ev.kifu;
                        hostApi.kifu(id, {
                            size: kifu && kifu.size,
                            moveCount: countMainline(kifu),
                        });
                    });
                } catch (e) { /* older forks without addEventListener: chart-only mode */ }
                // Post-hoc attach (declarative players): the kifu is already
                // loaded and the viewer may sit mid-game (data-wgo-move) —
                // synthesize the events the live listeners just missed.
                try {
                    if (player.kifu) {
                        hostApi.kifu(id, {
                            size: player.kifu.size,
                            moveCount: countMainline(player.kifu),
                        });
                        const path = player.kifuReader && player.kifuReader.path;
                        if (path) { hostApi.update(id, readLine(player), path); }
                    }
                } catch (e) { /* state snapshot is best-effort */ }
                return player;
            }

            const attachedPlayers = [];

            // WGo's declarative path (`<div data-wgo=…>`) constructs BasicPlayer
            // via a closure-local reference the property trap never sees, but it
            // stamps the instance on `element._wgo_player` — scan for those
            // after load. The data-wgo attribute holds either inline SGF ("(…")
            // or an SGF URL.
            function attachDeclarativePlayers() {
                for (const elem of document.querySelectorAll("[data-wgo]")) {
                    const player = elem._wgo_player;
                    if (!player || attachedPlayers.indexOf(player) >= 0) { continue; }
                    const raw = (elem.getAttribute("data-wgo") || "").trim();
                    const config = Object.assign(
                        raw.startsWith("(") ? { sgf: raw } : (raw ? { sgfFile: raw } : {}),
                        player.config || {});
                    attachedPlayers.push(registerPlayer(player, elem, config));
                }
            }

            // Load-time plus two retries covers static pages and slow inits;
            // constructor-trapped sites never reach here with work to do.
            const scan = () => { try { attachDeclarativePlayers(); } catch (e) {} };
            if (document.readyState === "complete") { scan(); }
            else { window.addEventListener("load", () => setTimeout(scan, 0), { once: true }); }
            setTimeout(scan, 1500);
            setTimeout(scan, 5000);

            function wrapBasicPlayer(WGoObj) {
                if (!WGoObj || WGoObj.__kgaWrapped) { return WGoObj; }
                const trap = (Orig) => {
                    function BasicPlayer(elem, config) {
                        const inst = Reflect.construct(Orig, [elem, config],
                                                       new.target || BasicPlayer);
                        try {
                            attachedPlayers.push(registerPlayer(inst, elem, config));
                        } catch (e) { /* never break the page */ }
                        return inst;
                    }
                    BasicPlayer.prototype = Orig.prototype;
                    Object.setPrototypeOf(BasicPlayer, Orig);
                    return BasicPlayer;
                };
                if (WGoObj.BasicPlayer) {
                    WGoObj.BasicPlayer = trap(WGoObj.BasicPlayer);
                } else {
                    let bp;
                    Object.defineProperty(WGoObj, "BasicPlayer", {
                        configurable: true,
                        get() { return bp; },
                        set(v) { bp = trap(v); },
                    });
                }
                try { Object.defineProperty(WGoObj, "__kgaWrapped", { value: true }); } catch (e) {}
                return WGoObj;
            }

            let realWGo;
            const existing = window.WGo;
            try {
                Object.defineProperty(window, "WGo", {
                    configurable: true,
                    get() { return realWGo; },
                    set(v) { realWGo = wrapBasicPlayer(v); },
                });
            } catch (e) { /* property locked: the declarative scan still covers it */ }
            if (existing) { window.WGo = existing; }
        },
    };

    // Read the ACTUAL line from the root to the node on screen.
    //
    // Replaces a truthiness test over WGo's `path` object, which could not
    // address a variation and got `onMainline` wrong in two reachable cases:
    // a move played in edit mode at a LEAF gets child index 0 and writes no
    // path key at all (`children.length` was never > 1), so an invented
    // position reported itself as the main line — and the extension then
    // analyzed a DIFFERENT position and drew the result on the reader's board.
    //
    // Walking up is also the only correct approach in edit mode: WGo swaps
    // `player.kifuReader` for a new reader over `player.kifu.clone()`, while
    // `player.kifu` still points at the original tree.
    function readLine(player, evNode) {
        const reader = player && player.kifuReader;   // never cache: edit mode swaps it
        const node = evNode || (reader && reader.node);
        if (!node) { return null; }
        const BLACK = (window.WGo && window.WGo.B) || 1;

        const chain = [];
        for (let n = node; n; n = n.parent) { chain.push(n); }
        chain.reverse();

        // Where each node sits in its parent's children array; index 0 is the
        // main line, because the parser appends in file order.
        const childIndices = [];
        for (let i = 1; i < chain.length; i += 1) {
            childIndices.push(chain[i].parent.children.indexOf(chain[i]));
        }

        // Leading run of child-0 steps = the main-line prefix. `_edited` marks
        // nodes WGo's edit mode invented; the index alone would call those
        // main line.
        let prefixNodes = 0;
        for (let k = 0; k < childIndices.length; k += 1) {
            if (childIndices[k] !== 0 || chain[k + 1]._edited) { break; }
            prefixNodes += 1;
        }

        const moves = [];
        let edited = false;
        let prefixMoves = 0;
        for (let j = 0; j < chain.length; j += 1) {
            const nd = chain[j];
            if (nd._edited) { edited = true; }
            if (nd.move) {
                // Color is ALWAYS explicit on the node. Never infer it by
                // alternation — handicap, passes and PL[] all break that.
                moves.push({
                    color: nd.move.c === BLACK ? "b" : "w",
                    // A pass is {pass:true, c} with NO x/y — not (-1,-1).
                    pass: !!nd.move.pass,
                    x: nd.move.pass ? null : nd.move.x,   // 0 = left column
                    y: nd.move.pass ? null : nd.move.y,   // 0 = TOP row
                });
                if (j <= prefixNodes) { prefixMoves = moves.length; }
            }
        }

        return {
            size: (reader && reader.kifu && reader.kifu.size) || 19,
            // Node depth, which is what WGo's own path.m counts and what goTo
            // expects. NOT the move count: a setup-only node inflates it.
            nodeDepth: chain.length - 1,
            moveCount: moves.length,
            onMainline: prefixNodes === childIndices.length && !edited,
            mainlinePrefixMoves: prefixMoves,
            edited,
            // Authoritative side to move; already accounts for HA > 1 and PL[].
            turn: reader && reader.game ? (reader.game.turn === BLACK ? "b" : "w") : null,
            moves,
        };
    }

    // Force the TRUE main line at MOVE number n.
    //
    // player.goTo(n) will NOT do this: it clones the current path — branch keys
    // included — and `rememberPath` (default true) makes unkeyed forks follow
    // `_last_selected`. Sitting at {m:5, 4:1}, goTo(3) then goTo(5) lands back
    // in the variation. There is no move-number seek that reaches the main line.
    function mainlinePath(player, n) {
        const kifu = player && player.kifuReader && player.kifuReader.kifu;
        const path = { m: 0 };
        let node = kifu && kifu.root;
        let depth = 0;
        let moves = 0;
        // `n` is a MOVE count — what the chart plots and what the analysis is
        // indexed by — while WGo's path.m counts NODES. A move-less main-line
        // node (a standalone comment or a setup node) makes the two diverge, so
        // count moves on the way down and hand goTo the node depth reached.
        while (node && moves < n && node.children.length) {
            if (node.children.length > 1) { path[depth + 1] = 0; }
            node = node.children[0];
            depth += 1;
            if (node.move) { moves += 1; }
        }
        path.m = depth;
        return path;
    }

    function countMainline(kifu) {
        let count = 0;
        let node = kifu && kifu.root;
        while (node && node.children && node.children.length) {
            node = node.children[0];
            if (node.move) { count += 1; }
        }
        return count;
    }

    // Custom handlers MUST be layer-keyed — WGo's redraw does
    // `for (d in handler) handler[d].draw.call(board[d].getContext(...))`, so a
    // flat {draw} makes board["draw"].getContext throw (swallowed by WGo's
    // try/catch) and nothing paints.
    const analysisHandler = {
        stone: {
            draw(state, board) {
                // Cell size from coordinate deltas — board.fieldWidth is not
                // present on every WGo build (NaN would draw nothing).
                const cell = board.size > 1
                    ? Math.abs(board.getX(1) - board.getX(0))
                    : board.stoneRadius * 2;
                paintAnalysis(this, state, cell,
                              (x, y) => ({ cx: board.getX(x), cy: board.getY(y) }));
            },
        },
    };

    // ---- the gibo dialect --------------------------------------------------
    //
    // cyberoro serves its records in a private dialect that LOOKS like SGF and
    // is not: it opens with a bare "(" and a property block with no root ";",
    // spells the event TE, the date RD, the komi KO and the handicap HD, has no
    // SZ (LN when the board is not 19x19) and no CA, writes a pass as a pair of
    // backticks, embeds reference variations in RN[...] blocks terminated by an
    // UNMATCHED ")", and appends the site's own engine output after a "//AI"
    // line. KataGo's parser rejects the raw text on the very first token —
    // cpp/dataio/sgf.cpp:1450-1455 requires a ";" after "(" — so something has
    // to rewrite it, and it happens HERE because the dialect belongs to one
    // site's viewer rather than to SGF (ADR 0016). The native side, the App
    // Group cache, the sgfHash and "Open in app" all keep working unchanged.
    //
    // Every rule below mirrors the site's own reader, main_new.js
    // DecodeSGFFile (:425-653), so the SGF describes the board the reader is
    // actually looking at. Returns null when the text is not a gibo record.

    // A FUNCTION, not a `const` table: the Node test hatch at the top of this
    // IIFE returns before any `const` in the file has initialized, so anything
    // the exported converters reach has to be hoisted.
    function sgfLetter(index) { return "abcdefghijklmnopqrstuvwxyz"[index]; }

    function giboToSgf(text) {
        const source = String(text == null ? "" : text);
        if (!/^\s*\(\s*;?/.test(source)) { return null; }

        // Order matters. Reference blocks first, because their move lists would
        // otherwise be read as main-line moves; then the //AI trailer, whose
        // lines contain commas and percent signs but also digits that a later
        // ")" scan must not see; then the record's own closing paren.
        let body = stripReferenceBlocks(source);
        const ai = body.indexOf("//AI");
        if (ai >= 0) { body = body.slice(0, ai); }
        const close = body.lastIndexOf(")");
        if (close >= 0) { body = body.slice(0, close); }

        const header = { EV: "", DT: "", PC: "", PB: "", PW: "", BR: "", WR: "", RE: "", KM: "" };
        const moves = [];
        const comments = [];
        let handicap = 0;
        let boardSize = 19;
        let seen = 0;

        let i = 0;
        while (i < body.length) {
            let j = i;
            while (j < body.length && body[j] >= "A" && body[j] <= "Z") { j += 1; }
            if (j === i) { i += 1; continue; }        // "(", ")", ";", newlines
            const tag = body.slice(i, j);
            i = j;
            if (body[i] !== "[") { continue; }
            i += 1;
            // EVERY property value ends at the first "]" — the dialect has no
            // escaping at all, and the site's own reader stops there too
            // (main_new.js mode 3 and mode 5).
            const end = body.indexOf("]", i);
            const value = end < 0 ? body.slice(i) : body.slice(i, end);
            i = end < 0 ? body.length : end + 1;
            seen += 1;

            switch (tag) {
                // The site folds every title-ish tag into one game name
                // (main_new.js:479-482), so they concatenate here too.
                case "TE": case "EV": case "GN": case "GD": case "GH":
                    header.EV += value; break;
                case "RD": case "DT": header.DT = value; break;
                case "PC": header.PC = value; break;
                case "PB": header.PB = value; break;
                case "PW": header.PW = value; break;
                case "BR": header.BR = value; break;
                case "WR": header.WR = value; break;
                case "RE": header.RE = value; break;
                // KO is the komi and arrives as a decimal already (KO[7.5]).
                case "KO": header.KM = value.trim(); break;
                case "HD": handicap = parseInt(value, 10) || 0; break;
                // LN is the board's line count and arrives as a STRING
                // (main_new.js:629 stores the raw property value).
                case "LN": {
                    const lines = parseInt(value, 10);
                    if (lines >= 2 && lines <= 26) { boardSize = lines; }
                    break;
                }
                case "C":
                    // Site parity: its comment reader drops "[" and stops at the
                    // first "]", so a comment can never contain either — which
                    // is what makes re-emitting it into real SGF safe.
                    comments.push({ index: moves.length, text: value.replace(/\[/g, "") });
                    break;
                case "B": case "W": {
                    const move = decodeGiboMove(tag, value, boardSize);
                    if (move) { moves.push(move); }
                    break;
                }
                default:
                    // TM/LT/LC/GK/TC and anything new: TM holds localized prose
                    // ("2 hours") where SGF's TM is a Real, and LT/LC are not
                    // SGF properties at all. Dropping them keeps the output a
                    // file other Go tools can read.
                    break;
            }
        }

        if (!seen) { return null; }
        return {
            sgf: buildGiboSgf(header, handicap, boardSize, moves, comments),
            moves,
            boardSize,
            handicap,
        };
    }

    // RN[...] holds a reference VARIATION: a title, a PT[] sequence number, its
    // own move list and comments, all terminated by an unmatched ")". The site
    // consumes it the same way, counting parens from just after the "[" until
    // the count reaches -1 (main_new.js:585-604). Removing these first is what
    // lets everything downstream treat the text as one linear game.
    function stripReferenceBlocks(text) {
        let out = "";
        let i = 0;
        for (;;) {
            const start = text.indexOf("RN[", i);
            if (start < 0) { return out + text.slice(i); }
            out += text.slice(i, start);
            let depth = 0;
            let j = start + 3;
            while (j < text.length) {
                const ch = text[j];
                if (ch === "(") { depth += 1; }
                else if (ch === ")") {
                    depth -= 1;
                    if (depth === -1) { j += 1; break; }
                }
                j += 1;
            }
            i = j;   // an unterminated block swallows the rest, as the site's does
        }
    }

    function decodeGiboMove(tag, value, boardSize) {
        const color = tag === "B" ? "b" : "w";
        if (value.length !== 2) { return null; }
        const x = value.charCodeAt(0) - 96;
        const y = value.charCodeAt(1) - 96;
        // A pass is a pair of backticks: charCode 96 is exactly "one before a",
        // so the site reads it as column 0 and calls PassMove (main_new.js:1514).
        if (x === 0) { return { color, pass: true, x: null, y: null }; }
        if (x < 1 || x > boardSize || y < 1 || y > boardSize) { return null; }
        // Wire coordinates: x from the LEFT and y from the TOP, both 0-based,
        // matching what the WGo adapter posts (and the dialect's own 1-based
        // top-left pair).
        return { color, pass: false, x: x - 1, y: y - 1 };
    }

    // The site's own handicap placement table (OwlGoBase.js:250-296), called
    // with H3Down = true (main_new.js:1260). Only the 19x19 branch is
    // reachable: the 13x13 and 9x9 branches test an UNDECLARED global `BSize`
    // (OwlGoBase.js:297, :330), which throws before a stone is placed — so a
    // handicap record on a smaller board draws no handicap stones on the page
    // either, and our SGF must show the board the reader is looking at.
    function giboHandicapStones(handicap, boardSize) {
        if (boardSize !== 19 || !(handicap >= 2) || handicap >= 20) { return []; }
        const at = (x, y) => sgfLetter(x - 1) + sgfLetter(y - 1);
        const stones = [at(16, 4), at(4, 16)];
        if (handicap >= 3) { stones.push(at(16, 16)); }
        if (handicap >= 4) { stones.push(at(4, 4)); }
        if (handicap === 5 || handicap === 7 || handicap === 9) { stones.push(at(10, 10)); }
        if (handicap >= 6) { stones.push(at(4, 10), at(16, 10)); }
        if (handicap >= 8) { stones.push(at(10, 4), at(10, 16)); }
        if (handicap >= 10) { stones.push(at(7, 7), at(7, 13), at(13, 7), at(13, 13)); }
        return stones;
    }

    function buildGiboSgf(header, handicap, boardSize, moves, comments) {
        const escape = (v) => String(v).replace(/([\]\\])/g, "\\$1");
        let sgf = "(;GM[1]FF[4]CA[UTF-8]SZ[" + boardSize + "]";
        const put = (tag, value) => {
            if (value != null && String(value).trim() !== "") {
                sgf += tag + "[" + escape(value) + "]";
            }
        };
        put("EV", header.EV);
        put("DT", header.DT);
        put("PC", header.PC);
        put("PB", header.PB);
        put("BR", header.BR);
        put("PW", header.PW);
        put("WR", header.WR);
        put("RE", header.RE);
        // Guarded: KM's type is Real, and a record whose KO carried prose would
        // otherwise produce a file KataGo reads as komi 0.
        if (/^-?\d+(\.\d+)?$/.test(header.KM)) { sgf += "KM[" + header.KM + "]"; }
        const stones = giboHandicapStones(handicap, boardSize);
        if (stones.length) {
            sgf += "HA[" + handicap + "]AB" + stones.map((p) => "[" + p + "]").join("");
        }

        const byIndex = new Map();
        for (const c of comments) {
            const prior = byIndex.get(c.index);
            byIndex.set(c.index, prior ? prior + "\n" + c.text : c.text);
        }
        if (byIndex.has(0)) { sgf += "C[" + escape(byIndex.get(0)) + "]"; }
        moves.forEach((move, k) => {
            const point = move.pass ? "" : sgfLetter(move.x) + sgfLetter(move.y);
            sgf += ";" + (move.color === "b" ? "B" : "W") + "[" + point + "]";
            const text = byIndex.get(k + 1);
            if (text) { sgf += "C[" + escape(text) + "]"; }
        });
        return sgf + ")";
    }

    // ---- adapter 2: cyberoro giboviewer ------------------------------------

    const cyberoroAdapter = {
        id: "cyberoro",

        detect() {
            // The giboviewer skin: the record inlined in a hidden input, the
            // bare board canvas, and the page's own loader. The ".sgf" test is
            // the DECODER the page will pick — main_new.js:419-422 chooses
            // DecodeSGFFile / DecodeNGFFile / DecodeUGFFile off the file
            // extension in #gibo, and giboToSgf reads only the SGF dialect.
            const source = document.getElementById("gibo");
            return !!document.getElementById("gibo_txt")
                && !!document.getElementById("board")
                && typeof window.GameStart === "function"
                && !!source
                && /\.sgf$/i.test(String(source.value || "").trim());
        },

        attach(hostApi) {
            // GameStart re-arms itself on a 1 s interval until roughly ninety
            // preloaded images have landed (main_new.js:213), so the page
            // objects this adapter needs appear seconds after the DOM does and
            // there is no event to wait on. Poll, and do not give up early:
            // detect() has already established this IS a giboviewer page, so a
            // short cap would only strand a reader on a slow connection.
            const startedAt = Date.now();
            const waiting = setInterval(() => {
                if (!(window.pbBoard && window.GoBoard && window.GameI)) {
                    if (Date.now() - startedAt > 120000) { clearInterval(waiting); }
                    return;
                }
                clearInterval(waiting);
                try { installCyberoro(hostApi); } catch (e) { /* never break the page */ }
            }, 500);
        },
    };

    function installCyberoro(hostApi) {
        // The record, captured ONCE.
        //
        // #gibo_txt is the ASP page's own copy, already transcoded to UTF-8 —
        // the raw file at open.cyberoro.com is EUC-KR, sends no
        // Access-Control-Allow-Origin, and Response.text() always decodes as
        // UTF-8 anyway, so fetching it would cost a round trip to produce
        // mojibake. It must be read exactly once: openReference() OVERWRITES
        // the input with a bare coordinate string when the reader opens a
        // variation popup (main_new.js:1706-1715).
        //
        // window.gibo is NOT a fallback, despite holding the same text at the
        // top of GameStart: DecodeAI reassigns it to the "//AI" trailer and
        // then consumes it line by line (main_new.js:991, :1028), so on any
        // record carrying the site's own engine output it is a stump by the
        // time an adapter could read it.
        const input = document.getElementById("gibo_txt");
        const record = giboToSgf(input && input.value);
        if (!record || !record.moves.length) { return; }

        const board = window.GoBoard;
        // The page drops a recorded move its own rules engine refuses
        // (OwlGoBase.js:752 records only what CanPut() allows), which would
        // slide every later index by one. Trust the shorter of the two.
        const reachable = Number(board.NowMaxSN());
        const moveCount = Number.isFinite(reachable) && reachable > 0
            ? Math.min(record.moves.length, reachable) : record.moves.length;

        let overlay = null;
        let analysis = { ownership: null, candidates: null };
        let lastSeq = -1;
        let lastMode = null;
        let lastGeometry = "";
        let coalescing = false;

        const viewer = {
            describe() {
                return {
                    sgfInline: record.sgf,
                    sgfFile: null,
                    hasJson: false,
                    // The whole page is position:fixed and the body has no flow
                    // at all, so the content script's body-end fallback would
                    // drop the panel underneath a full-viewport white div.
                    anchor: "floating",
                };
            },
            goTo(move) { seek(move); },
            draw(state) { analysis = state; redraw(); },
            clear() { analysis = { ownership: null, candidates: null }; redraw(); },
            detach() { teardown(); },
        };

        const playerId = hostApi.register(viewer, cyberoroAdapter.id);
        hostApi.kifu(playerId, { size: record.boardSize, moveCount });

        // GoBoardInfo is the page's own per-move notification: TGoBoard calls it
        // synchronously from Progress(), Retract() and PassMove()
        // (OwlGoBase.js:759 and neighbours), which is HUNDREDS of calls for one
        // seek to the end of a game. Wrap it — the same "trap the page's own
        // seam" move as the WGo BasicPlayer trap — and COALESCE into a
        // microtask, so a whole seek posts exactly once and an ordinary step
        // still posts immediately.
        const originalGoBoardInfo = window.GoBoardInfo;
        window.GoBoardInfo = function kgaGoBoardInfo() {
            const result = typeof originalGoBoardInfo === "function"
                ? originalGoBoardInfo.apply(this, arguments) : undefined;
            coalesce();
            return result;
        };

        // The safety net for everything that moves the board without going
        // through GoBoardInfo: the coordinate button (which resizes the canvas),
        // a window resize, and the mode switches that only assign NowMode.
        const poll = setInterval(() => {
            if (stateChanged()) { postState(); }
            if (geometrySignature() !== lastGeometry) { redraw(); }
        }, 500);

        let observer = null;
        try {
            observer = new ResizeObserver(() => redraw());
            const canvas = document.getElementById("board");
            if (canvas) { observer.observe(canvas); }
        } catch (e) { /* the 500 ms poll still covers resizes */ }

        postState();
        redraw();

        function coalesce() {
            if (coalescing) { return; }
            coalescing = true;
            queueMicrotask(() => {
                coalescing = false;
                if (stateChanged()) { postState(); }
            });
        }

        function currentSeq() {
            const seq = Number(window.GoBoard && window.GoBoard.NowSeqNo());
            return Number.isFinite(seq) ? seq : 0;
        }

        function stateChanged() {
            return currentSeq() !== lastSeq || window.NowMode !== lastMode;
        }

        function postState() {
            lastSeq = currentSeq();
            lastMode = window.NowMode;
            // "MakeVar" is the reader building their OWN variation on the
            // site's board. Those moves are nowhere in the record, so there is
            // no line to analyze: report the shape both content scripts already
            // understand — no line, off the main line — and they show
            // "Viewing a variation" and hide the board marks.
            if (lastMode === "MakeVar") {
                const base = Number(window.GoBoard && window.GoBoard.MinSN);
                hostApi.update(playerId, null,
                               { m: Number.isFinite(base) ? base : 0, onMainline: false });
                return;
            }
            hostApi.update(playerId, lineAt(lastSeq), null);
        }

        function lineAt(seq) {
            const upTo = Math.max(0, Math.min(seq, moveCount));
            const moves = record.moves.slice(0, upTo);
            return {
                size: record.boardSize,
                // The gibo record is one line with no branches once the RN
                // blocks are stripped, so node depth and move count are the
                // same number.
                nodeDepth: moves.length,
                moveCount: moves.length,
                onMainline: true,
                mainlinePrefixMoves: moves.length,
                edited: false,
                turn: turnAfter(moves.length),
                moves: moves.map((move) => ({
                    color: move.color,
                    pass: move.pass,
                    x: move.pass ? null : move.x,
                    y: move.pass ? null : move.y,
                })),
            };
        }

        function turnAfter(n) {
            // Colour is explicit on every recorded move, so the side to move is
            // read off the record rather than inferred by alternation — a
            // handicap game opens with White and a pass does not change the
            // rule.
            if (n < record.moves.length) { return record.moves[n].color; }
            if (n > 0) { return record.moves[n - 1].color === "b" ? "w" : "b"; }
            return record.handicap >= 2 ? "w" : "b";
        }

        function seek(target) {
            // The viewer exposes no seek API, so drive its own step functions
            // exactly the way its win-rate-graph click does
            // (main_new.js:1793-1822): `Dump` silences the stone sound and the
            // per-move readout while the loop runs, and the readout is
            // refreshed once at the end.
            //
            // Only in Review mode. Seeking during MakeVar would rewrite the
            // variation the reader is building.
            if (window.NowMode !== "Review") { return; }
            const board = window.GoBoard;
            const max = Number(board.NowMaxSN()) || 0;
            const want = Math.max(0, Math.min(Number(target) || 0, max));
            let guard = 0;
            window.Dump = true;
            try {
                while (want < board.NowSeqNo() && guard++ < 2000) { board.Retract(); }
                // Progress() reports true whenever there IS a next recorded
                // move, even when CanPut() refuses to place it
                // (OwlGoBase.js:735-760) — so its return value cannot end this
                // loop. Break on the sequence number standing still instead.
                while (want > board.NowSeqNo()
                       && board.NowMaxSN() > board.NowSeqNo() && guard++ < 2000) {
                    const before = board.NowSeqNo();
                    board.Progress();
                    if (board.NowSeqNo() === before) { break; }
                }
            } finally {
                window.Dump = false;
            }
            try {
                window.SetNowAI(board.NowSeqNo());
                window.SetNowHelpText();
            } catch (e) { /* the site's own readouts are best-effort */ }
            postState();
        }

        function geometrySignature() {
            const canvas = document.getElementById("board");
            const pb = window.pbBoard || {};
            return [canvas && canvas.width, canvas && canvas.height,
                    pb.szGrid, pb.line, !!pb.CCord].join("/");
        }

        function ensureOverlay() {
            const canvas = document.getElementById("board");
            if (!canvas || !canvas.parentNode) { return null; }
            if (!overlay || !overlay.isConnected) {
                overlay = document.createElement("canvas");
                // The board canvas owns mousedown (InputSystem_new.js), so the
                // overlay must never take a hit.
                overlay.style.position = "absolute";
                overlay.style.left = "0";
                overlay.style.top = "0";
                overlay.style.pointerEvents = "none";
                canvas.parentNode.insertBefore(overlay, canvas.nextSibling);
            }
            // The site sizes its canvas by the width/height ATTRIBUTES and
            // gives it no CSS box, so canvas pixels are CSS pixels and
            // mirroring the attributes is the whole alignment story.
            if (overlay.width !== canvas.width) { overlay.width = canvas.width; }
            if (overlay.height !== canvas.height) { overlay.height = canvas.height; }
            return overlay;
        }

        function redraw() {
            lastGeometry = geometrySignature();
            const canvas = ensureOverlay();
            if (!canvas) { return; }
            const ctx = canvas.getContext("2d");
            if (!ctx) { return; }
            ctx.clearRect(0, 0, canvas.width, canvas.height);
            const pb = window.pbBoard || {};
            const grid = Number(pb.szGrid) || 0;
            if (!(grid > 0)) { return; }
            // pbBoard.line is a STRING whenever it came from the record's LN
            // tag (SetBoard assigns GameI.Lines straight through,
            // GoPBUnit.js:674), so coerce before any arithmetic.
            const lines = Number(pb.line) || record.boardSize;
            const half = Math.floor(grid / 2);
            // CCord turns the board through 180 degrees (GoPBUnit.js:534-541).
            // No button on this skin sets it — btn_cordi toggles the coordinate
            // MARGIN instead (InputSystem_new.js:734-744) — but DrawStone
            // honours it, so honour it too rather than paint a mirrored board.
            const flipped = !!pb.CCord;
            paintAnalysis(ctx, analysis, grid, (x, y) => {
                const fx = flipped ? lines - 1 - x : x;
                const fy = flipped ? lines - 1 - y : y;
                // The grid starts at pixel 0 with its first line at hszGrid
                // (GoPBUnit.js:150-156) and a stone fills the szGrid cell that
                // begins at (X-1)*szGrid. The coordinate margin only grows the
                // canvas; it never moves this origin.
                return { cx: fx * grid + half, cy: fy * grid + half };
            });
        }

        function teardown() {
            clearInterval(poll);
            if (observer) { try { observer.disconnect(); } catch (e) {} }
            // Restore rather than delete: GoBoardInfo is a plain page global
            // the board calls on every move, and leaving a hole would break the
            // viewer for a reader who merely navigated away from the panel.
            window.GoBoardInfo = originalGoBoardInfo;
            if (overlay && overlay.parentNode) { overlay.parentNode.removeChild(overlay); }
            overlay = null;
        }
    }

    // ---- OGS (online-go.com) -----------------------------------------------
    //
    // ADR 0017: KataGo stays OFF ongoing games. OGS's terms of service forbid
    // using neural networks to analyse "current ongoing games", and the clause
    // is not scoped to games you are playing — so a game is analysed only once
    // it is FINISHED. A demo board has no source game and is always allowed; a
    // review of a live game IS a live game.
    //
    // A pure function, so the rule can be read and tested without a browser and
    // so the future spectator rule can sit in the code, off, instead of living
    // in a comment.
    function ogsAccess(state) {
        const s = state || {};
        // A demo board is nobody's game in progress: there is no source game to
        // be ongoing, and nothing a reader could learn from it that they are
        // not already free to work out on the board in front of them.
        if (!s.hasSourceGame) { return { allowed: true, reason: "demo" }; }
        if (s.phase === "finished") { return { allowed: true, reason: "finished" }; }
        if (!s.liveSpectatingEnabled) { return { allowed: false, reason: "ongoing" }; }
        // Everything past here is the OFF branch. An anonymous viewer is
        // provably not a participant of THIS page and says nothing about the
        // game they have open in the next tab, which is exactly the hole the
        // rule has to close.
        if (!s.signedIn) { return { allowed: false, reason: "anonymous" }; }
        if (s.isPlayer) { return { allowed: false, reason: "participant" }; }
        if (s.analysisDisabled) { return { allowed: false, reason: "analysisDisabled" }; }
        return { allowed: true, reason: "spectating" };
    }

    // Implemented and OFF (ADR 0017). Turning it on is a conversation with OGS
    // staff, not a code change: OGS's own analysis board exempts spectators
    // from a game's disable_analysis flag ("spectators may always analyze",
    // online-go.com src/lib/configure-goban.tsx:99-100), which points the other
    // way from the terms, and no staff statement resolves the two.
    function ogsLiveSpectatingEnabled() { return false; }

    // The MAIN LINE of an OGS game, review or demo, as SGF.
    //
    // Main line ONLY, and the reason is the parser on the other end: KataGo
    // follows the DEEPEST child at a fork while OGS's tree follows
    // `trunk_next`, so emitting variations would hand the engine a different
    // game than the reader is looking at — and KataGo rejects AB/AW after the
    // root, which is exactly where a review's later edits live.
    //
    // A LEADING run of `edited` nodes is setup rather than play, so it folds
    // into the root's AB/AW on top of `initial_state`. The first `edited` node
    // AFTER a real move truncates the file, because nothing downstream can
    // express it.
    function gobanToSgf(engine) {
        if (!engine || !engine.move_tree) { return null; }
        const width = Number(engine.width) || 19;
        const height = Number(engine.height) || width;

        const setupBlack = [];
        const setupWhite = [];
        // goban encodes coordinates with the SGF alphabet and the same
        // top-left origin (goban src/engine/util/coordinates.ts:20-33), so an
        // initial-state string IS an SGF point list already. "." is its pass
        // marker and has no place in a setup list.
        const takePoints = (into, encoded) => {
            const text = String(encoded || "");
            for (let i = 0; i + 1 < text.length; i += 2) {
                const point = text.slice(i, i + 2);
                if (point.indexOf(".") < 0) { into.push(point); }
            }
        };
        takePoints(setupBlack, engine.initial_state && engine.initial_state.black);
        takePoints(setupWhite, engine.initial_state && engine.initial_state.white);

        const moves = [];
        let node = engine.move_tree;
        let sawMove = false;
        for (;;) {
            const next = ogsMainChild(node);
            if (!next) { break; }
            node = next;
            if (node.edited) {
                if (sawMove) { break; }
                if (node.x >= 0) {
                    (node.player === 1 ? setupBlack : setupWhite).push(ogsPoint(node));
                }
                continue;
            }
            sawMove = true;
            moves.push({
                color: node.player === 1 ? "B" : "W",
                point: node.x === -1 ? "" : ogsPoint(node),
            });
        }

        const escape = (v) => String(v).replace(/([\]\\])/g, "\\$1");
        let sgf = "(;GM[1]FF[4]CA[UTF-8]SZ["
            + (width === height ? width : width + ":" + height) + "]";
        const players = engine.players || {};
        if (players.black && players.black.username) {
            sgf += "PB[" + escape(players.black.username) + "]";
        }
        if (players.white && players.white.username) {
            sgf += "PW[" + escape(players.white.username) + "]";
        }
        const komi = Number(engine.komi);
        if (Number.isFinite(komi)) { sgf += "KM[" + komi + "]"; }
        if (typeof engine.rules === "string" && engine.rules) {
            sgf += "RU[" + escape(engine.rules) + "]";
        }
        const handicap = Number(engine.handicap) || 0;
        if (handicap > 0) { sgf += "HA[" + handicap + "]"; }
        // A handicap game opens with White, and OGS says so on the config
        // rather than through the setup stones — SgfHeaderScan's all-black
        // fallback would otherwise be the only thing carrying it.
        const first = engine.config && engine.config.initial_player;
        if (first === "white" || first === "black") {
            sgf += "PL[" + (first === "white" ? "W" : "B") + "]";
        }
        if (setupBlack.length) {
            sgf += "AB" + setupBlack.map((p) => "[" + p + "]").join("");
        }
        if (setupWhite.length) {
            sgf += "AW" + setupWhite.map((p) => "[" + p + "]").join("");
        }
        for (const move of moves) { sgf += ";" + move.color + "[" + move.point + "]"; }
        return { sgf: sgf + ")", moveCount: moves.length, width, height };
    }

    /// The next node ON THE MAIN LINE. A game and a review carry `trunk_next`;
    /// a demo board has no trunk at all, so its first branch is its main line.
    function ogsMainChild(node) {
        if (!node) { return null; }
        if (node.trunk_next) { return node.trunk_next; }
        return (node.branches && node.branches[0]) || null;
    }

    function ogsPoint(node) { return sgfLetter(node.x) + sgfLetter(node.y); }

    const OGS_REFUSAL = "KataGo stays off ongoing games — OGS's terms forbid "
        + "engine analysis of a game in progress.";

    const ogsAdapter = {
        id: "ogs",

        // Unconditional, like the WGo trap and for the same reason: OGS is a
        // client-routed React app, so by the time any DOM test could recognise
        // it the assignment this adapter waits for has already happened. The
        // cost on every other page is one property descriptor.
        detect() { return true; },

        attach(hostApi) {
            // `window.global_goban` is set by <Game/> on mount and nulled on
            // unmount (online-go.com src/views/Game/Game.tsx:283, :600). All ten
            // game/review/demo routes render that component and set it; the two
            // /embed routes render a MiniGoban and never do — which is why the
            // ASSIGNMENT is the detection, and no URL is ever inspected.
            let live;
            let session = null;
            try {
                Object.defineProperty(window, "global_goban", {
                    configurable: true,
                    get() { return live; },
                    set(value) {
                        live = value;
                        if (session) { session.dispose(); session = null; }
                        if (value) {
                            try { session = bindOgsGoban(hostApi, value); }
                            catch (e) { /* never break the page */ }
                        }
                    },
                });
            } catch (e) { return; /* property locked: nothing else to try */ }
            const existing = window.global_goban;
            if (existing) { window.global_goban = existing; }
        },
    };

    function bindOgsGoban(hostApi, goban) {
        let playerId = null;
        let analysis = { ownership: null, candidates: null };
        let overlay = null;
        let restoreParentPosition = null;
        let lastSgf = null;
        let lastRefusal = "";
        let boardWidth = 19;
        let moveCount = 0;
        let disposed = false;
        let observer = null;
        let redrawTimer = null;
        const unbinders = [];

        const listen = (target, event, handler) => {
            if (!target || typeof target.on !== "function") { return; }
            try {
                target.on(event, handler);
                unbinders.push(() => { try { target.off(event, handler); } catch (e) {} });
            } catch (e) { /* an older goban without this event */ }
        };

        const viewer = {
            describe() {
                return {
                    sgfInline: lastSgf,
                    sgfFile: null,
                    hasJson: false,
                    // OGS's .Goban is absolutely positioned inside a flex
                    // column: inserting after it overlaps the board, and
                    // inserting after .goban-container shrinks the board.
                    anchor: "floating",
                    gameId: sessionKey(),
                    refusal: lastRefusal || null,
                };
            },
            goTo(move, mainline) { seek(move, mainline); },
            draw(state) { analysis = state; paint(); },
            clear() { analysis = { ownership: null, candidates: null }; paint(); },
            detach() { dispose(); },
        };

        // Games, reviews and demos are three identities, and they must not
        // collide: a review of game 42 is not game 42. The native side keys its
        // whole session on this instead of on the SGF hash, which changes every
        // time a demo's author plays another stone.
        function sessionKey() {
            const review = Number(goban.review_id) || 0;
            if (review > 0) { return (hasSourceGame() ? "ogs:review:" : "ogs:demo:") + review; }
            return "ogs:game:" + (Number(goban.game_id) || 0);
        }

        function hasSourceGame() {
            const engine = goban.engine;
            const fromEngine = engine && engine.config && Number(engine.config.game_id);
            return Number(fromEngine || goban.game_id || 0) > 0;
        }

        function accessState() {
            const engine = goban.engine;
            const user = window.user || {};
            const attempt = (fn, fallback) => {
                try { return fn(); } catch (e) { return fallback; }
            };
            return {
                hasSourceGame: hasSourceGame(),
                phase: engine && engine.phase,
                isPlayer: attempt(() => !!goban.isCurrentUserAPlayer(), false),
                // The STRICTEST reading of OGS's own flag: pass true so a game
                // whose creator ticked "disable analysis" is off limits to
                // spectators too, exactly as OGS turns off its SGF download for
                // them (online-go.com src/lib/configure-goban.tsx:94-97).
                analysisDisabled: attempt(() => !!goban.isAnalysisDisabled(true), false),
                signedIn: !!user.id && !user.anonymous,
                liveSpectatingEnabled: ogsLiveSpectatingEnabled(),
            };
        }

        function refresh() {
            if (disposed) { return; }
            const engine = goban.engine;
            // At assignment the engine is a pre-gamedata placeholder; gamedata
            // arrives over the socket and `load` fires with the real one.
            if (!engine || !engine.move_tree) { return; }

            const verdict = ogsAccess(accessState());
            const refusal = verdict.allowed ? "" : OGS_REFUSAL;
            const built = gobanToSgf(engine);
            const sgf = built && built.sgf;
            boardWidth = (built && built.width) || boardWidth;

            if (!playerId) {
                lastSgf = sgf;
                lastRefusal = refusal;
                moveCount = (built && built.moveCount) || 0;
                playerId = hostApi.register(viewer, ogsAdapter.id);
                hostApi.kifu(playerId, { size: boardWidth, moveCount, sgfInline: lastSgf });
                postLine();
                return;
            }

            if (refusal !== lastRefusal) {
                lastRefusal = refusal;
                // A game that finishes while the reader watches becomes
                // analysable under them, so the verdict is a live value rather
                // than something read once at attach.
                hostApi.access(playerId, refusal || null);
                if (refusal) { viewer.clear(); }
            }

            if (sgf && sgf !== lastSgf) {
                // The record GREW (a demo its author is playing, a review whose
                // leading line was edited). Re-posting the kifu is what makes
                // both panels drop their results and re-`start` under the same
                // session key.
                lastSgf = sgf;
                moveCount = built.moveCount;
                hostApi.kifu(playerId, { size: boardWidth, moveCount, sgfInline: sgf });
            }
            postLine();
        }

        function postLine() {
            if (!playerId || disposed) { return; }
            const engine = goban.engine;
            const node = engine && engine.cur_move;
            if (!node) { return; }
            const line = readOgsLine(engine, node);
            if (line) { hostApi.update(playerId, line, null); return; }
            // An edit in the middle of the displayed line: the position exists
            // only in the page and cannot be replayed as a sequence of moves.
            // Report the shape both content scripts already understand.
            const depth = typeof node.getMoveIndex === "function" ? node.getMoveIndex() : 0;
            hostApi.update(playerId, null, { m: Number(depth) || 0, onMainline: false });
        }

        function readOgsLine(engine, node) {
            const chain = [];
            for (let n = node; n; n = n.parent) { chain.push(n); }
            chain.reverse();

            const moves = [];
            let onMainline = true;
            let sawMove = false;
            for (let i = 1; i < chain.length; i += 1) {
                const nd = chain[i];
                if (ogsMainChild(chain[i - 1]) !== nd) { onMainline = false; }
                if (nd.edited) {
                    // Leading edits are the setup gobanToSgf already folded into
                    // the root; anything later is not a playable position.
                    if (sawMove) { return null; }
                    continue;
                }
                sawMove = true;
                moves.push({
                    color: nd.player === 1 ? "b" : "w",
                    pass: nd.x === -1,
                    x: nd.x === -1 ? null : nd.x,   // 0 = left column
                    y: nd.x === -1 ? null : nd.y,   // 0 = TOP row
                });
            }

            return {
                size: boardWidth,
                nodeDepth: typeof node.getMoveIndex === "function" ? node.getMoveIndex()
                                                                  : moves.length,
                moveCount: moves.length,
                onMainline,
                mainlinePrefixMoves: onMainline ? moves.length : 0,
                edited: false,
                // colorToMove(), never playerToMove(): the latter returns a
                // PLAYER ID (goban src/engine/GobanEngine.ts:1194).
                turn: typeof engine.colorToMove === "function"
                    ? (engine.colorToMove() === "black" ? "b" : "w") : null,
                moves,
            };
        }

        function seek(move, mainline) {
            const engine = goban.engine;
            if (!engine || typeof engine.jumpTo !== "function") { return; }
            let node = engine.move_tree;
            let steps = Number(move) || 0;
            while (steps > 0) {
                const next = ogsMainChild(node);
                if (!next) { break; }
                node = next;
                steps -= 1;
            }
            try {
                engine.jumpTo(node);
                goban.redraw(true);
            } catch (e) { /* the chart's seek is a convenience, never a fault */ }
            postLine();
            // `mainline` is always true from the chart, and the walk above only
            // ever follows the main line — the parameter is accepted so every
            // viewer has the same signature.
            void mainline;
        }

        // ---- drawing -------------------------------------------------------
        //
        // Candidates ride goban's OWN public display state, so they are drawn
        // by the same code that draws the stones and survive OGS switching
        // between its SVG and canvas renderers. Ownership squares and the
        // candidate text have no such primitive — setHeatmap is a
        // single-colour intensity map and cannot say Black-vs-White — so they
        // go on an overlay canvas positioned from goban's own metrics.
        //
        // setMarks/setColoredMarks are never called: they write into the
        // review's move tree and are BROADCAST to every other participant over
        // the socket. Analysis nobody asked for must not appear on a stranger's
        // board.

        function paint() {
            pushCircles();
            paintOverlay();
        }

        function pushCircles() {
            const circles = [];
            for (const mark of (analysis.candidates || [])) {
                circles.push({
                    move: { x: mark.x, y: mark.y },
                    color: `hsla(${Math.round(mark.hue * 360)},100%,50%,${mark.dimmed ? 0.2 : 0.8})`,
                    border_color: mark.isBest ? "#007aff" : undefined,
                    // A FRACTION of the circle's radius, not a pixel width
                    // (goban src/Goban/SVGRenderer.ts:5367), and the radius is
                    // half a cell — so 0.125 is the app's cell/16 ring.
                    border_width: mark.isBest ? 0.125 : 0,
                });
            }
            try {
                goban.setColoredCircles(circles);
                // setColoredCircles([]) deletes the matrix and returns WITHOUT
                // redrawing (goban src/Goban/InteractiveBase.ts:1427-1431), so
                // clearing has to ask for the repaint itself.
                if (!circles.length) { goban.redraw(true); }
            } catch (e) { /* an older goban without the API: overlay only */ }
        }

        function ensureOverlay() {
            const parent = goban.parent;
            if (!parent) { return null; }
            if (!overlay || !overlay.isConnected) {
                overlay = document.createElement("canvas");
                overlay.style.position = "absolute";
                overlay.style.left = "0";
                overlay.style.top = "0";
                overlay.style.pointerEvents = "none";
                // A static parent would make "absolute" resolve against some
                // ancestor. Nudge it, and put it back on the way out — this is
                // the one page style the adapter touches.
                if (getComputedStyle(parent).position === "static") {
                    restoreParentPosition = parent.style.position;
                    parent.style.position = "relative";
                }
                parent.appendChild(overlay);
            }
            return overlay;
        }

        function paintOverlay() {
            const canvas = ensureOverlay();
            if (!canvas || typeof goban.computeMetrics !== "function") { return; }
            const metrics = goban.computeMetrics();
            if (canvas.width !== metrics.width) { canvas.width = metrics.width; }
            if (canvas.height !== metrics.height) { canvas.height = metrics.height; }
            const ctx = canvas.getContext("2d");
            if (!ctx) { return; }
            ctx.clearRect(0, 0, canvas.width, canvas.height);
            const cell = Number(goban.square_size) || 0;
            if (!(cell > 0)) { return; }
            // The inverse of goban's own xy2ij (goban
            // src/Goban/InteractiveBase.ts:603-621): a cropped board offsets by
            // its bounds, an uncropped one by whether labels are drawn, and the
            // two are mutually exclusive because cropping turns labels off.
            const bounds = goban.bounds || { left: 0, top: 0 };
            const left = Number(bounds.left) || 0;
            const top = Number(bounds.top) || 0;
            const labelX = left > 0 ? 0 : (goban.draw_left_labels ? 1 : 0);
            const labelY = top > 0 ? 0 : (goban.draw_top_labels ? 1 : 0);
            // Only the OWNERSHIP layer goes here — the candidate circles are
            // goban's own display state — plus the candidate text, which has to
            // sit above them.
            paintAnalysis(ctx, { ownership: analysis.ownership, candidates: null }, cell,
                          (x, y) => ({
                              cx: (x - left + labelX) * cell + metrics.mid,
                              cy: (y - top + labelY) * cell + metrics.mid,
                          }));
            for (const mark of (analysis.candidates || [])) {
                const lines = mark.dimmed ? [] : (mark.lines || []);
                if (!lines.length) { continue; }
                const cx = (mark.x - left + labelX) * cell + metrics.mid;
                const cy = (mark.y - top + labelY) * cell + metrics.mid;
                ctx.fillStyle = "#000000";
                ctx.textAlign = "center";
                ctx.textBaseline = "middle";
                const size = lines.length > 1 ? cell * 0.26 : cell * 0.4;
                ctx.font = "700 " + size.toFixed(1) + "px ui-monospace, Menlo, monospace";
                const step = cell * 0.27;
                const y0 = cy - step * (lines.length - 1) / 2;
                lines.forEach((text, i) => ctx.fillText(text, cx, y0 + i * step));
            }
        }

        function schedulePaint() {
            if (redrawTimer !== null) { return; }
            // Debounced: OGS's own AI review writes colored circles too, and
            // every write emits `update`. Re-applying ours on the trailing edge
            // keeps the two from ping-ponging a redraw each.
            redrawTimer = setTimeout(() => {
                redrawTimer = null;
                if (!disposed) { paint(); }
            }, 80);
        }

        // ---- wiring --------------------------------------------------------

        // `load` REPLACES goban.engine on every gamedata and every reconnect, so
        // nothing may hold on to an engine: re-read it, and re-evaluate the
        // access rule, on each of these.
        listen(goban, "load", refresh);
        listen(goban, "engine.updated", refresh);
        listen(goban, "review.load-end", refresh);
        listen(goban, "gamedata", refresh);
        listen(goban, "phase", refresh);
        listen(goban, "move-made", refresh);
        listen(goban, "cur_move", postLine);
        listen(goban, "update", schedulePaint);
        listen(goban, "destroy", dispose);

        try {
            observer = new ResizeObserver(() => schedulePaint());
            if (goban.parent) { observer.observe(goban.parent); }
        } catch (e) { /* `update` still covers a resize OGS knows about */ }

        refresh();

        function dispose() {
            if (disposed) { return; }
            disposed = true;
            if (redrawTimer !== null) { clearTimeout(redrawTimer); redrawTimer = null; }
            for (const off of unbinders) { off(); }
            unbinders.length = 0;
            if (observer) { try { observer.disconnect(); } catch (e) {} }
            try { goban.setColoredCircles([]); } catch (e) {}
            if (overlay && overlay.parentNode) { overlay.parentNode.removeChild(overlay); }
            overlay = null;
            if (restoreParentPosition !== null && goban.parent) {
                goban.parent.style.position = restoreParentPosition;
                restoreParentPosition = null;
            }
            // An SPA never fires `pagehide` between routes, so without this the
            // panel outlives its board: a dead shadow host, and on macOS a poll
            // that keeps the single-sweep `busy` guard armed against the next
            // game the reader opens.
            if (playerId) { hostApi.remove(playerId); playerId = null; }
        }

        return { dispose };
    }

    // ---- adapter dispatch --------------------------------------------------
    //
    // Adapters are probed at document_start — the only moment the WGo trap can
    // be installed before the page assigns window.WGo — and again as the
    // document fills in, because a DOM-shaped detect() sees nothing that early.
    // Each adapter attaches at most once.
    const adapters = [wgoAdapter, cyberoroAdapter, ogsAdapter];
    const attachedAdapters = new Set();

    function probeAdapters() {
        for (const adapter of adapters) {
            if (attachedAdapters.has(adapter.id)) { continue; }
            let ready = false;
            try { ready = !!adapter.detect(); } catch (e) { ready = false; }
            if (!ready) { continue; }
            attachedAdapters.add(adapter.id);
            try { adapter.attach(host); } catch (e) { /* never break the page */ }
        }
    }

    probeAdapters();
    if (document.readyState !== "complete") {
        document.addEventListener("DOMContentLoaded", probeAdapters, { once: true });
        window.addEventListener("load", probeAdapters, { once: true });
    }
})();
