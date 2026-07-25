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

    async function native(message) {
        // A native message can fail transiently on iOS when the non-persistent
        // background page was torn down between calls; one retry absorbs it.
        try {
            const reply = await browser.runtime.sendMessage({ kgaNative: message });
            if (reply && reply.kgaError) { throw new Error(reply.kgaError); }
            return reply;
        } catch (first) {
            await new Promise((resolve) => setTimeout(resolve, 300));
            const reply = await browser.runtime.sendMessage({ kgaNative: message });
            if (reply && reply.kgaError) { throw new Error(reply.kgaError); }
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
            this.results = new Map();     // moveIndex → result
            // Lifecycle only. Whether analysis is ON and whether a scan is
            // running are ORTHOGONAL to it (and to each other): the Analyze
            // toggle governs per-scrub analysis + board marks, while Scan game
            // fills the chart independently.
            this.state = "idle";          // idle|starting|ready|error
            this.analysisEnabled = false;
            this.scanning = false;
            this.inFlight = false;        // one native analyze at a time
            this.pendingIndex = null;     // latest scrub while a request is out
            this.scanIndex = 0;
            this.showCandidates = true;
            // Engine identity, learned from replies. Version stays null until an
            // engine has actually booted — it is never persisted, so the panel
            // cannot claim a version for an engine that never ran.
            this.engineVersion = null;
            this.engineModel = null;
            this.buildPanel();
            window.addEventListener("pagehide", () => this.teardown());
        }

        // ---- panel DOM ---------------------------------------------------

        buildPanel() {
            const host = document.createElement("katago-anytime-panel");
            host.style.display = "block";
            const anchor = document.querySelector(".wgo-player-main") || document.body;
            (anchor.parentNode || document.body).insertBefore(host, anchor.nextSibling);
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
@media (prefers-color-scheme: dark) {
  .kga-root {
    --kga-bg: #1c1c1e; --kga-ink: #f2f2f7; --kga-ink-muted: #98989d;
    --kga-grid: #3a3a3c; --kga-winrate: #409cff; --kga-score: #da8fff;
    --kga-cursor: #f2f2f7; --kga-hatch: rgba(152,152,157,0.14);
  }
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
.kga-bar button, .kga-bar select {
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
/* Narrow phones: stack the controls under the buttons. */
@media (max-width: 420px) {
  .kga-controls { margin-left: 0; width: 100%; }
  .kga-chart { height: 100px; }
}
</style>
<div class="kga-root">
  <div class="kga-bar">
    <button class="kga-logo" type="button" aria-expanded="false"
            aria-label="Engine details">◉ KataGo<span class="kga-chev">▾</span></button>
    <button class="kga-analyze kga-primary">Analyze</button>
    <span class="kga-winrate-readout"></span>
    <span class="kga-progress" hidden></span>
    <div class="kga-controls">
      <label class="kga-toggle"><input type="checkbox" class="kga-cands" checked>Marks</label>
      <span class="kga-pass" hidden></span>
      <select class="kga-budget">
        <option value="fast">Fast</option>
        <option value="normal" selected>Normal</option>
        <option value="deep">Deep</option>
      </select>
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
                logo: root.querySelector(".kga-logo"),
                details: root.querySelector(".kga-details"),
                ver: root.querySelector(".kga-ver"),
                model: root.querySelector(".kga-model"),
                analyze: root.querySelector(".kga-analyze"),
                readout: root.querySelector(".kga-winrate-readout"),
                progress: root.querySelector(".kga-progress"),
                candsToggle: root.querySelector(".kga-cands"),
                pass: root.querySelector(".kga-pass"),
                budget: root.querySelector(".kga-budget"),
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
                onSeek: (index) => postToPage("goTo", { playerId: this.playerId, moveIndex: index }),
                onHover: (index) => this.showTip(index),
            });
            new ResizeObserver(() => this.chart.draw()).observe(this.el.canvas);

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
            if (index === null || !this.results.has(index)) { this.el.tip.hidden = true; return; }
            const r = this.results.get(index);
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
            this.currentIndex = path.m;
            this.onMainline = path.onMainline;
            this.chart.setCursor(path.m, path.onMainline);
            this.message(this.onMainline ? "" : "Viewing a variation — analysis follows the main line.");
            this.pushOverlays();
            // Lazy fill: the position the reader just moved to is the one we
            // analyze, and plotting it is what grows the chart over time. With
            // analysis off this is skipped entirely — no engine work, no marks.
            if (this.state === "ready" && this.onMainline && this.analysisEnabled) {
                this.requestPosition(path.m);
            }
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
            this.requestPosition(this.onMainline ? this.currentIndex : 0);
        }

        disableAnalysis() {
            this.analysisEnabled = false;
            this.pendingIndex = null;
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
                    budget: this.el.budget.value,
                });
                this.noteEngineInfo(accepted);
                if (accepted.type === "error") { this.onWireError(accepted); return false; }
                this.moveCount = accepted.moveCount;
                this.boardSize = accepted.boardWidth;
                if (!this.results.size) { this.chart.setGame(accepted.moveCount); }
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
        async requestPosition(index) {
            if (this.state !== "ready") { return; }
            // Engine work happens only for an enabled toggle or a running scan.
            if (!this.analysisEnabled && !this.scanning) { return; }
            // Already known: render locally, never spend an appex round-trip.
            if (this.results.has(index)) {
                this.pushOverlays();
                // Keep a scan moving if this call came from a scrub; when a
                // request is already out its own drain advances the scan.
                if (this.scanning && !this.inFlight) { this.scanStep(); }
                return;
            }
            if (this.inFlight) { this.pendingIndex = index; return; }

            this.inFlight = true;
            let deferred = false;   // a retry owns inFlight; skip the drain
            try {
                const reply = await native({
                    cmd: "query", gameId: this.sgfHash, moveIndex: index,
                    want: ["candidates"], budget: this.el.budget.value,
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
                            this.resume(index);
                        }, 1000);
                        return;
                    }
                    if (reply.code === "unknownGame") {
                        // Fresh appex process: re-`start` is idempotent and the
                        // native cache still holds prior results.
                        this.state = "idle";
                        deferred = true;
                        this.inFlight = false;
                        if (await this.ensureStarted()) { this.resume(index); }
                        return;
                    }
                    this.onWireError(reply);
                    return;
                }
                this.message("");
                // Merge unconditionally — the result is pure data that was
                // already computed and cached natively, and pushOverlays()
                // declines to draw marks while analysis is off.
                this.mergeResults(reply.moves);
            } catch (error) {
                // A transport failure on a scan would otherwise retry the same
                // index forever; stop the scan and let the user restart it.
                if (this.scanning) { this.stopScan(); }
                if (this.analysisEnabled) { this.disableAnalysis(); }
                this.message("Analysis stopped — tap Analyze to try again.", true);
            } finally {
                if (!deferred) {
                    this.inFlight = false;
                    // ALWAYS drain: a parked index is a position request, not
                    // analysis-toggle state. Gating this on a generation token
                    // stalled any running scan (and left the button reading
                    // "Analyzing" with nothing running) whenever the toggle moved.
                    const next = this.pendingIndex;
                    this.pendingIndex = null;
                    if (next !== null) { this.resume(next); }
                    else if (this.scanning) { this.scanStep(); }
                }
            }
        }

        /// Re-enter requestPosition only if the session still wants work.
        /// requestPosition's own guards would reject it anyway; this keeps the
        /// intent explicit at every deferred/scheduled re-entry point.
        resume(index) {
            if (this.analysisEnabled || this.scanning) { this.requestPosition(index); }
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
            while (this.scanIndex <= this.moveCount && this.results.has(this.scanIndex)) {
                this.scanIndex += 1;
            }
            this.el.progress.textContent = `${this.results.size} / ${this.moveCount + 1}`;
            if (this.scanIndex > this.moveCount) { return this.stopScan(); }
            this.requestPosition(this.scanIndex);
        }

        mergeResults(moves) {
            for (const move of moves || []) { this.results.set(move.moveIndex, move); }
            this.chart.merge(Array.from(this.results.values()), this.computeBadges());
            this.pushOverlays();
        }

        computeBadges() {
            // Winrate drop from the MOVER's perspective, derived from adjacent
            // analyzed positions. With lazy fill most neighbours are missing,
            // so a badge only appears once both sides of a move are analyzed.
            const badges = [];
            for (const [index, r] of this.results) {
                const before = this.results.get(index - 1);
                if (!before) { continue; }
                const mover = before.toMove;   // side that played move `index`
                const drop = mover === "w" ? (r.winrateB - before.winrateB)
                                           : (before.winrateB - r.winrateB);
                if (drop >= 0.12) { badges.push({ moveIndex: index, severity: "major" }); }
                else if (drop >= 0.06) { badges.push({ moveIndex: index, severity: "minor" }); }
            }
            return badges;
        }

        pushOverlays() {
            const current = this.results.get(this.onMainline ? this.currentIndex : -1);
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
                    cmd: "openInApp", sgf: withGameName(sgf, document.title),
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

        onWireError(reply) {
            this.state = "error";
            this.analysisEnabled = false;
            this.scanning = false;
            this.el.analyze.textContent = "Analyze";
            this.el.scan.textContent = "Scan game";
            this.el.progress.hidden = true;
            const friendly = {
                boardTooLarge: "Boards larger than 19×19 aren't supported in Safari.",
                warmingUp: "Starting the analysis engine…",
                sgfParse: "This game's SGF could not be read.",
                engineDown: "Analysis is unavailable — tap Analyze to retry.",
                unknownGame: "Restarting analysis…",
            };
            this.message(friendly[reply.code] || reply.message || "Analysis failed.",
                         reply.code !== "warmingUp");
        }

        teardown() {
            if (this.sgfHash) {
                native({ cmd: "stop", gameId: this.sgfHash }).catch(() => {});
            }
        }
    }
})();
