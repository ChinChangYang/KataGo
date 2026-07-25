// Page-world hook (MAIN world, document_start). Traps WGo.BasicPlayer
// construction so the extension can reach player instances that pages keep in
// local variables (katagotraining.org's is created inside a load listener and
// never escapes). Zero footprint on pages that never assign WGo: one property
// trap, no timers, no DOM writes, no messages.
//
// Also injected as a fallback <script src> from the content script (Safari
// versions without manifest `world: "MAIN"`), so it must be idempotent.

(() => {
    "use strict";
    if (window.__kgaHooked) { return; }
    Object.defineProperty(window, "__kgaHooked", { value: true });

    const registry = [];          // { id, player, config, element }
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

    function describe(entry) {
        const config = entry.config || {};
        return {
            playerId: entry.id,
            sgfInline: typeof config.sgf === "string" ? config.sgf : null,
            sgfFile: typeof config.sgfFile === "string"
                ? new URL(config.sgfFile, location.href).href : null,
            hasJson: !!config.json,
        };
    }

    // ---- Player capture -------------------------------------------------

    function registerPlayer(player, elem, config) {
        const id = "kga-p" + registry.length;
        // One custom object carries BOTH analysis layers so z-order matches
        // the app's AnalysisView (ownership under candidates) — WGo draws
        // obj_arr marks before obj_list customs, so split layers would stack
        // wrong. `analysisState` is mutated in place; redraw() re-renders it.
        const entry = { id, player, config, element: (player && player.element) || elem,
                        analysisState: { ownership: null, candidates: null, registered: false } };
        registry.push(entry);
        post("playerFound", describe(entry));
        try {
            player.addEventListener("update", (ev) => {
                const line = readLine(player, ev && ev.node);
                post("playerUpdate", {
                    playerId: id,
                    path: sanitizePath(line, ev && ev.path),
                    line,
                });
            });
            player.addEventListener("kifuLoaded", (ev) => {
                const kifu = ev && ev.kifu;
                post("kifuLoaded", {
                    playerId: id,
                    size: kifu && kifu.size,
                    moveCount: countMainline(kifu),
                });
            });
        } catch (e) { /* older forks without addEventListener: chart-only mode */ }
        // Post-hoc attach (declarative players): the kifu is already loaded
        // and the viewer may sit mid-game (data-wgo-move) — synthesize the
        // events the live listeners just missed.
        try {
            if (player.kifu) {
                post("kifuLoaded", {
                    playerId: id,
                    size: player.kifu.size,
                    moveCount: countMainline(player.kifu),
                });
                const path = player.kifuReader && player.kifuReader.path;
                if (path) {
                    const line = readLine(player);
                    post("playerUpdate", {
                        playerId: id,
                        path: sanitizePath(line, path),
                        line,
                    });
                }
            }
        } catch (e) { /* state snapshot is best-effort */ }
    }

    // WGo's declarative path (`<div data-wgo=…>`) constructs BasicPlayer via a
    // closure-local reference the property trap never sees, but it stamps the
    // instance on `element._wgo_player` — scan for those after load. The
    // data-wgo attribute holds either inline SGF ("(…") or an SGF URL.
    function attachDeclarativePlayers() {
        let found = false;
        for (const elem of document.querySelectorAll("[data-wgo]")) {
            const player = elem._wgo_player;
            if (!player || registry.some((entry) => entry.player === player)) { continue; }
            const raw = (elem.getAttribute("data-wgo") || "").trim();
            const config = Object.assign(
                raw.startsWith("(") ? { sgf: raw } : (raw ? { sgfFile: raw } : {}),
                player.config || {});
            registerPlayer(player, elem, config);
            found = true;
        }
        return found;
    }

    function scheduleDeclarativeScan() {
        // Load-time plus two retries covers static pages and slow inits;
        // constructor-trapped sites never reach here with work to do.
        const scan = () => { try { attachDeclarativePlayers(); } catch (e) {} };
        if (document.readyState === "complete") { scan(); }
        else { window.addEventListener("load", () => setTimeout(scan, 0), { once: true }); }
        setTimeout(scan, 1500);
        setTimeout(scan, 5000);
    }
    scheduleDeclarativeScan();

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

    // Legacy shape, still posted alongside the line so the macOS content script
    // (which shares this file byte-for-byte) keeps working unchanged. Derived
    // from the walk above, so it inherits the corrected `onMainline`.
    function sanitizePath(line, path) {
        if (line) { return { m: line.nodeDepth, onMainline: line.onMainline }; }
        if (!path || typeof path !== "object") { return { m: 0, onMainline: true }; }
        let onMainline = true;
        for (const key of Object.keys(path)) {
            if (key !== "m" && Number(path[key])) { onMainline = false; break; }
        }
        return { m: Number(path.m) || 0, onMainline };
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

    function wrapBasicPlayer(WGoObj) {
        if (!WGoObj || WGoObj.__kgaWrapped) { return WGoObj; }
        const trap = (Orig) => {
            function BasicPlayer(elem, config) {
                const inst = Reflect.construct(Orig, [elem, config], new.target || BasicPlayer);
                try { registerPlayer(inst, elem, config); } catch (e) { /* never break the page */ }
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
    } catch (e) { /* property locked: late path below still covers it */ }
    if (existing) { window.WGo = existing; }

    // ---- Commands from the content script -------------------------------

    function entryFor(playerId) {
        return registry.find((entry) => entry.id === playerId) || null;
    }

    function handleCommand(type, payload) {
        const entry = payload && entryFor(payload.playerId);
        if (!entry) { return; }
        const board = entry.player && entry.player.board;
        switch (type) {
            case "goTo": {
                if (entry.player.frozen) { return; }
                const move = Number(payload.moveIndex);
                if (!Number.isFinite(move)) { return; }
                // `mainline` means "move n OF THE GAME", which player.goTo(n)
                // cannot do from inside a variation — see mainlinePath.
                entry.player.goTo(payload.mainline
                    ? mainlinePath(entry.player, move)
                    : move);
                return;
            }
            case "drawAnalysis": {
                if (!board || typeof board.addCustomObject !== "function") { return; }
                const state = entry.analysisState;
                state.ownership = Array.isArray(payload.ownership) ? payload.ownership : null;
                state.candidates = Array.isArray(payload.candidates) ? payload.candidates.slice(0, 50) : null;
                if (!state.registered) {
                    board.addCustomObject(analysisHandler, state);
                    state.registered = true;
                } else {
                    try { board.redraw(); } catch (e) {}
                }
                return;
            }
            case "clearOverlays": {
                if (!board) { return; }
                entry.analysisState.ownership = null;
                entry.analysisState.candidates = null;
                try { board.redraw(); } catch (e) {}
                return;
            }
        }
    }

    // Both analysis layers in ONE custom object, drawn in AnalysisView's
    // z-order: ownership squares first, candidate circles on top. Custom
    // handlers MUST be layer-keyed — WGo's redraw does
    // `for (d in handler) handler[d].draw.call(board[d].getContext(...))`,
    // so a flat {draw} makes board["draw"].getContext throw (swallowed by
    // WGo's try/catch) and nothing paints. Visual constants mirror
    // AnalysisView: full-cell circles at 0.8 alpha (0.2 dimmed), a
    // cell/16-wide systemBlue ring on the best candidate, black bold
    // monospaced text, grayscale ownership squares sized by `scale`.
    const analysisHandler = {
        stone: {
            draw(state, board) {
                // Cell size from coordinate deltas — board.fieldWidth is not
                // present on every WGo build (NaN would draw nothing).
                const cell = board.size > 1
                    ? Math.abs(board.getX(1) - board.getX(0))
                    : board.stoneRadius * 2;

                for (const own of state.ownership || []) {
                    const side = cell * own.scale;
                    if (!(side > 0)) { continue; }
                    const v = Math.round(255 * Math.min(1, Math.max(0, own.whiteness)));
                    this.fillStyle = `rgba(${v},${v},${v},${own.opacity})`;
                    const cx = board.getX(own.x);
                    const cy = board.getY(own.y);
                    this.fillRect(cx - side / 2, cy - side / 2, side, side);
                }

                for (const mark of state.candidates || []) {
                    const x = board.getX(mark.x);
                    const y = board.getY(mark.y);
                    const r = cell / 2;
                    this.beginPath();
                    this.arc(x, y, r, 0, 2 * Math.PI);
                    // HSB(h,1,1) == HSL(h,100%,50%): the app's exact ramp.
                    this.fillStyle = `hsla(${Math.round(mark.hue * 360)},100%,50%,${mark.dimmed ? 0.2 : 0.8})`;
                    this.fill();
                    if (mark.isBest) {
                        this.beginPath();
                        this.arc(x, y, r - cell / 32, 0, 2 * Math.PI);
                        this.strokeStyle = "#007aff";
                        this.lineWidth = cell / 16;
                        this.stroke();
                    }
                    const lines = mark.dimmed ? [] : (mark.lines || []);
                    if (lines.length) {
                        this.fillStyle = "#000000";
                        this.textAlign = "center";
                        this.textBaseline = "middle";
                        const size = lines.length > 1 ? cell * 0.26 : cell * 0.4;
                        this.font = "700 " + size.toFixed(1) + "px ui-monospace, Menlo, monospace";
                        const step = cell * 0.27;
                        const y0 = y - step * (lines.length - 1) / 2;
                        lines.forEach((line, i) => this.fillText(line, x, y0 + i * step));
                    }
                }
            },
        },
    };
})();
