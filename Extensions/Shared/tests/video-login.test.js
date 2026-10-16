"use strict";

const test = require("node:test");
const assert = require("node:assert/strict");
const login = require("../video-login.js");

function fixture(enabled, granted = true, scheme = "chrome-extension") {
    const reads = [];
    const messages = [];
    return {
        reads, messages,
        api: {
            storage: { local: { get: async () => ({ videoLogin: enabled }) } },
            permissions: { contains: async () => granted },
            runtime: {
                getManifest: () => ({ optional_permissions: ["cookies", "nativeMessaging"] }),
                getURL: name => scheme + "://test-extension/" + name,
                sendNativeMessage: async (host, payload) => { messages.push({ host, payload }); return { ok: true }; }
            },
            cookies: { getAll: async ({ domain }) => {
                reads.push(domain);
                return [
                    { domain: "." + domain, path: "/", name: domain === "bilibili.com" ? "SESSDATA" : "test", value: "synthetic", secure: true, httpOnly: true, hostOnly: false },
                    { domain: ".example.org", path: "/", name: "forbidden", value: "synthetic", secure: true, httpOnly: false, hostOnly: false }
                ];
            } }
        }
    };
}

test("off or revoked permission never reads cookies", async () => {
    for (const [enabled, granted] of [[false, true], [true, false]]) {
        const state = fixture(enabled, granted);
        await login.transfer(state.api, ["https://www.bilibili.com/video/example"], true);
        assert.deepEqual(state.reads, []);
        assert.deepEqual(state.messages, []);
    }
});

test("explicit sync reads only the two permitted sites and filters foreign domains", async () => {
    const state = fixture(true);
    await login.transfer(state.api, [], true);
    assert.deepEqual(state.reads, ["bilibili.com", "youtube.com"]);
    assert.equal(state.messages.length, 2);
    for (const { host, payload } of state.messages) {
        assert.equal(host, "com.cqagc.mulee.video_login");
        assert.equal(payload.cookies.length, 1);
        assert.equal(payload.cookies[0].value, "synthetic");
        assert.equal(payload.url, undefined);
    }
});

test("sending links reads only the matching site", async () => {
    const state = fixture(true);
    await login.transfer(state.api, ["https://www.youtube.com/watch?v=example", "https://youtube.com.evil.org/a"]);
    assert.deepEqual(state.reads, ["youtube.com"]);
});

test("foreign links and domain lookalikes cannot trigger cookie reads", async () => {
    const state = fixture(true);
    await login.transfer(state.api, ["https://notyoutube.com/a", "https://youtube.com.evil.org/a", "file:///tmp/a"]);
    assert.deepEqual(state.reads, []);
    assert.equal(login.allowedDomain(".accounts.youtube.com", "youtube"), true);
    assert.equal(login.allowedDomain(".google.com", "youtube"), false);
});

test("native rejection fails closed without exposing host errors", async () => {
    const state = fixture(true);
    state.api.runtime.sendNativeMessage = async () => { throw new Error("synthetic credential"); };
    await assert.rejects(login.transfer(state.api, [], true), { message: "videoLoginFailed" });
});

test("known short links still read only the matching permitted cookie domain", async () => {
    const state = fixture(true);
    await login.transfer(state.api, ["https://b23.tv/example", "https://youtu.be/example"]);
    assert.deepEqual(state.reads, ["bilibili.com", "youtube.com"]);
});

test("Chrome exposing a browser namespace still uses the Chrome host", async () => {
    globalThis.browser = {};
    try {
        const state = fixture(true);
        await login.transfer(state.api, [], true);
        assert.ok(state.messages.length > 0);
        assert.ok(state.messages.every(({ host }) => host === "com.cqagc.mulee.video_login"));
    } finally {
        delete globalThis.browser;
    }
});

test("Safari uses the app extension host", async () => {
    const state = fixture(true, true, "safari-web-extension");
    await login.transfer(state.api, [], true);
    assert.ok(state.messages.length > 0);
    assert.ok(state.messages.every(({ host }) => host === "com.cqagc.mulee"));
});

test("automatic transfers skip empty cookies and explicit sync explains when neither site is signed in", async () => {
    const state = fixture(true);
    state.api.cookies.getAll = async () => [];
    await login.transfer(state.api, ["https://b23.tv/example", "https://youtu.be/example"]);
    assert.deepEqual(state.messages, []);
    await assert.rejects(login.transfer(state.api, [], true), { message: "videoLoginNotFound" });
    assert.deepEqual(state.messages, []);
});

test("explicit sync skips each empty site while still transferring the other", async () => {
    for (const signedIn of ["bilibili.com", "youtube.com"]) {
        const state = fixture(true);
        const getAll = state.api.cookies.getAll;
        state.api.cookies.getAll = query => query.domain === signedIn ? getAll(query) : Promise.resolve([]);
        await login.transfer(state.api, [], true);
        assert.equal(state.messages.length, 1);
        assert.equal(state.messages[0].payload.site + ".com", signedIn);
    }
});

test("Bilibili cookies without a permitted SESSDATA are never sent", async () => {
    const state = fixture(true);
    state.api.cookies.getAll = async () => [
        { domain: ".bilibili.com", path: "/", name: "buvid3", value: "synthetic" },
        { domain: ".example.org", path: "/", name: "SESSDATA", value: "synthetic" }
    ];
    await login.transfer(state.api, ["https://www.bilibili.com/video/example"]);
    assert.deepEqual(state.messages, []);
    await assert.rejects(login.transfer(state.api, [], true), { message: "videoLoginNotFound" });
    assert.deepEqual(state.messages, []);
});

test("anonymous Bilibili cookies do not stop a signed-in YouTube transfer", async () => {
    const state = fixture(true);
    const getAll = state.api.cookies.getAll;
    state.api.cookies.getAll = async query => (await getAll(query)).map(cookie => ({ ...cookie, name: "anonymous" }));
    await login.transfer(state.api, [], true);
    assert.equal(state.messages.length, 1);
    assert.equal(state.messages[0].payload.site, "youtube");
});

test("missing cookie or native messaging APIs return an actionable reload code", async () => {
    for (const remove of [
        api => { delete api.cookies; },
        api => { delete api.cookies.getAll; },
        api => { delete api.runtime.sendNativeMessage; }
    ]) {
        for (const explicit of [false, true]) {
            const state = fixture(true);
            remove(state.api);
            await assert.rejects(login.transfer(state.api, ["https://youtu.be/example"], explicit), { message: "videoLoginReloadRequired" });
            assert.deepEqual(state.reads, []);
            assert.deepEqual(state.messages, []);
        }
    }
});

test("unrelated downloads do not require cookie APIs and cookie read errors stay private", async () => {
    const state = fixture(true);
    state.api.cookies.getAll = async () => { throw new Error("synthetic credential"); };
    await assert.rejects(login.transfer(state.api, [], true), { message: "videoLoginFailed" });
    delete state.api.cookies;
    delete state.api.runtime.sendNativeMessage;
    await login.transfer(state.api, ["https://example.org/a.zip"]);
    assert.deepEqual(state.messages, []);
});

test("download cookies require both an explicit exact-site grant and browser permission", async () => {
    const download = login.downloadCookies;
    for (const [sites, granted] of [[[], true], [["https://example.org"], false],
        [["https://other.example.org"], true], [["http://example.org"], true], [["https://example.org:8443"], true]]) {
        const state = fixture(false, granted);
        state.api.storage.local.get = async () => ({ downloadCookieSites: sites });
        assert.equal(await download.transfer(state.api, "https://example.org/archive.zip"), null);
        assert.deepEqual(state.reads, []);
        assert.deepEqual(state.messages, []);
    }
});

test("download cookie permissions include only the current origin", () => {
    const request = login.downloadCookies.permissionRequest(fixture(false).api, "https://example.org/page");
    assert.deepEqual(request.origins, ["https://example.org/*"]);
    assert.deepEqual(request.permissions, ["cookies", "nativeMessaging"]);
    assert.equal(login.downloadCookies.siteOrigin("file:///temporary/a.zip"), null);
});

test("download tokens use sixteen cryptographically random bytes", () => {
    let length;
    const token = login.downloadCookies.createToken({ getRandomValues: bytes => {
        length = bytes.length;
        bytes.set(Array.from({ length: 16 }, (_, index) => index));
    } });
    assert.equal(length, 16);
    assert.equal(token, "000102030405060708090a0b0c0d0e0f");
    const crypto = require("node:crypto").webcrypto;
    assert.notEqual(login.downloadCookies.createToken(crypto), login.downloadCookies.createToken(crypto));
});

test("download handoff queries only the download URL and sends cookies through native messaging", async () => {
    const state = fixture(false);
    state.api.storage.local.get = async () => ({ downloadCookieSites: ["https://example.org"] });
    state.api.cookies.getAll = async query => {
        state.reads.push(query);
        return [{ name: "session", value: "synthetic-private" }];
    };
    const url = "https://example.org/private/archive.zip";
    const token = await login.downloadCookies.transfer(state.api, url);
    assert.match(token, /^[a-f0-9]{32}$/);
    assert.deepEqual(state.reads, [{ url }]);
    assert.equal(state.messages.length, 1);
    assert.equal(state.messages[0].payload.token, token);
    assert.equal(state.messages[0].payload.type, "downloadCookies");
    assert.equal(state.messages[0].payload.cookie, "session=synthetic-private");
    assert.equal(state.messages[0].payload.url, url);
});

test("download native errors and malformed cookies never expose cookie contents", async () => {
    const state = fixture(false);
    state.api.storage.local.get = async () => ({ downloadCookieSites: ["https://example.org"] });
    state.api.cookies.getAll = async () => [{ name: "session", value: "synthetic-private" }];
    state.api.runtime.sendNativeMessage = async () => { throw new Error("synthetic-private"); };
    await assert.rejects(login.downloadCookies.transfer(state.api, "https://example.org/a.zip"), { message: "downloadCookiesFailed" });
    state.api.cookies.getAll = async () => [{ name: "session", value: "synthetic-private\r\nInjected: true" }];
    await assert.rejects(login.downloadCookies.transfer(state.api, "https://example.org/a.zip"), { message: "downloadCookiesFailed" });
    assert.deepEqual(state.messages, []);
});

test("Safari download cookies reuse the app extension host without requesting native permission", async () => {
    const state = fixture(false, true, "safari-web-extension");
    state.api.runtime.getManifest = () => ({ optional_permissions: ["cookies"] });
    state.api.storage.local.get = async () => ({ downloadCookieSites: ["https://example.org"] });
    state.api.cookies.getAll = async () => [{ name: "session", value: "synthetic-private" }];
    assert.deepEqual(login.downloadCookies.permissionRequest(state.api, "https://example.org/page"), {
        permissions: ["cookies"], origins: ["https://example.org/*"]
    });
    const token = await login.downloadCookies.transfer(state.api, "https://example.org/a.zip");
    assert.equal(state.messages[0].host, "com.cqagc.mulee");
    assert.equal(state.messages[0].payload.token, token);
});
