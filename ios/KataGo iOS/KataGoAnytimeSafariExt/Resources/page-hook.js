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
        const entry = { id, player, config, element: (player && player.element) || elem,
                        overlays: { candidates: [], ownershipHandler: null, ownershipArgs: null } };
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
            case "drawCandidates": {
                if (!board || typeof board.addObject !== "function") { return; }
                clearCandidates(entry, board);
                const marks = Array.isArray(payload.marks) ? payload.marks.slice(0, 12) : [];
                for (const mark of marks) {
                    const obj = {
                        x: Number(mark.x), y: Number(mark.y),
                        type: candidateHandler,
                        kgaLabel: String(mark.label || ""),
                        kgaRank: Number(mark.rank) || 0,
                        kgaStrength: Math.max(0, Math.min(1, Number(mark.strength) || 0)),
                    };
                    if (!Number.isFinite(obj.x) || !Number.isFinite(obj.y)) { continue; }
                    board.addObject(obj);
                    entry.overlays.candidates.push(obj);
                }
                return;
            }
            case "drawOwnership": {
                if (!board || typeof board.addCustomObject !== "function") { return; }
                clearOwnership(entry, board);
                const values = Array.isArray(payload.values) ? payload.values.map(Number) : [];
                const args = { values, width: Number(payload.width), height: Number(payload.height) };
                board.addCustomObject(ownershipHandler, args);
                entry.overlays.ownershipHandler = ownershipHandler;
                entry.overlays.ownershipArgs = args;
                return;
            }
            case "clearOverlays": {
                if (!board) { return; }
                clearCandidates(entry, board);
                clearOwnership(entry, board);
                return;
            }
        }
    }

    function clearCandidates(entry, board) {
        for (const obj of entry.overlays.candidates) {
            try { board.removeObject(obj); } catch (e) {}
        }
        entry.overlays.candidates = [];
    }

    function clearOwnership(entry, board) {
        if (entry.overlays.ownershipHandler && typeof board.removeCustomObject === "function") {
            try { board.removeCustomObject(entry.overlays.ownershipHandler, entry.overlays.ownershipArgs); } catch (e) {}
        }
        entry.overlays.ownershipHandler = null;
        entry.overlays.ownershipArgs = null;
        try { board.redraw(); } catch (e) {}
    }

    // Candidate badge: filled disc scaled by strength, best move accented,
    // top ranks carry a small winrate label. Draw handlers run with the 2D
    // context as `this` (WGo convention) and are auto-redrawn on resize.
    const candidateHandler = {
        stone: {
            draw(args, board) {
                const x = board.getX(args.x);
                const y = board.getY(args.y);
                const r = board.stoneRadius * (0.55 + 0.35 * args.kgaStrength);
                this.beginPath();
                this.arc(x, y, r, 0, 2 * Math.PI);
                this.fillStyle = args.kgaRank === 0
                    ? "rgba(10,132,255,0.85)"
                    : "rgba(10,132,255," + (0.25 + 0.35 * args.kgaStrength) + ")";
                this.fill();
                if (args.kgaLabel && args.kgaRank < 3) {
                    this.fillStyle = args.kgaRank === 0 ? "#ffffff" : "rgba(0,0,0,0.75)";
                    this.font = Math.round(board.stoneRadius * 0.78) + "px -apple-system, sans-serif";
                    this.textAlign = "center";
                    this.textBaseline = "middle";
                    this.fillText(args.kgaLabel, x, y);
                }
            },
        },
    };

    // Ownership heatmap: ONE custom object painting the whole grid in a
    // single canvas pass; stones get a dimmed ring instead of a full square
    // so the position stays readable. White-positive values (engine order:
    // top-left, row-major).
    const ownershipHandler = {
        draw(args, board) {
            if (!args || !Array.isArray(args.values)) { return; }
            const w = args.width, h = args.height;
            if (!Number.isFinite(w) || !Number.isFinite(h)) { return; }
            const fw = board.fieldWidth * 0.92;
            const fh = board.fieldHeight * 0.92;
            for (let gy = 0; gy < h; gy += 1) {
                for (let gx = 0; gx < w; gx += 1) {
                    const v = args.values[gy * w + gx];
                    if (!Number.isFinite(v) || Math.abs(v) < 0.1) { continue; }
                    const alpha = Math.min(0.55, Math.abs(v) * 0.55);
                    this.fillStyle = v > 0
                        ? "rgba(255,255,255," + alpha + ")"
                        : "rgba(0,0,0," + alpha + ")";
                    const cx = board.getX(gx);
                    const cy = board.getY(gy);
                    this.fillRect(cx - fw / 2, cy - fh / 2, fw, fh);
                }
            }
        },
    };
})();
