// Dependency-free canvas charts for the analysis panel: a winrate area chart
// and a score-lead line chart stacked on a SHARED x-axis (two measures, two
// charts — never a dual-axis). Single series per chart, so identity lives in
// the chart title; values live in the crosshair tooltip, not on the marks.
// HiDPI-aware; redraws are cheap and idempotent from the caller's store.

"use strict";

class KGAChart {
    /**
     * @param canvas   the <canvas> inside the shadow root
     * @param callbacks { onSeek(moveIndex), onHover(moveIndex|null) }
     */
    constructor(canvas, callbacks) {
        this.canvas = canvas;
        this.callbacks = callbacks || {};
        this.moveCount = 0;         // x-domain = 0..moveCount
        this.winrates = [];         // sparse: winrates[i] = Black winrate 0..1
        this.scores = [];           // sparse: scores[i] = Black score lead
        this.badges = [];           // [{ moveIndex, severity: "major"|"minor" }]
        this.cursor = 0;
        this.cursorOnMainline = true;
        this.hoverIndex = null;
        this.theme = this.readTheme();

        canvas.addEventListener("pointerdown", (e) => this.seek(e));
        canvas.addEventListener("pointermove", (e) => {
            if (e.buttons & 1) { this.seek(e); return; }
            const index = this.indexAt(e);
            if (index !== this.hoverIndex) {
                this.hoverIndex = index;
                if (this.callbacks.onHover) { this.callbacks.onHover(index); }
                this.draw();
            }
        });
        canvas.addEventListener("pointerleave", () => {
            this.hoverIndex = null;
            if (this.callbacks.onHover) { this.callbacks.onHover(null); }
            this.draw();
        });
    }

    readTheme() {
        const styles = getComputedStyle(this.canvas);
        return {
            grid: styles.getPropertyValue("--kga-grid").trim() || "#e5e5ea",
            ink: styles.getPropertyValue("--kga-ink-muted").trim() || "#6e6e73",
            winrate: styles.getPropertyValue("--kga-winrate").trim() || "#0a84ff",
            score: styles.getPropertyValue("--kga-score").trim() || "#bf5af2",
            badge: styles.getPropertyValue("--kga-badge").trim() || "#ff453a",
            pendingHatch: styles.getPropertyValue("--kga-hatch").trim() || "rgba(110,110,115,0.12)",
            cursor: styles.getPropertyValue("--kga-cursor").trim() || "#1d1d1f",
        };
    }

    setGame(moveCount) {
        this.moveCount = Math.max(0, moveCount);
        this.winrates = [];
        this.scores = [];
        this.badges = [];
        this.cursor = 0;
        this.draw();
    }

    merge(results, badges) {
        for (const r of results) {
            this.winrates[r.moveIndex] = r.winrateB;
            this.scores[r.moveIndex] = r.scoreLeadB;
        }
        if (badges) { this.badges = badges; }
        this.draw();
    }

    setCursor(moveIndex, onMainline) {
        this.cursor = moveIndex;
        this.cursorOnMainline = onMainline !== false;
        this.draw();
    }

    // ---- geometry --------------------------------------------------------

    layout() {
        const rect = this.canvas.getBoundingClientRect();
        const w = Math.max(80, rect.width);
        const h = Math.max(60, rect.height);
        const padL = 8, padR = 8, padT = 6, gap = 10, padB = 14;
        const winH = Math.round((h - padT - padB - gap) * 0.62);
        const scoreH = h - padT - padB - gap - winH;
        return { w, h, padL, padR,
                 win: { top: padT, height: winH },
                 score: { top: padT + winH + gap, height: scoreH } };
    }

    xFor(index, l) {
        const span = Math.max(1, this.moveCount);
        return l.padL + (l.w - l.padL - l.padR) * (index / span);
    }

    indexAt(event) {
        const rect = this.canvas.getBoundingClientRect();
        const l = this.layout();
        const frac = (event.clientX - rect.left - l.padL) / Math.max(1, l.w - l.padL - l.padR);
        const index = Math.round(frac * Math.max(1, this.moveCount));
        return Math.max(0, Math.min(this.moveCount, index));
    }

    seek(event) {
        const index = this.indexAt(event);
        if (this.callbacks.onSeek) { this.callbacks.onSeek(index); }
    }

    // ---- drawing ---------------------------------------------------------

    draw() {
        const l = this.layout();
        const dpr = window.devicePixelRatio || 1;
        if (this.canvas.width !== Math.round(l.w * dpr) ||
            this.canvas.height !== Math.round(l.h * dpr)) {
            this.canvas.width = Math.round(l.w * dpr);
            this.canvas.height = Math.round(l.h * dpr);
        }
        this.theme = this.readTheme();
        const ctx = this.canvas.getContext("2d");
        ctx.setTransform(dpr, 0, 0, dpr, 0, 0);
        ctx.clearRect(0, 0, l.w, l.h);

        this.drawPending(ctx, l);
        this.drawWinrate(ctx, l);
        this.drawScore(ctx, l);
        this.drawBadges(ctx, l);
        this.drawCursor(ctx, l);
    }

    contiguousRuns() {
        // Runs of consecutive analyzed indices, so partial sweeps draw as
        // segments instead of connecting across unanalyzed gaps.
        const runs = [];
        let run = null;
        for (let i = 0; i <= this.moveCount; i += 1) {
            if (typeof this.winrates[i] === "number") {
                if (!run) { run = [i, i]; runs.push(run); }
                run[1] = i;
            } else {
                run = null;
            }
        }
        return runs;
    }

    drawPending(ctx, l) {
        // Hatch the whole strip, then clear analyzed runs — the advancing
        // boundary IS the progress indicator.
        ctx.fillStyle = this.theme.pendingHatch;
        ctx.fillRect(l.padL, l.win.top, l.w - l.padL - l.padR, l.win.height);
        ctx.fillRect(l.padL, l.score.top, l.w - l.padL - l.padR, l.score.height);
        const clear = (topBand) => {
            for (const [a, b] of this.contiguousRuns()) {
                const x0 = this.xFor(a, l);
                const x1 = this.xFor(b, l);
                ctx.clearRect(x0 - 1, topBand.top, Math.max(2, x1 - x0 + 2), topBand.height);
            }
        };
        clear(l.win);
        clear(l.score);
    }

    drawWinrate(ctx, l) {
        const { top, height } = l.win;
        const yFor = (wr) => top + height * (1 - wr);
        // Recessive midline at 50%.
        ctx.strokeStyle = this.theme.grid;
        ctx.lineWidth = 1;
        ctx.beginPath();
        ctx.moveTo(l.padL, yFor(0.5));
        ctx.lineTo(l.w - l.padR, yFor(0.5));
        ctx.stroke();

        for (const [a, b] of this.contiguousRuns()) {
            if (a === b) {
                ctx.fillStyle = this.theme.winrate;
                ctx.beginPath();
                ctx.arc(this.xFor(a, l), yFor(this.winrates[a]), 2, 0, 2 * Math.PI);
                ctx.fill();
                continue;
            }
            // Area between the series and the midline.
            ctx.beginPath();
            ctx.moveTo(this.xFor(a, l), yFor(0.5));
            for (let i = a; i <= b; i += 1) { ctx.lineTo(this.xFor(i, l), yFor(this.winrates[i])); }
            ctx.lineTo(this.xFor(b, l), yFor(0.5));
            ctx.closePath();
            ctx.fillStyle = this.hexWithAlpha(this.theme.winrate, 0.18);
            ctx.fill();
            // 2px series line on top.
            ctx.beginPath();
            for (let i = a; i <= b; i += 1) {
                const x = this.xFor(i, l), y = yFor(this.winrates[i]);
                if (i === a) { ctx.moveTo(x, y); } else { ctx.lineTo(x, y); }
            }
            ctx.strokeStyle = this.theme.winrate;
            ctx.lineWidth = 2;
            ctx.stroke();
        }
    }

    drawScore(ctx, l) {
        const { top, height } = l.score;
        let maxAbs = 5;
        for (const [a, b] of this.contiguousRuns()) {
            for (let i = a; i <= b; i += 1) {
                maxAbs = Math.max(maxAbs, Math.abs(this.scores[i] || 0));
            }
        }
        const yFor = (s) => top + height * (0.5 - (s / (2 * maxAbs)));
        ctx.strokeStyle = this.theme.grid;
        ctx.lineWidth = 1;
        ctx.beginPath();
        ctx.moveTo(l.padL, yFor(0));
        ctx.lineTo(l.w - l.padR, yFor(0));
        ctx.stroke();

        for (const [a, b] of this.contiguousRuns()) {
            ctx.beginPath();
            for (let i = a; i <= b; i += 1) {
                const x = this.xFor(i, l), y = yFor(this.scores[i] || 0);
                if (i === a) { ctx.moveTo(x, y); } else { ctx.lineTo(x, y); }
            }
            ctx.strokeStyle = this.theme.score;
            ctx.lineWidth = 2;
            ctx.stroke();
        }
    }

    drawBadges(ctx, l) {
        for (const badge of this.badges) {
            const wr = this.winrates[badge.moveIndex];
            if (typeof wr !== "number") { continue; }
            const x = this.xFor(badge.moveIndex, l);
            const y = l.win.top + l.win.height * (1 - wr);
            ctx.fillStyle = this.theme.badge;
            ctx.beginPath();
            ctx.arc(x, y, badge.severity === "major" ? 4 : 3, 0, 2 * Math.PI);
            ctx.fill();
            if (badge.severity === "major") {
                // Symbol so severity is never color-alone.
                ctx.fillStyle = "#ffffff";
                ctx.font = "600 6px -apple-system, sans-serif";
                ctx.textAlign = "center";
                ctx.textBaseline = "middle";
                ctx.fillText("!", x, y + 0.5);
            }
        }
    }

    drawCursor(ctx, l) {
        const drawLine = (index, color, width) => {
            const x = this.xFor(index, l);
            ctx.strokeStyle = color;
            ctx.lineWidth = width;
            ctx.beginPath();
            ctx.moveTo(x, l.win.top);
            ctx.lineTo(x, l.score.top + l.score.height);
            ctx.stroke();
        };
        if (this.hoverIndex !== null && this.hoverIndex !== this.cursor) {
            drawLine(this.hoverIndex, this.theme.grid, 1);
        }
        drawLine(this.cursor,
                 this.cursorOnMainline ? this.theme.cursor : this.theme.grid,
                 this.cursorOnMainline ? 1.5 : 1);
    }

    hexWithAlpha(hex, alpha) {
        const m = /^#?([0-9a-f]{6})$/i.exec(hex.trim());
        if (!m) { return hex; }
        const n = parseInt(m[1], 16);
        return `rgba(${(n >> 16) & 255},${(n >> 8) & 255},${n & 255},${alpha})`;
    }
}
