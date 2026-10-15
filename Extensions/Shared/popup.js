"use strict";

const extensionAPI = globalThis.browser || globalThis.chrome;
let page = { url: "", text: "" };
const status = document.getElementById("status");
const sendButton = document.getElementById("send");
const takeover = document.getElementById("takeover");
const extensions = document.getElementById("extensions");

function message(key) {
    return extensionAPI.i18n.getMessage(key) || extensionAPI.i18n.getMessage("sendFailed");
}

for (const node of document.querySelectorAll("[data-i18n]")) node.textContent = message(node.dataset.i18n);
document.documentElement.lang = extensionAPI.i18n.getUILanguage();

function showError(error) {
    status.textContent = message(error.message);
}

function updateSelection() {
    sendButton.disabled = !document.querySelector(".link input:checked");
}

async function initialize() {
    const settings = await extensionAPI.storage.local.get({ takeover: false, extensions: MuleeLinks.defaultExtensions });
    const supported = (extensionAPI.runtime.getManifest().optional_permissions || []).includes("downloads");
    const granted = supported && await extensionAPI.permissions.contains({ permissions: ["downloads"] });
    takeover.checked = settings.takeover && granted;
    takeover.disabled = !supported;
    if (!supported) document.querySelector("[data-i18n='takeoverHint']").textContent = message("takeoverUnavailable");
    extensions.value = settings.extensions;
    try {
        const [tab] = await extensionAPI.tabs.query({ active: true, currentWindow: true });
        const [result] = await extensionAPI.scripting.executeScript({
            target: { tabId: tab.id },
            func: () => ({
                hrefs: [...document.querySelectorAll("a[href]")].map(anchor => anchor.href),
                text: document.body?.innerText || "",
                selection: window.getSelection()?.toString() || "",
                url: location.href
            })
        });
        page = { url: result.result.url, text: result.result.selection };
        const links = MuleeLinks.collectLinks(result.result.hrefs, result.result.text, page.url);
        document.getElementById("empty").hidden = links.length > 0;
        for (const link of links) {
            const label = document.createElement("label");
            label.className = "link";
            const checkbox = document.createElement("input");
            checkbox.type = "checkbox";
            checkbox.value = link;
            checkbox.checked = true;
            checkbox.addEventListener("change", updateSelection);
            const text = document.createElement("span");
            text.textContent = link;
            label.append(checkbox, text);
            document.getElementById("links").append(label);
        }
        updateSelection();
    } catch {
        document.getElementById("empty").hidden = false;
        status.textContent = message("restrictedPage");
    }
    await extensionAPI.action.setBadgeText({ text: "" });
}

sendButton.addEventListener("click", async () => {
    sendButton.disabled = true;
    try {
        const links = [...document.querySelectorAll(".link input:checked")].map(input => input.value);
        const response = await extensionAPI.runtime.sendMessage({ type: "sendLinks", links, referrer: page.url, text: page.text });
        if (!response?.ok) throw new Error(response?.error || "sendFailed");
        status.textContent = message("sent");
    } catch (error) {
        showError(error);
    } finally {
        updateSelection();
    }
});

takeover.addEventListener("change", async () => {
    try {
        if (takeover.checked) {
            // This request must run directly in the checkbox's user gesture.
            const granted = await extensionAPI.permissions.request({ permissions: ["downloads"] });
            takeover.checked = granted;
            if (!granted) status.textContent = message("permissionDenied");
        }
        await extensionAPI.storage.local.set({ takeover: takeover.checked });
        if (!takeover.checked) await extensionAPI.permissions.remove({ permissions: ["downloads"] });
    } catch (error) {
        takeover.checked = false;
        await extensionAPI.storage.local.set({ takeover: false });
        showError(error);
    }
});

document.getElementById("save").addEventListener("click", async () => {
    try {
        const list = MuleeLinks.extensionList(extensions.value).join(" ");
        await extensionAPI.storage.local.set({ extensions: list });
        extensions.value = list;
        status.textContent = message("saved");
    } catch (error) {
        showError(error);
    }
});

initialize().catch(showError);
