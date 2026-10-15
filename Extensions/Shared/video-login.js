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
        for (const site of sites) {
            if (!explicit && !links.some(link => {
                try {
                    const host = new URL(link).hostname;
                    return allowedDomain(host, site) || host === (site === "bilibili" ? "b23.tv" : "youtu.be");
                } catch { return false; }
            })) continue;
            const cookies = (await api.cookies.getAll({ domain: site + ".com" }))
                .filter(cookie => allowedDomain(cookie.domain, site))
                .map(cookie => ({
                    domain: cookie.domain, path: cookie.path, name: cookie.name, value: cookie.value,
                    secure: cookie.secure, httpOnly: cookie.httpOnly, hostOnly: cookie.hostOnly,
                    ...(cookie.expirationDate === undefined ? {} : { expirationDate: cookie.expirationDate })
                }));
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
        }
    }

    const api = { permissionRequest, allowedDomain, transfer };
    root.MuleeVideoLogin = api;
    if (typeof module !== "undefined") module.exports = api;
})(globalThis);
