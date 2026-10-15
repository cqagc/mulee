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
        cookies: { getAll: async () => [] },
        action: { setBadgeText: () => {}, setTitle: () => {} },
        i18n: { getMessage: key => key },
        downloads: {
            onCreated: event(),
            cancel: async id => calls.push(["cancel", id])
        }
    };
    if (native) {
        api.runtime.sendNativeMessage = async (application, message) => {
            calls.push(["native", application, message]);
            return { ok: true };
        };
    }
    const context = { MuleeLinks: core, MuleeVideoLogin: login, console, [native ? "browser" : "chrome"]: api };
    vm.createContext(context);
    vm.runInContext(fs.readFileSync(path.join(__dirname, "../background.js"), "utf8"), context);
    return { api, calls, context };
}

test("download interception is inactive by default and never touches cookies", async () => {
    const { context, calls } = worker();
    await vm.runInContext('interceptDownload({ id: 1, state: "in_progress", url: "https://example.org/a.zip" })', context);
    assert.equal(calls.length, 0);
});

test("enabled interception cancels matching downloads before handing off with referrer", async () => {
    const { context, calls } = worker({ takeover: true });
    await vm.runInContext('interceptDownload({ id: 1, state: "in_progress", url: "https://example.org/a.zip", referrer: "https://example.org/page" })', context);
    assert.equal(calls[0][0], "cancel");
    const entry = calls.find(call => call[0] === "session")[1]["handoff-9"];
    assert.equal(new URL(entry).searchParams.get("referrer"), "https://example.org/page");
    assert.equal(new URL(entry).searchParams.get("url"), "https://example.org/a.zip");
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
    const locale = JSON.parse(fs.readFileSync(path.join(__dirname, "../_locales/en/messages.json"), "utf8"));
    let initialized;
    const ready = new Promise(resolve => { initialized = resolve; });
    const api = {
        i18n: {
            getMessage: (key, substitution) => locale[key]?.message.replace("$1", substitution) || "",
            getUILanguage: () => "en"
        },
        storage: { local: { get: async defaults => ({ ...defaults, videoLogin }), set: async () => {} } },
        permissions: { contains: async () => true, request: async () => true, remove: async () => {} },
        runtime: {
            getManifest: () => ({ optional_permissions: ["downloads", "cookies", "nativeMessaging"] }),
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
    const context = { document, chrome: api, MuleeLinks: core, MuleeVideoLogin: login };
    vm.createContext(context);
    vm.runInContext(fs.readFileSync(path.join(__dirname, "../popup.js"), "utf8"), context);
    await ready;
    return { nodes, inputs, messages };
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
    const keys = ["sendSelected", "selectAll", "selectNone", "videoLoginNotFound", "videoLoginReloadRequired"];
    for (const language of ["en", "ja", "zh_CN", "zh_TW"]) {
        const locale = JSON.parse(fs.readFileSync(path.join(__dirname, "../_locales", language, "messages.json"), "utf8"));
        for (const key of keys) assert.ok(locale[key].message, language + ": " + key);
        assert.ok(locale.sendSelected.message.includes("$1"));
        assert.ok(locale.videoLoginReloadRequired.message.includes("chrome://extensions"));
    }
});
