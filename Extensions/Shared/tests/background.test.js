"use strict";

const test = require("node:test");
const assert = require("node:assert/strict");
const vm = require("node:vm");
const fs = require("node:fs");
const path = require("node:path");
const core = require("../core.js");
const login = require("../video-login.js");

function event() {
    const listeners = [];
    return {
        listeners,
        addListener: listener => listeners.push(listener),
        hasListener: listener => listeners.includes(listener)
    };
}

function worker({ takeover = false, videoLogin = false, native = false, scheme = native ? "safari-web-extension" : "chrome-extension" } = {}) {
    const calls = [];
    const api = {
        runtime: {
            id: "test-extension",
            onInstalled: event(),
            onMessage: event(),
            getManifest: () => ({ optional_permissions: ["cookies", "nativeMessaging"] }),
            getURL: name => scheme + "://test-extension/" + name
        },
        tabs: {
            onRemoved: event(),
            create: async value => { calls.push(["create", value]); return { id: 9 }; },
            remove: async () => {},
            sendMessage: async () => {}
        },
        storage: {
            local: { get: async defaults => ({ ...defaults, takeover, videoLogin }) },
            session: {
                set: async value => calls.push(["session", value]),
                remove: async () => {}
            }
        },
        contextMenus: { onClicked: event() },
        permissions: { onAdded: event(), onRemoved: event(), contains: async () => true },
        webRequest: { onBeforeRequest: event() },
        cookies: { getAll: async () => [] },
        action: { setBadgeText: () => {}, setTitle: () => {} },
        i18n: { getMessage: key => key },
        downloads: {
            onCreated: event(),
            pause: async id => calls.push(["pause", id]),
            resume: async id => calls.push(["resume", id]),
            cancel: async id => calls.push(["cancel", id]),
            erase: async query => calls.push(["erase", query])
        }
    };
    if (native) {
        api.runtime.sendNativeMessage = async (application, message) => {
            calls.push(["native", application, message]);
            return { ok: true };
        };
    }
    const context = { MuleeLinks: core, MuleeVideoLogin: login, MuleeDownloadCookies: login.downloadCookies,
        navigator: { userAgent: "Synthetic Browser/1.0" }, URL, console, setTimeout, clearTimeout, [native ? "browser" : "chrome"]: api };
    vm.createContext(context);
    vm.runInContext(fs.readFileSync(path.join(__dirname, "../background.js"), "utf8"), context);
    return { api, calls, context };
}

test("download interception is inactive by default and never touches cookies", async () => {
    const { context, calls } = worker();
    await vm.runInContext('interceptDownload({ id: 1, state: "in_progress", url: "https://example.org/a.zip" })', context);
    assert.equal(calls.length, 0);
});

test("enabled interception pauses matching downloads and cancels only after handoff with referrer", async () => {
    const { context, calls } = worker({ takeover: true });
    await vm.runInContext('interceptDownload({ id: 1, state: "in_progress", url: "https://example.org/a.zip", referrer: "https://example.org/page", filename: "/temporary/downloads/archive.zip" })', context);
    assert.equal(calls[0][0], "pause");
    assert.deepEqual(calls.slice(-2).map(call => call[0]), ["cancel", "erase"]);
    const entry = calls.find(call => call[0] === "session")[1]["handoff-9"];
    assert.equal(new URL(entry).searchParams.get("referrer"), "https://example.org/page");
    assert.equal(new URL(entry).searchParams.get("url"), "https://example.org/a.zip");
    assert.equal(new URL(entry).searchParams.get("ua"), "Synthetic Browser/1.0");
    assert.equal(new URL(entry).searchParams.get("filename"), "archive.zip");
});

test("interception ignores nonmatching, completed and unsafe downloads", async () => {
    const { context, calls } = worker({ takeover: true });
    for (const item of [
        { id: 1, state: "in_progress", url: "https://example.org/a.html" },
        { id: 2, state: "complete", url: "https://example.org/a.zip" },
        { id: 3, state: "in_progress", url: "file:///tmp/private.zip" }
    ]) {
        await vm.runInContext("interceptDownload(" + JSON.stringify(item) + ")", context);
    }
    assert.equal(calls.length, 0);
});

test("Safari native messaging opens no temporary browser tabs", async () => {
    const { context, calls } = worker({ native: true });
    await vm.runInContext('sendLinks(["https://example.org/a.zip"], "https://example.org/page", "密码：abc")', context);
    assert.equal(calls.length, 1);
    assert.equal(calls[0][0], "native");
    assert.equal(calls[0][1], "com.cqagc.mulee");
    assert.equal(new URL(calls[0][2].url).searchParams.get("text"), "密码：abc");
});

test("Chrome with a browser namespace still uses the protocol tab", async () => {
    const { context, calls } = worker({ native: true, scheme: "chrome-extension" });
    await vm.runInContext('sendLinks(["https://example.org/a.zip"], "", "")', context);
    assert.equal(calls[0][0], "create");
    assert.equal(calls.some(call => call[0] === "native"), false);
});

test("native host failure falls back to a temporary protocol tab", async () => {
    const { context, api, calls } = worker({ native: true });
    api.runtime.sendNativeMessage = async () => { throw new Error("host unavailable"); };
    await vm.runInContext('sendLinks(["https://example.org/a.zip"], "", "")', context);
    assert.equal(calls[0][0], "create");
});

test("only the extension popup can request link handoff", () => {
    const { api, calls } = worker();
    const listener = api.runtime.onMessage.listeners[0];
    const message = { type: "sendLinks", links: ["https://example.org/a.zip"] };
    assert.equal(listener(message, { id: "other-extension" }, () => {}), false);
    assert.equal(listener(message, { id: api.runtime.id, tab: { id: 1 } }, () => {}), false);
    assert.equal(calls.length, 0);
});

test("download event registration is synchronous and idempotent", () => {
    const { api } = worker();
    assert.equal(api.downloads.onCreated.listeners.length, 1);
    api.permissions.onAdded.listeners[0]();
    assert.equal(api.downloads.onCreated.listeners.length, 1);
});

test("background handoff normalizes and deduplicates links before opening Mulee", async () => {
    const { context, calls } = worker({ native: true });
    await vm.runInContext('sendLinks(["https://youtube.com/watch?v=abc&list=xyz&t=20&si=one", "https://youtube.com/watch?v=abc&list=xyz&t=20&feature=share"], "", "")', context);
    assert.equal(calls.length, 1);
    assert.deepEqual(new URL(calls[0][2].url).searchParams.getAll("url"), ["https://youtube.com/watch?v=abc&list=xyz&t=20"]);
});

test("authorized cookies are paired with one token per link before Safari opens the handoff", async () => {
    const { context, api, calls } = worker({ native: true });
    const reads = [];
    api.storage.local.get = async defaults => ({ ...defaults, downloadCookieSites: ["https://example.org"] });
    api.cookies.getAll = async query => {
        reads.push(query);
        return [{ name: "session", value: "synthetic-private" }];
    };
    await vm.runInContext('sendLinks(["https://example.org/a.zip?utm_source=one", "https://example.org/a.zip", "https://other.example.org/b.zip", "https://example.org/c.zip"], "https://example.org/page", "")', context);
    assert.deepEqual(reads, [{ url: "https://example.org/a.zip" }, { url: "https://example.org/c.zip" }]);
    const transfers = calls.filter(call => call[0] === "native" && call[2].type === "downloadCookies");
    const entries = calls.filter(call => call[0] === "native" && call[2].url?.startsWith("mulee:"));
    assert.equal(transfers.length, 2);
    assert.equal(entries.length, 3);
    assert.notEqual(transfers[0][2].token, transfers[1][2].token);
    for (const transfer of transfers) {
        const entry = entries.find(call => new URL(call[2].url).searchParams.get("url") === transfer[2].url);
        assert.equal(new URL(entry[2].url).searchParams.get("token"), transfer[2].token);
        assert.ok(calls.indexOf(transfer) < calls.indexOf(entry));
    }
    assert.equal(new URL(entries[1][2].url).searchParams.has("token"), false);
    for (const entry of entries) {
        assert.equal(entry[2].url.includes("synthetic-private"), false);
        assert.equal(new URL(entry[2].url).searchParams.get("ua"), "Synthetic Browser/1.0");
    }
    assert.equal(calls.some(call => call[0] === "session" || call[0] === "create"), false);
});

test("sync response preserves actionable errors and sanitizes unexpected failures", async () => {
    for (const expected of ["videoLoginNotFound", "videoLoginReloadRequired", "videoLoginFailed"]) {
        const { api, context } = worker({ native: true, videoLogin: true });
        if (expected === "videoLoginReloadRequired") delete api.cookies;
        if (expected === "videoLoginFailed") {
            context.MuleeVideoLogin = { transfer: async () => { throw new Error("synthetic credential"); } };
        }
        const response = await new Promise(resolve => {
            assert.equal(api.runtime.onMessage.listeners[0]({ type: "syncVideoLogin" }, { id: api.runtime.id }, resolve), true);
        });
        assert.equal(response.ok, false);
        assert.equal(response.error, expected);
    }
    const { api } = worker({ videoLogin: true });
    const response = await new Promise(resolve => {
        api.runtime.onMessage.listeners[0]({ type: "syncVideoLogin" }, { id: api.runtime.id }, resolve);
    });
    assert.equal(response.error, "videoLoginReloadRequired");
});

test("background sync succeeds when one permitted site has login cookies", async () => {
    const { api, calls } = worker({ native: true, videoLogin: true });
    api.cookies.getAll = async ({ domain }) => domain === "bilibili.com" ? [
        { domain: ".bilibili.com", path: "/", name: "SESSDATA", value: "synthetic" }
    ] : [];
    const response = await new Promise(resolve => {
        api.runtime.onMessage.listeners[0]({ type: "syncVideoLogin" }, { id: api.runtime.id }, resolve);
    });
    assert.equal(response.ok, true);
    assert.equal(calls.length, 1);
    assert.equal(calls[0][2].site, "bilibili");
});

async function popup({ url = "https://www.bilibili.com/", hrefs = [], videoLogin = true,
    syncResponse = { ok: true }, sendResponse = { ok: true }, restricted = false } = {}) {
    const nodes = new Map();
    const localized = [];
    function element() {
        return {
            children: [], listeners: {}, dataset: {}, hidden: false, disabled: false, checked: false,
            textContent: "", value: "",
            append(...children) { this.children.push(...children); },
            addEventListener(type, listener) { this.listeners[type] = listener; },
            async dispatch(type) { await this.listeners[type](); }
        };
    }
    const html = fs.readFileSync(path.join(__dirname, "../popup.html"), "utf8");
    for (const tag of html.matchAll(/<[a-z]+\b([^>]*)>/g)) {
        const node = element();
        const id = tag[1].match(/\bid="([^"]+)"/);
        const key = tag[1].match(/\bdata-i18n="([^"]+)"/);
        node.hidden = /\bhidden\b/.test(tag[1]);
        node.disabled = /\bdisabled\b/.test(tag[1]);
        if (id) nodes.set(id[1], node);
        if (key) {
            node.dataset.i18n = key[1];
            localized.push(node);
        }
    }
    const inputs = () => nodes.get("links").children.filter(node => node.className === "link")
        .flatMap(node => node.children.filter(child => child.type === "checkbox"));
    const document = {
        documentElement: {},
        getElementById: id => nodes.get(id),
        createElement: element,
        querySelectorAll: selector => selector === "[data-i18n]" ? localized
            : selector === ".link input:checked" ? inputs().filter(input => input.checked) : inputs()
    };
    const messages = [];
    const permissionRequests = [];
    const stored = {};
    const locale = JSON.parse(fs.readFileSync(path.join(__dirname, "../_locales/en/messages.json"), "utf8"));
    let initialized;
    const ready = new Promise(resolve => { initialized = resolve; });
    const api = {
        i18n: {
            getMessage: (key, substitution) => locale[key]?.message.replace("$1", substitution) || "",
            getUILanguage: () => "en"
        },
        storage: { local: {
            get: async defaults => ({ ...defaults, videoLogin, ...stored }),
            set: async values => Object.assign(stored, values)
        } },
        permissions: {
            contains: async () => true,
            request: async request => { permissionRequests.push(request); return true; },
            remove: async () => {}
        },
        runtime: {
            getManifest: () => ({ optional_permissions: ["downloads", "webRequest", "cookies", "nativeMessaging"] }),
            sendMessage: async message => {
                messages.push(message);
                return message.type === "syncVideoLogin" ? syncResponse : sendResponse;
            }
        },
        tabs: { query: async () => [{ id: 1, url }] },
        scripting: { executeScript: async () => {
            if (restricted) throw new Error("restricted");
            return [{ result: { url, hrefs, text: "", selection: "" } }];
        } },
        action: { setBadgeText: async () => initialized() }
    };
    const context = { document, chrome: api, MuleeLinks: core, MuleeVideoLogin: login, MuleeDownloadCookies: login.downloadCookies };
    vm.createContext(context);
    vm.runInContext(fs.readFileSync(path.join(__dirname, "../popup.js"), "utf8"), context);
    await ready;
    return { nodes, inputs, messages, permissionRequests, stored, api };
}

test("homepage popup leaves links unchecked and bulk controls update the send count", async () => {
    const hrefs = Array.from({ length: 8 }, (_, index) => "https://www.bilibili.com/video/BV" + index + "?trackid=feed");
    const state = await popup({ hrefs });
    assert.equal(state.inputs().length, 8);
    assert.equal(state.inputs().some(input => input.checked), false);
    assert.equal(state.nodes.get("selection-actions").hidden, false);
    assert.equal(state.nodes.get("send").disabled, true);
    assert.equal(state.nodes.get("send").textContent, "Send to Mulee (0)");
    await state.nodes.get("select-all").dispatch("click");
    assert.equal(state.inputs().every(input => input.checked), true);
    assert.equal(state.nodes.get("send").disabled, false);
    assert.equal(state.nodes.get("send").textContent, "Send to Mulee (8)");
    await state.nodes.get("select-none").dispatch("click");
    assert.equal(state.inputs().some(input => input.checked), false);
    assert.equal(state.nodes.get("send").disabled, true);
    assert.equal(state.nodes.get("send").textContent, "Send to Mulee (0)");
    state.inputs()[2].checked = true;
    await state.inputs()[2].dispatch("change");
    assert.equal(state.nodes.get("send").textContent, "Send to Mulee (1)");
    await state.nodes.get("send").dispatch("click");
    assert.equal(state.messages.length, 1);
    assert.deepEqual(Array.from(state.messages[0].links), ["https://www.bilibili.com/video/BV2"]);
});

test("popup moves the normalized current page first and selects only that link", async () => {
    for (const url of ["https://www.bilibili.com/video/BVcurrent?p=2&t=30&trackid=feed",
        "https://youtube.com/watch?v=current&list=xyz&t=20&si=share", "https://example.org/a.zip?token=a%2fb"]) {
        const current = core.normalizeURL(url);
        const state = await popup({ url, hrefs: ["https://example.org/other.zip", current, url] });
        assert.equal(state.inputs().length, 2);
        assert.equal(state.inputs()[0].value, current);
        assert.equal(state.inputs()[0].checked, true);
        assert.equal(state.inputs()[1].checked, false);
        assert.equal(state.nodes.get("links").children[0].children[1].textContent, current);
        assert.equal(state.nodes.get("selection-actions").hidden, true);
        await state.nodes.get("send").dispatch("click");
        assert.deepEqual(Array.from(state.messages[0].links), [current]);
    }
});

test("popup includes a recognized current URL even without a matching page anchor", async () => {
    const url = "magnet:?xt=urn:btih:" + "a".repeat(40);
    const state = await popup({ url, hrefs: ["https://example.org/a.zip"] });
    assert.equal(state.inputs()[0].value, url);
    assert.equal(state.inputs()[0].checked, true);
    assert.equal(state.inputs()[1].checked, false);
});

test("empty and restricted popup pages keep the send count at zero", async () => {
    for (const restricted of [false, true]) {
        const state = await popup({ restricted });
        assert.equal(state.nodes.get("empty").hidden, false);
        assert.equal(state.nodes.get("selection-actions").hidden, true);
        assert.equal(state.nodes.get("send").disabled, true);
        assert.equal(state.nodes.get("send").textContent, "Send to Mulee (0)");
    }
});

test("popup preserves specific sync errors on both login controls and during link handoff", async () => {
    const locale = JSON.parse(fs.readFileSync(path.join(__dirname, "../_locales/en/messages.json"), "utf8"));
    for (const error of ["videoLoginNotFound", "videoLoginReloadRequired", "videoLoginFailed", "unknown"]) {
        const response = { ok: false, error };
        const state = await popup({ syncResponse: response });
        await state.nodes.get("video-login-sync").dispatch("click");
        const expected = error === "unknown" ? "videoLoginFailed" : error;
        assert.equal(state.nodes.get("status").textContent, locale[expected].message);
        assert.equal(state.nodes.get("video-login-sync").disabled, false);
        state.nodes.get("video-login").checked = true;
        await state.nodes.get("video-login").dispatch("change");
        assert.equal(state.nodes.get("status").textContent, locale[expected].message);
    }
    const state = await popup({ url: "https://youtu.be/example", sendResponse: { ok: false, error: "videoLoginReloadRequired" } });
    await state.nodes.get("send").dispatch("click");
    assert.equal(state.nodes.get("status").textContent, locale.videoLoginReloadRequired.message);
});

test("all four locales provide selection and actionable login messages", () => {
    const keys = ["sendSelected", "selectAll", "selectNone", "videoLoginNotFound", "videoLoginReloadRequired",
        "downloadCookies", "downloadCookiesHint", "downloadCookiesUnavailable", "downloadCookiesDenied", "downloadCookiesFailed", "excludedSites", "excludedSitesHint", "invalidExcludedSites", "methodPermissionDenied", "handoffTimeout"];
    for (const language of ["en", "ja", "zh_CN", "zh_TW"]) {
        const locale = JSON.parse(fs.readFileSync(path.join(__dirname, "../_locales", language, "messages.json"), "utf8"));
        for (const key of keys) assert.ok(locale[key].message, language + ": " + key);
        assert.ok(locale.sendSelected.message.includes("$1"));
        assert.ok(locale.videoLoginReloadRequired.message.includes("chrome://extensions"));
    }
});

test("download cookie popup is off by default and requests only the current website", async () => {
    const state = await popup({ url: "https://example.org/a.zip" });
    const toggle = state.nodes.get("download-cookies");
    assert.equal(toggle.checked, false);
    assert.equal(toggle.disabled, false);
    toggle.checked = true;
    await toggle.dispatch("change");
    assert.equal(toggle.checked, true);
    assert.equal(state.permissionRequests.length, 1);
    assert.deepEqual(state.permissionRequests[0].origins, ["https://example.org/*"]);
    assert.deepEqual(state.permissionRequests[0].permissions, ["cookies", "nativeMessaging"]);
    assert.deepEqual(Array.from(state.stored.downloadCookieSites), ["https://example.org"]);
    toggle.checked = false;
    await toggle.dispatch("change");
    assert.deepEqual(Array.from(state.stored.downloadCookieSites), []);
    assert.equal(state.permissionRequests.length, 1);
});

const matchingDownload = { id: 1, state: "in_progress", tabId: 4, url: "https://example.org/a.zip" };

async function intercept(state, item = matchingDownload) {
    await vm.runInContext("interceptDownload(" + JSON.stringify(item) + ")", state.context);
}

test("pause failure leaves browser download untouched", async () => {
    const state = worker({ takeover: true });
    state.api.downloads.pause = async id => {
        state.calls.push(["pause", id]);
        throw new Error("not pausable");
    };
    await intercept(state);
    assert.deepEqual(state.calls.map(call => call[0]), ["pause"]);
});

test("validation and handoff failures resume without cancelling or erasing", async () => {
    for (const failure of ["validation", "handoff", "cancel"]) {
        const state = worker({ takeover: true });
        if (failure === "handoff") state.api.tabs.create = async () => { throw new Error("unavailable"); };
        if (failure === "cancel") state.api.downloads.cancel = async () => { throw new Error("cancel failed"); };
        const item = failure === "validation"
            ? { ...matchingDownload, filename: "x".repeat(core.maximumBytes) + ".zip" } : matchingDownload;
        await assert.rejects(intercept(state, item));
        assert.equal(state.calls[0][0], "pause");
        assert.equal(state.calls.at(-1)[0], "resume");
        assert.equal(state.calls.some(call => call[0] === "erase"), false);
    }
});

test("ten second handoff deadline resumes browser and ignores late completion", async () => {
    const state = worker({ takeover: true });
    let expire;
    let delay;
    let finish;
    state.context.setTimeout = (callback, milliseconds) => { expire = callback; delay = milliseconds; return 1; };
    state.context.clearTimeout = () => {};
    state.api.tabs.create = () => new Promise(resolve => { finish = resolve; });
    const pending = intercept(state);
    await new Promise(resolve => setImmediate(resolve));
    assert.equal(delay, 10000);
    expire();
    await assert.rejects(pending, /handoffTimeout/);
    finish({ id: 9 });
    await new Promise(resolve => setImmediate(resolve));
    assert.deepEqual(state.calls.filter(call => ["pause", "resume", "cancel", "erase"].includes(call[0]))
        .map(call => call[0]), ["pause", "resume"]);
});

test("erase failure never tries to resume an already cancelled download", async () => {
    const state = worker({ takeover: true });
    state.api.downloads.erase = async () => { throw new Error("erase failed"); };
    await assert.rejects(intercept(state), /erase failed/);
    assert.equal(state.calls.at(-1)[0], "cancel");
    assert.equal(state.calls.some(call => call[0] === "resume"), false);
});

test("POST requests bypass takeover while GET and missing records can be handed off", async () => {
    for (const method of ["POST", "GET", undefined]) {
        const state = worker({ takeover: true });
        const listener = state.api.webRequest.onBeforeRequest.listeners[0];
        if (method) listener({ url: matchingDownload.url, tabId: 4, method, type: "main_frame" });
        await intercept(state);
        assert.equal(state.calls.some(call => call[0] === "pause"), method !== "POST");
    }
});

test("request matching checks original and redirected URL in the same tab", async () => {
    const state = worker({ takeover: true });
    state.api.webRequest.onBeforeRequest.listeners[0]({ url: matchingDownload.url, tabId: 4, method: "POST", type: "other" });
    await intercept(state, { ...matchingDownload, finalUrl: "https://cdn.example.org/a.zip" });
    assert.equal(state.calls.length, 0);
    await intercept(state, { ...matchingDownload, tabId: 5 });
    assert.equal(state.calls[0][0], "pause");
});

test("site exceptions match source page, original URL or redirected download URL", async () => {
    for (const fields of [
        { referrer: "https://page.example.com/start" },
        { url: "https://cdn.example.com/a.zip" },
        { finalUrl: "https://cdn.example.com/a.zip" }
    ]) {
        const state = worker({ takeover: true });
        state.api.storage.local.get = async defaults => ({ ...defaults, takeover: true, excludedSites: ["*.example.com"] });
        await intercept(state, { ...matchingDownload, ...fields });
        assert.equal(state.calls.length, 0);
    }
});

test("unsupported or rejected webRequest registration does not break downloads", async () => {
    const state = worker({ takeover: true });
    delete state.api.webRequest;
    state.api.permissions.onAdded.listeners[0]();
    state.api.webRequest = { onBeforeRequest: { hasListener: () => false, addListener: () => { throw new Error("unsupported"); } } };
    state.api.permissions.onAdded.listeners[0]();
    await intercept(state);
    assert.equal(state.calls[0][0], "pause");
});

test("popup saves normalized site exceptions and rejects invalid entries without writing", async () => {
    const state = await popup();
    state.nodes.get("excluded-sites").value = "Example.COM, *.example.org\nexample.com";
    await state.nodes.get("save").dispatch("click");
    assert.deepEqual(Array.from(state.stored.excludedSites), ["example.com", "*.example.org"]);
    assert.equal(state.nodes.get("excluded-sites").value, "example.com\n*.example.org");
    state.nodes.get("excluded-sites").value = "https://example.com/page";
    await state.nodes.get("save").dispatch("click");
    assert.deepEqual(Array.from(state.stored.excludedSites), ["example.com", "*.example.org"]);
});


test("Chrome native acknowledgement precedes cancel and rejection resumes without a protocol tab", async () => {
    for (const ok of [true, false]) {
        const state = worker({ takeover: true, native: true, scheme: "chrome-extension" });
        state.api.runtime.sendNativeMessage = async (host, message) => {
            state.calls.push(["native", host, message]);
            return { ok };
        };
        if (ok) await intercept(state);
        else await assert.rejects(intercept(state), /sendFailed/);
        assert.deepEqual(state.calls.map(call => call[0]), ok ? ["pause", "native", "cancel", "erase"] : ["pause", "native", "resume"]);
        assert.equal(state.calls[1][1], "com.cqagc.mulee.video_login");
        assert.equal(state.calls[1][2].type, "openLinks");
    }
});

test("Safari native failure resumes without falling back during takeover", async () => {
    for (const rejects of [false, true]) {
        const state = worker({ takeover: true, native: true });
        state.api.runtime.sendNativeMessage = async () => {
            if (rejects) throw new Error("unavailable");
            return { ok: false };
        };
        await assert.rejects(intercept(state), /sendFailed/);
        assert.deepEqual(state.calls.map(call => call[0]), ["pause", "resume"]);
    }
});

test("Chrome without native permission or installed host retains protocol handoff", async () => {
    for (const permission of [true, false]) {
        const state = worker({ takeover: true, native: true, scheme: "chrome-extension" });
        state.api.permissions.contains = async request => !request.permissions.includes("nativeMessaging") || permission;
        state.api.runtime.sendNativeMessage = async () => { throw new Error("Specified native messaging host not found."); };
        await intercept(state);
        assert.equal(state.calls.some(call => call[0] === "create"), true);
        assert.equal(state.calls.at(-1)[0], "erase");
    }
});

test("Chrome native transport errors resume without falling back", async () => {
    const state = worker({ takeover: true, native: true, scheme: "chrome-extension" });
    state.api.runtime.sendNativeMessage = async () => { throw new Error("host exited"); };
    await assert.rejects(intercept(state), /sendFailed/);
    assert.deepEqual(state.calls.map(call => call[0]), ["pause", "resume"]);
});

test("Chrome downloads without tab IDs still leave a recently recorded POST in the browser", async () => {
    const state = worker({ takeover: true });
    state.api.webRequest.onBeforeRequest.listeners[0]({ url: matchingDownload.url, tabId: 4, method: "POST" });
    const { tabId, ...item } = matchingDownload;
    await intercept(state, item);
    assert.equal(state.calls.length, 0);
});

test("denied optional method access keeps takeover enabled and saves domain exceptions", async () => {
    const state = await popup();
    state.api.permissions.request = async request => {
        state.permissionRequests.push(request);
        return !request.permissions.includes("webRequest");
    };
    state.nodes.get("takeover").checked = true;
    await state.nodes.get("takeover").dispatch("change");
    assert.equal(state.stored.takeover, true);
    assert.equal(state.permissionRequests.length, 2);
    assert.deepEqual(Array.from(state.permissionRequests[1].origins), ["http://*/*", "https://*/*"]);
    assert.ok(state.nodes.get("status").textContent.includes("still"));
});


test("resume failure never cancels or erases the paused browser download", async () => {
    const state = worker({ takeover: true });
    state.api.tabs.create = async () => { throw new Error("handoff failed"); };
    state.api.downloads.resume = async id => {
        state.calls.push(["resume", id]);
        throw new Error("resume failed");
    };
    await assert.rejects(intercept(state), /resume failed/);
    assert.deepEqual(state.calls.map(call => call[0]), ["pause", "resume"]);
});

test("session write failure cleans up the handoff tab and resumes", async () => {
    const state = worker({ takeover: true });
    state.api.storage.session.set = async () => { throw new Error("storage failed"); };
    const removed = [];
    state.api.tabs.remove = async id => removed.push(id);
    await assert.rejects(intercept(state), /storage failed/);
    assert.deepEqual(removed, [9]);
    assert.deepEqual(state.calls.map(call => call[0]), ["pause", "create", "resume"]);
});

test("malformed native acknowledgements never authorize cancellation", async () => {
    for (const response of [undefined, {}, { ok: "true" }]) {
        const state = worker({ takeover: true, native: true, scheme: "chrome-extension" });
        state.api.runtime.sendNativeMessage = async () => response;
        await assert.rejects(intercept(state), /sendFailed/);
        assert.deepEqual(state.calls.map(call => call[0]), ["pause", "resume"]);
    }
});

test("request listeners register once and permission revocation drops cached methods", async () => {
    const state = worker({ takeover: true });
    state.api.permissions.onAdded.listeners[0]();
    assert.equal(state.api.webRequest.onBeforeRequest.listeners.length, 1);
    state.api.webRequest.onBeforeRequest.listeners[0]({ url: matchingDownload.url, tabId: 4, method: "POST" });
    state.api.permissions.onRemoved.listeners[0]();
    await intercept(state);
    assert.equal(state.calls[0][0], "pause");
});


test("native handoff timeout resumes and a late ok cannot cancel the browser download", async () => {
    const state = worker({ takeover: true, native: true, scheme: "chrome-extension" });
    let expire;
    let complete;
    state.context.setTimeout = callback => { expire = callback; return 1; };
    state.context.clearTimeout = () => {};
    state.api.runtime.sendNativeMessage = () => new Promise(resolve => { complete = resolve; });
    const pending = intercept(state);
    await new Promise(resolve => setImmediate(resolve));
    expire();
    await assert.rejects(pending, /handoffTimeout/);
    complete({ ok: true });
    await new Promise(resolve => setImmediate(resolve));
    assert.deepEqual(state.calls.map(call => call[0]), ["pause", "resume"]);
});
