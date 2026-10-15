"use strict";

const test = require("node:test");
const assert = require("node:assert/strict");
const vm = require("node:vm");
const fs = require("node:fs");
const path = require("node:path");
const core = require("../core.js");

function event() {
    const listeners = [];
    return {
        listeners,
        addListener: listener => listeners.push(listener),
        hasListener: listener => listeners.includes(listener)
    };
}

function worker({ takeover = false, native = false } = {}) {
    const calls = [];
    const api = {
        runtime: {
            id: "test-extension",
            onInstalled: event(),
            onMessage: event(),
            getURL: name => "chrome-extension://test-extension/" + name
        },
        tabs: {
            onRemoved: event(),
            create: async value => { calls.push(["create", value]); return { id: 9 }; },
            sendMessage: async () => {}
        },
        storage: {
            local: { get: async defaults => ({ ...defaults, takeover }) },
            session: {
                set: async value => calls.push(["session", value]),
                remove: async () => {}
            }
        },
        contextMenus: { onClicked: event() },
        permissions: { onAdded: event(), onRemoved: event() },
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
    const context = { MuleeLinks: core, console, [native ? "browser" : "chrome"]: api };
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
