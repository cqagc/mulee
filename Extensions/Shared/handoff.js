"use strict";

const extensionAPI = globalThis.browser || globalThis.chrome;
const hint = document.getElementById("hint");
const openButton = document.getElementById("open");
const closeButton = document.getElementById("close");
let tabID;
let entry;
let opening = false;
let lostFocus = false;

hint.textContent = extensionAPI.i18n.getMessage("externalPrompt");
openButton.textContent = extensionAPI.i18n.getMessage("openMulee");
closeButton.textContent = extensionAPI.i18n.getMessage("closeTab");

async function openMulee() {
    if (!entry || opening) return;
    opening = true;
    try {
        await extensionAPI.tabs.update(tabID, { url: entry });
    } catch {
        hint.textContent = extensionAPI.i18n.getMessage("sendFailed");
    } finally {
        opening = false;
    }
}

async function readEntry() {
    const tab = await extensionAPI.tabs.getCurrent();
    tabID = tab.id;
    const key = "handoff-" + tabID;
    const stored = await extensionAPI.storage.session.get(key);
    if (!stored[key] || entry) return;
    entry = stored[key];
    await extensionAPI.storage.session.remove(key);
    await openMulee();
}

extensionAPI.runtime.onMessage.addListener(message => {
    if (message?.type === "handoffReady") readEntry().catch(console.error);
});
window.addEventListener("blur", () => { lostFocus = true; });
window.addEventListener("focus", () => {
    if (lostFocus && entry) extensionAPI.tabs.remove(tabID).catch(console.error);
});
openButton.addEventListener("click", () => openMulee().catch(console.error));
closeButton.addEventListener("click", async () => {
    const tab = await extensionAPI.tabs.getCurrent();
    await extensionAPI.storage.session.remove("handoff-" + tab.id);
    await extensionAPI.tabs.remove(tab.id);
});
readEntry().catch(console.error);
