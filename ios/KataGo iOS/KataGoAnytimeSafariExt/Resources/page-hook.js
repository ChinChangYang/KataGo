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
                post("playerUpdate", { playerId: id, path: sanitizePath(ev && ev.path) });
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
    }

    function sanitizePath(path) {
        if (!path || typeof path !== "object") { return { m: 0, onMainline: true }; }
        let onMainline = true;
        for (const key of Object.keys(path)) {
            if (key !== "m" && Number(path[key])) { onMainline = false; break; }
        }
        return { m: Number(path.m) || 0, onMainline };
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
                if (Number.isFinite(move)) { entry.player.goTo(move); }
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
