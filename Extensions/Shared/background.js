"use strict";

if (typeof importScripts === "function") importScripts("core.js", "video-login.js");
const extensionAPI = globalThis.browser || globalThis.chrome;
const linksAPI = globalThis.MuleeLinks;
// Chrome 也提供 browser 命名空间，只能按扩展 URL 的协议区分 Safari。
const isSafari = extensionAPI.runtime.getURL("").startsWith("safari-web-extension:");

async function openEntry(url) {
    if (extensionAPI.runtime.sendNativeMessage && isSafari) {
        try {
            const response = await extensionAPI.runtime.sendNativeMessage("com.cqagc.mulee", { url });
            if (response?.ok) return;
            throw new Error("nativeRejected");
        } catch (error) {
            // A missing native host falls back to the browser's external-protocol prompt.
            console.info("Mulee native handoff unavailable");
        }
    }
    // A dedicated extension tab survives the external-protocol confirmation. It closes
    // after the browser loses focus to Mulee and the user returns; cancellation is manual.
    const tab = await extensionAPI.tabs.create({ url: extensionAPI.runtime.getURL("handoff.html"), active: true });
    await extensionAPI.storage.session.set({ ["handoff-" + tab.id]: url });
    await extensionAPI.tabs.sendMessage(tab.id, { type: "handoffReady" }).catch(() => {});
}

async function sendLinks(links, referrer, text, context = {}) {
    const requestContext = { ...context, userAgent: globalThis.navigator?.userAgent || "" };
    let batches = linksAPI.buildBatches(links, referrer, text, requestContext);
    if (globalThis.MuleeVideoLogin) await globalThis.MuleeVideoLogin.transfer(extensionAPI, links);
    if (globalThis.MuleeDownloadCookies) {
        const entries = [];
        for (const batch of batches) {
            const parameters = new URL(batch).searchParams;
            const values = parameters.getAll("url");
            const tokens = [];
            for (const link of values) tokens.push(await globalThis.MuleeDownloadCookies.transfer(extensionAPI, link));
            if (tokens.every(token => !token)) {
                entries.push(batch);
            } else {
                for (let index = 0; index < values.length; index++) {
                    entries.push(...linksAPI.buildBatches([values[index]], referrer, text, { ...requestContext, token: tokens[index] }));
                }
            }
        }
        batches = entries;
    }
    for (const url of batches) await openEntry(url);
    return batches.length;
}

function reportIssue(error) {
    console.error("Mulee handoff failed");
    extensionAPI.action.setBadgeText({ text: "!" });
    extensionAPI.action.setTitle({ title: extensionAPI.i18n.getMessage(error.message) || extensionAPI.i18n.getMessage("sendFailed") });
}

extensionAPI.runtime.onInstalled.addListener(() => {
    extensionAPI.contextMenus.removeAll().then(() => {
        extensionAPI.contextMenus.create({ id: "mulee-link", title: extensionAPI.i18n.getMessage("downloadLink"), contexts: ["link"] });
        extensionAPI.contextMenus.create({ id: "mulee-selection", title: extensionAPI.i18n.getMessage("downloadSelection"), contexts: ["selection"] });
    }).catch(reportIssue);
});

extensionAPI.contextMenus.onClicked.addListener((info, tab) => {
    const selected = info.selectionText || "";
    const links = info.menuItemId === "mulee-link" ? [info.linkUrl] : linksAPI.extractLinks(selected);
    sendLinks(links, info.pageUrl || tab?.url || "", selected).catch(reportIssue);
});

extensionAPI.tabs.onRemoved.addListener(tabID => {
    extensionAPI.storage.session.remove("handoff-" + tabID).catch(reportIssue);
});

extensionAPI.runtime.onMessage.addListener((message, sender, respond) => {
    if (sender.id !== extensionAPI.runtime.id || sender.tab) return false;
    if (message?.type === "syncVideoLogin") {
        globalThis.MuleeVideoLogin.transfer(extensionAPI, [], true).then(
            () => respond({ ok: true }),
            error => respond({ ok: false, error: ["videoLoginNotFound", "videoLoginReloadRequired"].includes(error.message)
                ? error.message : "videoLoginFailed" })
        );
        return true;
    }
    if (message?.type !== "sendLinks") return false;
    sendLinks(message.links, message.referrer, message.text).then(
        batches => respond({ ok: true, batches }),
        error => respond({ ok: false, error: ["invalidLinks", "tooLarge", "downloadCookiesFailed",
            "videoLoginNotFound", "videoLoginReloadRequired", "videoLoginFailed"].includes(error.message) ? error.message : "sendFailed" })
    );
    return true;
});

async function interceptDownload(item) {
    const settings = await extensionAPI.storage.local.get({ takeover: false, extensions: linksAPI.defaultExtensions });
    if (!settings.takeover || item.state !== "in_progress" || !linksAPI.remoteLink(item.finalUrl || item.url)) return;
    const extensions = linksAPI.extensionList(settings.extensions);
    if (!linksAPI.hasExtension(item.finalUrl || item.url, extensions)
        && !extensions.some(extension => item.filename?.toLowerCase().endsWith("." + extension))) return;
    // Validate the complete request before cancelling the browser's transfer.
    const context = { filename: item.filename || "", userAgent: globalThis.navigator?.userAgent || "" };
    linksAPI.buildBatches([item.finalUrl || item.url], item.referrer || "", "", context);
    await extensionAPI.downloads.cancel(item.id);
    await sendLinks([item.finalUrl || item.url], item.referrer || "", "", context);
}

// Optional permission may already exist when an MV3 worker restarts. Register
// synchronously whenever the namespace exists, and again after a fresh grant.
function registerDownloads() {
    if (extensionAPI.downloads?.onCreated && !extensionAPI.downloads.onCreated.hasListener(onDownload)) {
        extensionAPI.downloads.onCreated.addListener(onDownload);
    }
}

function onDownload(item) {
    interceptDownload(item).catch(reportIssue);
}

registerDownloads();
extensionAPI.permissions.onAdded.addListener(registerDownloads);
extensionAPI.permissions.onRemoved.addListener(() => {
    extensionAPI.permissions.contains({ permissions: ["downloads"] }).then(granted => {
        if (!granted) return extensionAPI.storage.local.set({ takeover: false });
    }).catch(reportIssue);
});
