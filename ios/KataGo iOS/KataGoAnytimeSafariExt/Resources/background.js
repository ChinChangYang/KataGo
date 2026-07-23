// T1 spike driver. Runs the native feasibility spike once per install
// (auto, so verification is hands-free after enabling the extension) and
// again whenever the toolbar button is clicked. Results also land in
// ~/Library/Group Containers/group.chinchangyang.KataGo-iOS.tw/Library/Caches/SafariSpike/report.json
// via the native handler, so the report survives even if this page unloads.

async function runSpike(force) {
    try {
        const { spikeDone } = await browser.storage.local.get("spikeDone");
        if (spikeDone && !force) {
            console.log("[kga] spike already ran; click the toolbar button to re-run");
            return;
        }
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
