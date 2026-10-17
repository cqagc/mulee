/* Shared, dependency-free link recognition and Mulee URL construction. */
(function (root) {
    "use strict";

    const maximumLinks = 200;
    const maximumBytes = 1048576;
    const defaultExtensions = "zip rar 7z tar gz bz2 xz iso img dmg pkg exe msi mp4 mkv mov avi webm torrent";
    const fileExtensions = new Set((defaultExtensions + " mp3 flac wav aac ogg m4a pdf epub doc docx xls xlsx ppt pptx deb rpm zst tgz vhd vhdx").split(" "));
    const bilibiliTracking = new Set(("track_id trackid spm_id_from from_spmid from_source from vd_source share_source share_medium share_plat "
        + "share_session_id share_tag share_from bbid ts unique_k timestamp buvid is_story_h5 mid plat_id up_id msource seid session_id rt spmid").split(" "));
    const youtubeTracking = new Set(["si", "pp", "feature", "ab_channel"]);

    function extensionList(value) {
        return [...new Set(String(value).toLowerCase().split(/[\s,;，；]+/)
            .map(item => item.replace(/^\./, "")).filter(item => /^[a-z0-9]+$/.test(item)))];
    }

    function excludedSiteList(value) {
        const entries = Array.isArray(value) ? value : String(value).split(/[\s,;，；]+/);
        const result = [];
        for (const entry of entries) {
            if (!entry) continue;
            const wildcard = entry.startsWith("*.");
            const domain = wildcard ? entry.slice(2) : entry;
            if (!domain || /[\\/:?#@%\s*]/.test(domain)) throw new Error("invalidExcludedSites");
            let host;
            try {
                host = new URL("https://" + domain).hostname.toLowerCase().replace(/\.$/, "");
            } catch {
                throw new Error("invalidExcludedSites");
            }
            if (!host.split(".").every(label => /^[a-z0-9](?:[a-z0-9-]*[a-z0-9])?$/.test(label))) {
                throw new Error("invalidExcludedSites");
            }
            result.push((wildcard ? "*." : "") + host);
        }
        return [...new Set(result)];
    }

    function isExcludedSite(value, sites) {
        try {
            const host = new URL(value).hostname.toLowerCase().replace(/\.$/, "");
            return sites.some(site => site.startsWith("*.")
                ? host.endsWith(site.slice(1)) : host === site);
        } catch {
            return false;
        }
    }

    function requestMethods(now = () => Date.now()) {
        const records = new Map();
        const key = (url, tabID) => JSON.stringify([url, tabID]);
        function prune() {
            const cutoff = now() - 60000;
            for (const [id, record] of records) {
                if (record.time <= cutoff) records.delete(id);
            }
        }
        return {
            record(details) {
                prune();
                const id = key(details.url, details.tabId);
                records.delete(id);
                records.set(id, { url: details.url, method: details.method.toUpperCase(), time: now() });
                while (records.size > 200) records.delete(records.keys().next().value);
            },
            get(url, tabID) {
                prune();
                if (Number.isInteger(tabID)) return records.get(key(url, tabID))?.method;
                // Chrome 的 DownloadItem 没有 tabId；有任一非 GET 记录就留给浏览器。
                const matches = [...records.values()].filter(record => record.url === url);
                return matches.find(record => record.method !== "GET")?.method || matches.at(-1)?.method;
            },
            clear() {
                records.clear();
            }
        };
    }

    function remoteLink(value, depth = 0) {
        if (typeof value !== "string" || depth > 4 || /[\r\n\t\u0000]/.test(value)) return false;
        if (/^ed2k:\/\/\|file\|[^|]+\|[1-9]\d*\|[a-f0-9]{32}\|(?:[a-z]=[^|\s]+\|)*\/$/i.test(value)) return true;
        if (/\s/.test(value)) return false;
        if (/^thunder:\/\//i.test(value)) {
            try {
                const decoded = new TextDecoder("utf-8", { fatal: true }).decode(
                    Uint8Array.from(atob(value.slice(10)), character => character.charCodeAt(0))
                );
                return decoded.startsWith("AA") && decoded.endsWith("ZZ") && remoteLink(decoded.slice(2, -2), depth + 1);
            } catch {
                return false;
            }
        }
        try {
            const url = new URL(value);
            if (url.protocol === "magnet:") {
                return /^urn:btih:(?:[a-f0-9]{40}|[a-z2-7]{32})$/i.test(url.searchParams.get("xt") || "");
            }
            return ["http:", "https:", "ftp:"].includes(url.protocol) && Boolean(url.hostname);
        } catch {
            return false;
        }
    }

    function isVideoPage(value) {
        try {
            const url = new URL(value);
            const host = url.hostname.toLowerCase();
            if (!["http:", "https:"].includes(url.protocol)) return false;
            return (host === "youtu.be" && url.pathname.length > 1)
                || ((host === "youtube.com" || host.endsWith(".youtube.com"))
                    && ((url.pathname === "/watch" && Boolean(url.searchParams.get("v"))) || /^\/(shorts|live)\/[^/]+/.test(url.pathname)))
                || ((host === "bilibili.com" || host.endsWith(".bilibili.com")) && /^\/(video|bangumi\/play)\/[^/]+/.test(url.pathname))
                || (host === "b23.tv" && url.pathname.length > 1);
        } catch {
            return false;
        }
    }

    function hasExtension(value, extensions) {
        try {
            const path = decodeURIComponent(new URL(value).pathname).toLowerCase();
            return extensions.some(extension => path.endsWith("." + extension));
        } catch {
            return false;
        }
    }

    function isDownloadable(value) {
        return remoteLink(value) && (/^(magnet:|ed2k:|thunder:)/i.test(value)
            || hasExtension(value, [...fileExtensions]) || isVideoPage(value));
    }

    function normalizeURL(value) {
        try {
            const url = new URL(value);
            if (!["http:", "https:", "ftp:"].includes(url.protocol)) return value;
            const host = url.hostname.toLowerCase();
            const matches = domain => host === domain || host.endsWith("." + domain);
            const tracking = matches("bilibili.com") || matches("b23.tv") ? bilibiliTracking
                : matches("youtube.com") || matches("youtu.be") ? youtubeTracking : new Set();
            const queryStart = value.indexOf("?");
            const fragmentStart = value.indexOf("#");
            if (queryStart < 0 || (fragmentStart >= 0 && fragmentStart < queryStart)) return value;
            const queryEnd = fragmentStart < 0 ? value.length : fragmentStart;
            const parameters = value.slice(queryStart + 1, queryEnd).split("&");
            const retained = parameters.filter(parameter => {
                const key = new URLSearchParams("key=" + parameter.split("=", 1)[0]).get("key") || "";
                return !key.startsWith("utm_") && key !== "fbclid" && key !== "gclid" && !tracking.has(key);
            });
            if (retained.length === parameters.length) return value;
            // Preserve all remaining query bytes: download URLs may contain signatures.
            const query = retained.join("&");
            return value.slice(0, queryStart) + (query ? "?" + query : "") + value.slice(queryEnd);
        } catch {
            return value;
        }
    }

    function trimPunctuation(value) {
        let result = value.replace(/[，。；：！？、….,;!?]+$/u, "");
        const pairs = { ")": "(", "]": "[", "}": "{", "）": "（", "】": "【", "》": "《" };
        while (result && pairs[result.at(-1)]) {
            const close = result.at(-1);
            const open = pairs[close];
            if (result.split(close).length <= result.split(open).length) break;
            result = result.slice(0, -1);
        }
        return result;
    }

    function extractLinks(text) {
        const matches = String(text).match(/ed2k:\/\/\|file\|[^\r\n]*?\|\/|(?:https?:\/\/|ftp:\/\/|magnet:\?|thunder:\/\/)[^\s<>"，。；：！？、…]+/gi) || [];
        return [...new Set(matches.map(trimPunctuation)
            .filter(value => remoteLink(value)).map(normalizeURL))];
    }

    function collectLinks(hrefs, text, pageURL) {
        return [...new Set([...hrefs, ...extractLinks(text), pageURL].filter(isDownloadable).map(normalizeURL))];
    }

    function buildBatches(links, referrer = "", text = "", context = {}) {
        if (!Array.isArray(links) || !links.length || !links.every(value => remoteLink(value))) {
            throw new Error("invalidLinks");
        }
        let source = "";
        try {
            const url = new URL(referrer);
            if (["http:", "https:"].includes(url.protocol)) source = normalizeURL(referrer);
        } catch {
            // Browser-internal pages are not valid referrers.
        }
        const userAgent = typeof context.userAgent === "string" && !/[\r\n\u0000]/.test(context.userAgent)
            ? context.userAgent : "";
        const filename = typeof context.filename === "string" ? context.filename.split(/[\\/]/).at(-1) : "";
        const token = /^[a-f0-9]{32}$/.test(context.token || "") ? context.token : "";
        const suffix = (source ? "&referrer=" + encodeURIComponent(source) : "")
            + (text ? "&text=" + encodeURIComponent(text) : "")
            + (userAgent ? "&ua=" + encodeURIComponent(userAgent) : "")
            + (filename ? "&filename=" + encodeURIComponent(filename) : "")
            + (token ? "&token=" + token : "");
        const prefix = "mulee://add?";
        const batches = [];
        let parameters = [];
        let size = prefix.length + suffix.length;
        for (const link of [...new Set(links.map(normalizeURL))]) {
            const parameter = "url=" + encodeURIComponent(link);
            if (prefix.length + suffix.length + parameter.length > maximumBytes) throw new Error("tooLarge");
            if (parameters.length === maximumLinks || size + parameter.length + (parameters.length ? 1 : 0) > maximumBytes) {
                batches.push(prefix + parameters.join("&") + suffix);
                parameters = [];
                size = prefix.length + suffix.length;
            }
            size += parameter.length + (parameters.length ? 1 : 0);
            parameters.push(parameter);
        }
        if (parameters.length) batches.push(prefix + parameters.join("&") + suffix);
        return batches;
    }

    const api = { maximumLinks, maximumBytes, defaultExtensions, extensionList, excludedSiteList, isExcludedSite, requestMethods, remoteLink,
        isVideoPage, hasExtension, isDownloadable, normalizeURL, extractLinks, collectLinks, buildBatches };
    root.MuleeLinks = api;
    if (typeof module !== "undefined") module.exports = api;
})(globalThis);
