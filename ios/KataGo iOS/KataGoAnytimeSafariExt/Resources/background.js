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
