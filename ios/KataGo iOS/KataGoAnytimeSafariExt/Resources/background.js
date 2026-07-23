// Stateless native-messaging relay: content scripts cannot call
// sendNativeMessage themselves, so every `{ kgaNative: ... }` runtime message
// is forwarded to the appex and the reply returned verbatim. All session
// state lives in the content script (tab-lifetime) and the native side
// (App Group cache), so this event page may unload freely.

"use strict";

browser.runtime.onMessage.addListener((message) => {
    if (!message || !message.kgaNative) { return undefined; }
    return browser.runtime.sendNativeMessage("application.id", message.kgaNative)
        .catch((error) => ({ kgaError: String(error && error.message || error) }));
});

// ---- T1 feasibility spike (temporary; removed once the spike verdict is
// recorded). Auto-runs once per install and again on toolbar-button click.
// The native side also writes the report to the App Group:
// .../Group Containers/group.chinchangyang.KataGo-iOS.tw/Library/Caches/SafariSpike/report.json

async function runSpike(force) {
    try {
        const { spikeDone } = await browser.storage.local.get("spikeDone");
        if (spikeDone && !force) { return; }
        const echo = await browser.runtime.sendNativeMessage("application.id",
            { cmd: "echo", payload: "hello-from-background" });
        console.log("[kga] echo reply:", echo);
        console.log("[kga] starting engine spike (first run may take minutes: CoreML compile)…");
        const t0 = Date.now();
        const spike = await browser.runtime.sendNativeMessage("application.id", { cmd: "spike" });
        console.log(`[kga] spike reply after ${Date.now() - t0} ms:`, spike);
        await browser.storage.local.set({ spikeDone: true, spikeResult: spike });
    } catch (e) {
        console.error("[kga] spike failed:", e);
        await browser.storage.local.set({ spikeDone: true, spikeError: String(e) });
    }
}

browser.runtime.onInstalled.addListener(() => runSpike(false));
browser.action.onClicked.addListener(() => runSpike(true));
runSpike(false);
