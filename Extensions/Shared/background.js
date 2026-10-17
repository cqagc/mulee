"use strict";

if (typeof importScripts === "function") importScripts("core.js", "video-login.js");
const extensionAPI = globalThis.browser || globalThis.chrome;
const linksAPI = globalThis.MuleeLinks;
// Chrome 也提供 browser 命名空间，只能按扩展 URL 的协议区分 Safari。
const isSafari = extensionAPI.runtime.getURL("").startsWith("safari-web-extension:");

function nativeHandoffError(error) {
    const unavailable = [
        "Specified native messaging host not found.",
        "Failed to start native messaging host.",
        "Access to the specified native messaging host is forbidden.",
        "Invalid native messaging host name specified."
    ].includes(error?.message);
    // 只有确定没有建立连接才可恢复；中途断线不能证明 Mulee 尚未接收。
    return new Error(unavailable ? "sendFailed" : "handoffTimeout");
}

async function openEntry(url, requireConfirmation = false, assertActive = () => {}) {
    if (requireConfirmation && !isSafari && extensionAPI.runtime.sendNativeMessage
        && await extensionAPI.permissions.contains({ permissions: ["nativeMessaging"] })) {
        let response;
        try {
            response = await extensionAPI.runtime.sendNativeMessage("com.cqagc.mulee.video_login", { type: "openLinks", url });
        } catch (error) {
            throw nativeHandoffError(error);
        }
        assertActive();
        if (response?.ok === true) return;
        throw new Error(response?.ok === false ? "sendFailed" : "handoffTimeout");
    }
    if (extensionAPI.runtime.sendNativeMessage && isSafari) {
        let response;
        try {
            response = await extensionAPI.runtime.sendNativeMessage("com.cqagc.mulee", { url });
        } catch (error) {
            if (requireConfirmation) throw nativeHandoffError(error);
            // A missing native host falls back to the browser's external-protocol prompt.
            console.info("Mulee native handoff unavailable");
        }
        if (response?.ok === true) return;
        if (requireConfirmation) throw new Error(response?.ok === false ? "sendFailed" : "handoffTimeout");
    }
    // A dedicated extension tab survives the external-protocol confirmation. It closes
    // after the browser loses focus to Mulee and the user returns; cancellation is manual.
    assertActive();
    const tab = await extensionAPI.tabs.create({ url: extensionAPI.runtime.getURL("handoff.html"), active: true });
    try {
        assertActive();
        await extensionAPI.storage.session.set({ ["handoff-" + tab.id]: url });
        assertActive();
        await extensionAPI.tabs.sendMessage(tab.id, { type: "handoffReady" }).catch(() => {});
    } catch (error) {
        await extensionAPI.storage.session.remove("handoff-" + tab.id).catch(() => {});
        await extensionAPI.tabs.remove(tab.id).catch(() => {});
        throw error;
    }
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
    for (const url of batches) {
        context.assertActive?.();
        await openEntry(url, context.requireConfirmation, context.assertActive);
    }
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

const methods = linksAPI.requestMethods();

function recordRequest(details) {
    methods.record(details);
}

function registerRequests() {
    const event = extensionAPI.webRequest?.onBeforeRequest;
    if (!event?.addListener) return;
    try {
        if (event.hasListener?.(recordRequest)) return;
        event.addListener(recordRequest, { urls: ["http://*/*", "https://*/*"] });
    } catch {
        // Safari 或尚未授权的浏览器可能提供命名空间却不允许监听。
    }
}

function handoffWithTimeout(operation) {
    let timer;
    let expired = false;
    const assertActive = () => {
        if (expired) throw new Error("handoffTimeout");
    };
    return Promise.race([
        Promise.resolve().then(() => operation(assertActive)),
        new Promise((resolve, reject) => {
            timer = setTimeout(() => {
                expired = true;
                reject(new Error("handoffTimeout"));
            }, 10000);
        })
    ]).finally(() => clearTimeout(timer));
}

async function interceptDownload(item) {
    const settings = await extensionAPI.storage.local.get({
        takeover: false, extensions: linksAPI.defaultExtensions, excludedSites: []
    });
    const url = item.finalUrl || item.url;
    if (!settings.takeover || item.state !== "in_progress" || !linksAPI.remoteLink(url)) return;
    const sites = linksAPI.excludedSiteList(settings.excludedSites);
    if ([item.referrer, item.url, url].some(value => linksAPI.isExcludedSite(value, sites))) return;
    if ([item.url, url].some(value => {
        const method = methods.get(value, item.tabId);
        return method && method !== "GET";
    })) return;
    const extensions = linksAPI.extensionList(settings.extensions);
    if (!linksAPI.hasExtension(url, extensions)
        && !extensions.some(extension => item.filename?.toLowerCase().endsWith("." + extension))) return;
    try {
        await extensionAPI.downloads.pause(item.id);
    } catch {
        // 暂停失败时保留浏览器原来的下载，不尝试交接或取消。
        return;
    }
    try {
        const context = { filename: item.filename || "", userAgent: globalThis.navigator?.userAgent || "" };
        await handoffWithTimeout(assertActive => sendLinks([url], item.referrer || "", "", {
            ...context, requireConfirmation: true, assertActive
        }));
    } catch (error) {
        // 超时无法证明 Mulee 没收到，恢复会有重复下载风险。
        if (error.message !== "handoffTimeout") await extensionAPI.downloads.resume(item.id);
        throw error;
    }
    try {
        await extensionAPI.downloads.cancel(item.id);
    } catch {
        // 已确认交接后取消失败也不能恢复，让用户手动清理暂停的浏览器任务。
        throw new Error("browserDownloadPaused");
    }
    // 取消成功后不能再恢复；清理历史失败只报告错误。
    await extensionAPI.downloads.erase({ id: item.id });
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
registerRequests();
extensionAPI.permissions.onAdded.addListener(() => {
    registerDownloads();
    registerRequests();
});
extensionAPI.permissions.onRemoved.addListener(() => {
    methods.clear();
    extensionAPI.permissions.contains({ permissions: ["downloads"] }).then(granted => {
        if (!granted) return extensionAPI.storage.local.set({ takeover: false });
    }).catch(reportIssue);
});
