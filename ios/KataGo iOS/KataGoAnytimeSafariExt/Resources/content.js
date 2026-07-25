// Isolated-world content script: bridges the page hook, owns the analysis
// panel (shadow DOM) and the session with the native side. The content
// script drives polling — a tab lives exactly as long as its page, so no
// background-lifetime bookkeeping is needed; the background is a stateless
// native-messaging relay. Every native message is self-contained and results
// are idempotent by moveIndex, so an appex restart mid-sweep only costs a
// re-`start` (served from the native App Group cache).

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
        const reply = await browser.runtime.sendMessage({ kgaNative: message });
        if (reply && reply.kgaError) { throw new Error(reply.kgaError); }
        return reply;
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

    // Matches the app's SI-formatted visits text (convertToSIUnits).
    function siVisits(visits) {
        if (visits >= 1e9) { return (visits / 1e9).toFixed(1).replace(/\.0$/, "") + "G"; }
        if (visits >= 1e6) { return (visits / 1e6).toFixed(1).replace(/\.0$/, "") + "M"; }
        if (visits >= 1e3) { return (visits / 1e3).toFixed(1).replace(/\.0$/, "") + "k"; }
        return String(visits);
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
            this.results = new Map();     // moveIndex → latest result
            this.sinceSeq = 0;
            this.sweep = { done: 0, total: 0 };
            this.state = "idle";          // idle|starting|sweeping|done|error
            this.pollTimer = null;
            this.showCandidates = true;
            this.showOwnership = true;    // app parity: defaultShowOwnership
            this.mode = "all";            // app parity: defaultAnalysisInformation = All
            this.buildPanel();
            browser.storage.local.get("kgaMode").then(({ kgaMode }) => {
                if (["winrate", "score", "all"].includes(kgaMode)) {
                    this.mode = kgaMode;
                    this.el.mode.value = kgaMode;
                    this.pushOverlays();
                }
            }).catch(() => {});
            window.addEventListener("pagehide", () => this.teardown());
        }

        // ---- panel DOM ---------------------------------------------------

        buildPanel() {
            const host = document.createElement("katago-anytime-panel");
            host.style.display = "block";
            // Prefer sitting right under the player; fall back to body-end.
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
.kga-bar { display: flex; align-items: center; gap: 10px; flex-wrap: wrap; }
.kga-logo { font-weight: 600; }
.kga-bar button {
  font: inherit; color: var(--kga-accent); background: transparent;
  border: 1px solid var(--kga-accent); border-radius: 7px;
  padding: 3px 12px; cursor: pointer;
}
.kga-bar button.kga-primary { color: #fff; background: var(--kga-accent); }
.kga-controls { display: flex; align-items: center; gap: 10px; margin-left: auto; flex-wrap: wrap; }
.kga-toggle { display: inline-flex; align-items: center; gap: 4px; color: var(--kga-ink-muted); cursor: pointer; }
.kga-toggle input { accent-color: var(--kga-accent); }
.kga-budget, .kga-mode { font: inherit; }
.kga-pass { display: inline-flex; align-items: center; gap: 4px; color: var(--kga-ink-muted); font-variant-numeric: tabular-nums; }
.kga-pass-dot { width: 12px; height: 12px; border-radius: 6px; display: inline-block; }
.kga-progress { color: var(--kga-ink-muted); font-variant-numeric: tabular-nums; }
.kga-chart-wrap { position: relative; margin-top: 10px; }
.kga-chart-wrap[hidden] { display: none; }
.kga-chart { display: block; width: 100%; height: 160px; touch-action: none; cursor: crosshair; }
.kga-axis { display: flex; justify-content: space-between; color: var(--kga-ink-muted); font-size: 11px; }
.kga-tip {
  position: absolute; pointer-events: none; background: var(--kga-bg);
  border: 1px solid var(--kga-grid); border-radius: 6px; padding: 4px 8px;
  font-size: 11px; white-space: nowrap; transform: translate(-50%, -100%);
  top: 0; box-shadow: 0 2px 8px rgba(0,0,0,0.12);
}
.kga-msg { margin-top: 8px; color: var(--kga-ink-muted); }
.kga-msg.kga-error { color: var(--kga-badge); }
</style>
<div class="kga-root">
  <div class="kga-bar">
    <span class="kga-logo">◉ KataGo</span>
    <button class="kga-analyze kga-primary">Analyze</button>
    <span class="kga-progress" hidden></span>
    <div class="kga-controls">
      <label class="kga-toggle"><input type="checkbox" class="kga-cands" checked>Candidates</label>
      <label class="kga-toggle"><input type="checkbox" class="kga-own" checked>Ownership</label>
      <select class="kga-mode">
        <option value="winrate">Winrate</option>
        <option value="score">Score</option>
        <option value="all" selected>All</option>
      </select>
      <span class="kga-pass" hidden></span>
      <select class="kga-budget">
        <option value="fast">Fast</option>
        <option value="normal" selected>Normal</option>
        <option value="deep">Deep</option>
      </select>
      <button class="kga-open">Open in KataGo Anytime</button>
    </div>
  </div>
  <div class="kga-chart-wrap" hidden>
    <canvas class="kga-chart"></canvas>
    <div class="kga-axis"><span>0</span><span class="kga-axis-max"></span></div>
    <div class="kga-tip" hidden></div>
  </div>
  <div class="kga-msg" hidden></div>
</div>`;
            this.el = {
                analyze: root.querySelector(".kga-analyze"),
                progress: root.querySelector(".kga-progress"),
                candsToggle: root.querySelector(".kga-cands"),
                ownToggle: root.querySelector(".kga-own"),
                mode: root.querySelector(".kga-mode"),
                pass: root.querySelector(".kga-pass"),
                budget: root.querySelector(".kga-budget"),
                open: root.querySelector(".kga-open"),
                chartWrap: root.querySelector(".kga-chart-wrap"),
                canvas: root.querySelector(".kga-chart"),
                axisMax: root.querySelector(".kga-axis-max"),
                tip: root.querySelector(".kga-tip"),
                msg: root.querySelector(".kga-msg"),
            };
            this.chart = new KGAChart(this.el.canvas, {
                onSeek: (index) => postToPage("goTo", { playerId: this.playerId, moveIndex: index }),
                onHover: (index) => this.showTip(index),
            });
            new ResizeObserver(() => this.chart.draw()).observe(this.el.canvas);

            this.el.analyze.addEventListener("click", () => {
                if (this.state === "sweeping" || this.state === "starting") { this.stop(); }
                else { this.analyze(); }
            });
            this.el.open.addEventListener("click", () => this.openInApp());
            this.el.candsToggle.addEventListener("change", () => {
                this.showCandidates = this.el.candsToggle.checked;
                this.pushOverlays();
            });
            this.el.ownToggle.addEventListener("change", () => {
                this.showOwnership = this.el.ownToggle.checked;
                this.pushOverlays();
            });
            this.el.mode.addEventListener("change", () => {
                this.mode = this.el.mode.value;
                browser.storage.local.set({ kgaMode: this.mode }).catch(() => {});
                this.pushOverlays();
            });
        }

        message(text, isError) {
            this.el.msg.hidden = !text;
            this.el.msg.textContent = text || "";
            this.el.msg.classList.toggle("kga-error", !!isError);
        }

        showTip(index) {
            if (index === null || !this.results.has(index)) { this.el.tip.hidden = true; return; }
            const r = this.results.get(index);
            const wr = (r.winrateB * 100).toFixed(1);
            const score = (r.scoreLeadB >= 0 ? "B+" : "W+") + Math.abs(r.scoreLeadB).toFixed(1);
            this.el.tip.textContent = `Move ${index} · Black ${wr}% · ${score} · ${r.visits} visits`;
            this.el.tip.hidden = false;
            const l = this.chart.layout();
            this.el.tip.style.left = this.chart.xFor(index, l) + "px";
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
            if (this.state === "sweeping" || this.state === "done") {
                if (this.onMainline) {
                    native({ cmd: "navigate", gameId: this.sgfHash, moveIndex: path.m }).catch(() => {});
                }
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

        async analyze() {
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
                if (accepted.type === "error") { return this.onWireError(accepted); }
                this.moveCount = accepted.moveCount;
                this.boardSize = accepted.boardWidth;
                this.sweep = { done: 0, total: accepted.moveCount + 1 };
                if (!this.results.size) { this.chart.setGame(accepted.moveCount); }
                this.el.axisMax.textContent = String(accepted.moveCount);
                this.el.chartWrap.hidden = false;
                this.chart.setCursor(this.currentIndex, this.onMainline);
                this.state = "sweeping";
                this.el.analyze.textContent = "Stop";
                this.el.progress.hidden = false;
                if (accepted.cached) { this.sinceSeq = 0; }
                this.schedulePoll(200);
            } catch (error) {
                this.state = "error";
                this.el.analyze.textContent = "Analyze";
                this.message(String(error && error.message || error), true);
            }
        }

        schedulePoll(delay) {
            clearTimeout(this.pollTimer);
            this.pollTimer = setTimeout(() => this.poll(), delay);
        }

        async poll() {
            if (this.state !== "sweeping") { return; }
            if (document.hidden) { this.schedulePoll(2000); return; }
            try {
                const reply = await native({
                    cmd: "poll", gameId: this.sgfHash, sinceSeq: this.sinceSeq,
                });
                if (reply.type === "error") {
                    if (reply.code === "unknownGame") {
                        // Fresh appex process: restart is idempotent and served
                        // from the native cache.
                        this.sinceSeq = 0;
                        this.state = "idle";
                        return this.analyze();
                    }
                    return this.onWireError(reply);
                }
                this.sinceSeq = reply.nextSeq;
                this.sweep = reply.sweep;
                this.mergeResults(reply.moves);
                this.el.progress.textContent = `${reply.sweep.done} / ${reply.sweep.total}`;
                if (reply.sweep.done >= reply.sweep.total) {
                    this.state = "done";
                    this.el.analyze.textContent = "Re-analyze";
                    this.el.progress.hidden = true;
                } else {
                    this.schedulePoll(500);
                }
            } catch (error) {
                // Relay/appex hiccup: retry with backoff, the protocol resumes.
                this.schedulePoll(2000);
            }
        }

        mergeResults(moves) {
            for (const move of moves || []) {
                this.results.set(move.moveIndex, move);
            }
            const flat = Array.from(this.results.values());
            this.chart.merge(flat, this.computeBadges());
            this.pushOverlays();
        }

        computeBadges() {
            // Winrate drop from the MOVER's perspective, derived from adjacent
            // analyzed positions; recomputed from the store every merge so
            // out-of-order delivery stays consistent.
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

        // Candidate text exactly as AnalysisView shows it (side-to-move
        // perspective, app formats): "57%", "+3", or all three stacked.
        candidateLines(candidate, toMove) {
            const wr = toMove === "w" ? 1 - candidate.winrateB : candidate.winrateB;
            const score = toMove === "w" ? -candidate.scoreLeadB : candidate.scoreLeadB;
            const wrText = Math.round(wr * 100) + "%";
            const scoreText = (score >= 0 ? "+" : "-") + Math.abs(Math.round(score));
            if (this.mode === "winrate") { return [wrText]; }
            if (this.mode === "score") { return [scoreText]; }
            return [wrText, siVisits(candidate.visits), scoreText];
        }

        pushOverlays() {
            const current = this.results.get(this.onMainline ? this.currentIndex : -1);
            const payload = { playerId: this.playerId, candidates: null, ownership: null };
            let passMark = null;

            if (this.showCandidates && current && current.candidates.length) {
                const maxVisits = Math.max(...current.candidates.map((c) => c.visits));
                const maxLcb = Math.max(...current.candidates.map((c) => c.utilityLcb));
                payload.candidates = [];
                for (const candidate of current.candidates) {
                    const dimmed = candidate.visits < HIDDEN_VISIT_RATIO * maxVisits;
                    const mark = {
                        hue: analysisBaseHue(candidate.visits, maxVisits),
                        dimmed,
                        isBest: candidate.utilityLcb === maxLcb,
                        lines: dimmed ? [] : this.candidateLines(candidate, current.toMove),
                    };
                    const point = vertexToBoard(candidate.move, this.boardSize);
                    if (point) {
                        payload.candidates.push({ ...mark, x: point.x, y: point.y });
                    } else if (candidate.move.toLowerCase() === "pass" && !dimmed) {
                        passMark = mark;   // the board has no pass point — panel chip
                    }
                }
            }
            if (this.showOwnership && current && current.ownership) {
                payload.ownership = current.ownership;
            }
            postToPage("drawAnalysis", payload);

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

        async stop() {
            clearTimeout(this.pollTimer);
            this.state = "idle";
            this.el.analyze.textContent = "Analyze";
            this.el.progress.hidden = true;
            if (this.sgfHash) {
                native({ cmd: "stop", gameId: this.sgfHash }).catch(() => {});
            }
        }

        async openInApp() {
            try {
                const sgf = await this.obtainSgf();
                const reply = await native({
                    cmd: "openInApp", sgf: withGameName(sgf, document.title),
                });
                if (reply.type === "error") { return this.onWireError(reply); }
                this.message("Opened in KataGo Anytime.");
            } catch (error) {
                this.message(String(error && error.message || error), true);
            }
        }

        onWireError(reply) {
            this.state = "error";
            clearTimeout(this.pollTimer);
            this.el.analyze.textContent = "Analyze";
            this.el.progress.hidden = true;
            const friendly = {
                boardTooLarge: "Boards larger than 19×19 aren't supported yet.",
                busy: "Another game is being analyzed — try again in a moment.",
                warmingUp: "Preparing the neural network (first run takes a few minutes)…",
                sgfParse: "This game's SGF could not be read.",
                engineDown: "The analysis engine stopped — press Analyze to retry.",
            };
            this.message(friendly[reply.code] || reply.message || "Analysis failed.",
                         reply.code !== "warmingUp");
            if (reply.retryable && reply.code === "busy") { this.schedulePoll(5000); }
        }

        teardown() {
            clearTimeout(this.pollTimer);
            if (this.sgfHash && this.state === "sweeping") {
                native({ cmd: "stop", gameId: this.sgfHash }).catch(() => {});
            }
        }
    }
})();
