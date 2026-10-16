"use strict";

(function (root) {
    const origins = ["https://*.bilibili.com/*", "https://*.youtube.com/*"];
    const sites = ["bilibili", "youtube"];

    function permissionRequest(api) {
        const optional = api.runtime.getManifest().optional_permissions || [];
        return { permissions: ["cookies", ...(optional.includes("nativeMessaging") ? ["nativeMessaging"] : [])], origins };
    }

    function allowedDomain(domain, site) {
        const host = domain.replace(/^\./, "");
        const base = site + ".com";
        return host === base || host.endsWith("." + base);
    }

    async function transfer(api, links, explicit = false) {
        const settings = await api.storage.local.get({ videoLogin: false });
        if (!settings.videoLogin || !await api.permissions.contains(permissionRequest(api))) return;
        let transferred = 0;
        for (const site of sites) {
            if (!explicit && !links.some(link => {
                try {
                    const host = new URL(link).hostname;
                    return allowedDomain(host, site) || host === (site === "bilibili" ? "b23.tv" : "youtu.be");
                } catch { return false; }
            })) continue;
            if (typeof api.cookies?.getAll !== "function" || typeof api.runtime.sendNativeMessage !== "function") {
                throw new Error("videoLoginReloadRequired");
            }
            let storedCookies;
            try {
                storedCookies = await api.cookies.getAll({ domain: site + ".com" });
            } catch { throw new Error("videoLoginFailed"); }
            const cookies = storedCookies
                .filter(cookie => allowedDomain(cookie.domain, site))
                .map(cookie => ({
                    domain: cookie.domain, path: cookie.path, name: cookie.name, value: cookie.value,
                    secure: cookie.secure, httpOnly: cookie.httpOnly, hostOnly: cookie.hostOnly,
                    ...(cookie.expirationDate === undefined ? {} : { expirationDate: cookie.expirationDate })
                }));
            if (!cookies.length || (site === "bilibili" && !cookies.some(cookie => cookie.name === "SESSDATA"))) continue;
            if (cookies.length > 256) throw new Error("videoLoginFailed");
            const request = { type: "videoCookies", site, cookies };
            if (new TextEncoder().encode(JSON.stringify(request)).length > 524288) throw new Error("videoLoginFailed");
            // Cookie 不写入 URL、storage 或控制台；失败不回退到 URL 通道。
            let response;
            try {
                // Chrome 也提供 browser 命名空间，只能按扩展 URL 的协议区分 Safari。
                const safari = api.runtime.getURL("").startsWith("safari-web-extension:");
                response = await api.runtime.sendNativeMessage(safari ? "com.cqagc.mulee" : "com.cqagc.mulee.video_login", request);
            } catch { throw new Error("videoLoginFailed"); }
            if (!response?.ok) throw new Error("videoLoginFailed");
            transferred++;
        }
        if (explicit && !transferred) throw new Error("videoLoginNotFound");
    }

    const api = { permissionRequest, allowedDomain, transfer };
    root.MuleeVideoLogin = api;
    if (typeof module !== "undefined") module.exports = api;
})(globalThis);

// 下载登录状态独立按精确站点授权，不复用视频登录开关或广域权限。
(function (root) {
    "use strict";

    function siteOrigin(value) {
        try {
            const url = new URL(value);
            return ["http:", "https:"].includes(url.protocol) && !url.username && !url.password
                ? url.origin : null;
        } catch { return null; }
    }

    function permissionRequest(api, value) {
        const origin = siteOrigin(value);
        if (!origin) throw new Error("downloadCookiesUnavailable");
        const optional = api.runtime.getManifest().optional_permissions || [];
        return {
            permissions: ["cookies", ...(optional.includes("nativeMessaging") ? ["nativeMessaging"] : [])],
            origins: [origin + "/*"]
        };
    }

    function createToken(cryptoAPI = root.crypto) {
        const bytes = new Uint8Array(16);
        cryptoAPI.getRandomValues(bytes);
        return Array.from(bytes, byte => byte.toString(16).padStart(2, "0")).join("");
    }

    async function isAuthorized(api, value) {
        const origin = siteOrigin(value);
        if (!origin) return false;
        const settings = await api.storage.local.get({ downloadCookieSites: [] });
        return settings.downloadCookieSites.includes(origin)
            && await api.permissions.contains(permissionRequest(api, value));
    }

    async function transfer(api, value) {
        if (!await isAuthorized(api, value)) return null;
        try {
            const cookies = await api.cookies.getAll({ url: value });
            if (!cookies.length) return null;
            const cookie = cookies.map(item => {
                if (!/^[!#$%&'*+.^_`|~0-9A-Za-z-]+$/.test(item.name)
                    || /[;\r\n\u0000-\u001f\u007f]/.test(item.value)) throw new Error();
                return item.name + "=" + item.value;
            }).join("; ");
            const token = createToken();
            const request = { type: "downloadCookies", token, url: value, cookie };
            if (new TextEncoder().encode(JSON.stringify(request)).length > 65536) throw new Error();
            const safari = api.runtime.getURL("").startsWith("safari-web-extension:");
            const response = await api.runtime.sendNativeMessage(
                safari ? "com.cqagc.mulee" : "com.cqagc.mulee.video_login", request
            );
            if (!response?.ok) throw new Error();
            return token;
        } catch {
            // 浏览器异常可能包含 Cookie；只向调用方返回固定错误码。
            throw new Error("downloadCookiesFailed");
        }
    }

    root.MuleeDownloadCookies = { siteOrigin, permissionRequest, createToken, isAuthorized, transfer };
    if (typeof module !== "undefined") module.exports.downloadCookies = root.MuleeDownloadCookies;
})(globalThis);
