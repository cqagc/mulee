"use strict";

const test = require("node:test");
const assert = require("node:assert/strict");
const links = require("../core.js");
const magnet = "magnet:?xt=urn:btih:" + "a".repeat(40);
const ed2k = "ed2k://|file|Sintel archive.zip|1024|" + "a".repeat(32) + "|/";
const thunder = value => "thunder://" + Buffer.from("AA" + value + "ZZ").toString("base64");

test("recognizes remote schemes and rejects local, embedded and malformed input", () => {
    for (const value of [magnet, ed2k, thunder("https://example.org/a.zip"), "ftp://example.org/a.iso"]) {
        assert.equal(links.remoteLink(value), true, value);
    }
    for (const value of ["file:///tmp/a.torrent", "/tmp/a.torrent", "javascript:alert(1)",
        "https://example.org/a.zip\nfile:///tmp/a.torrent", "magnet:?xt=broken", "https://", thunder("file:///tmp/a.torrent"),
        thunder("https://example.org/a.zip\nfile:///tmp/a.torrent"), "thunder://broken"]) {
        assert.equal(links.remoteLink(value), false, value);
    }
});

test("extracts selected links, preserves ed2k filenames with spaces and removes duplicates", () => {
    const values = [magnet, ed2k, "https://example.org/a.zip", thunder("https://example.org/b.zip"),
        "http://example.org/c.pdf", "https://example.org/d.iso", "https://example.org/e.zip"];
    assert.deepEqual(links.extractLinks("密码：abc123，" + values.join("\n") + "\n" + magnet), values);
});

test("recognizes file extensions with queries, case and encoded paths", () => {
    for (const value of ["https://example.org/a.ZIP?token=1", "https://example.org/a.%37z", "https://example.org/a.torrent#hash"]) {
        assert.equal(links.isDownloadable(value), true);
    }
    assert.equal(links.isDownloadable("https://example.org/a.zip.html"), false);
    assert.equal(links.isDownloadable("https://example.org/about"), false);
});

test("recognizes video pages without accepting lookalike hosts or home pages", () => {
    for (const value of ["https://www.youtube.com/watch?v=abc", "https://youtu.be/abc", "https://m.youtube.com/shorts/abc",
        "https://www.bilibili.com/video/BVexample", "https://www.bilibili.com/bangumi/play/ep1", "https://b23.tv/abc"]) {
        assert.equal(links.isVideoPage(value), true, value);
    }
    for (const value of ["https://youtube.com", "https://youtube.com.evil.org/watch?v=abc", "https://evilbilibili.com/video/x"]) {
        assert.equal(links.isVideoPage(value), false, value);
    }
});

test("page collection deduplicates and includes the current video page", () => {
    const page = "https://youtube.com/watch?v=abc";
    assert.deepEqual(links.collectLinks([magnet, "https://example.org/about"], magnet + "\n" + ed2k, page), [magnet, ed2k, page]);
});

test("URL encoding round-trips reserved characters, referrer and selected password text", () => {
    const url = "https://example.org/资料.zip?a=1&b=2+3#hash";
    const referrer = "https://example.org/page?q=a&b=中";
    const text = "密码：abc+123 & 😀";
    const [entry] = links.buildBatches([url, magnet], referrer, text);
    const query = new URL(entry).searchParams;
    assert.deepEqual(query.getAll("url"), [url, magnet]);
    assert.equal(query.get("referrer"), referrer);
    assert.equal(query.get("text"), text);
    assert.equal(Buffer.byteLength(entry), entry.length);
});

test("count limits split at 200 without losing or reordering links", () => {
    const values = Array.from({ length: 401 }, (_, index) => `https://example.org/${index}.zip`);
    const batches = links.buildBatches(values, "https://example.org/page", "password: secret");
    assert.deepEqual(batches.map(value => new URL(value).searchParams.getAll("url").length), [200, 200, 1]);
    assert.deepEqual(batches.flatMap(value => new URL(value).searchParams.getAll("url")), values);
    for (const value of batches) assert.equal(new URL(value).searchParams.get("text"), "password: secret");
});

test("byte limits split before 1 MiB and preserve all links", () => {
    const values = Array.from({ length: 8 }, (_, index) => `https://example.org/${index}.zip?q=` + "中".repeat(20000));
    const batches = links.buildBatches(values);
    assert.ok(batches.length > 1);
    for (const batch of batches) assert.ok(Buffer.byteLength(batch) <= links.maximumBytes);
    assert.deepEqual(batches.flatMap(value => new URL(value).searchParams.getAll("url")), values);
});

test("exact 1 MiB boundary succeeds, the next byte is rejected", () => {
    const base = "https://example.org/a.zip?q=";
    const overhead = links.buildBatches([base])[0].length;
    const exact = base + "a".repeat(links.maximumBytes - overhead);
    assert.equal(links.buildBatches([exact])[0].length, links.maximumBytes);
    assert.throws(() => links.buildBatches([exact + "a"]), /tooLarge/);
});

test("oversized metadata or a single link fails before sending any partial batch", () => {
    assert.throws(() => links.buildBatches([magnet], "", "中".repeat(120000)), /tooLarge/);
    assert.throws(() => links.buildBatches([magnet, "https://example.org/" + "a".repeat(links.maximumBytes)]), /tooLarge/);
    assert.throws(() => links.buildBatches([]), /invalidLinks/);
    assert.throws(() => links.buildBatches([magnet, "file:///tmp/a.torrent"]), /invalidLinks/);
});

test("invalid referrers are omitted, duplicates removed, interception list normalized", () => {
    const [entry] = links.buildBatches([magnet, magnet], "file:///tmp/private", "");
    assert.equal(new URL(entry).searchParams.has("referrer"), false);
    assert.deepEqual(new URL(entry).searchParams.getAll("url"), [magnet]);
    assert.deepEqual(links.extensionList(".ZIP, rar；7z zip /tmp exe* mp4"), ["zip", "rar", "7z", "mp4"]);
    assert.equal(links.hasExtension("https://example.org/a.zip?x=1", ["zip"]), true);
});

test("selected text trims unmatched wrappers while preserving balanced URL parentheses", () => {
    assert.deepEqual(links.extractLinks("(" + magnet + ")"), [magnet]);
    assert.deepEqual(links.extractLinks("（https://example.org/a(1).zip）"), ["https://example.org/a(1).zip"]);
});

test("Bilibili tracking is removed while parts, timestamps and season identifiers survive", () => {
    const tracking = "track_id trackid spm_id_from from_spmid from_source from vd_source share_source share_medium share_plat "
        + "share_session_id share_tag share_from bbid ts unique_k timestamp buvid is_story_h5 mid plat_id up_id msource seid session_id rt spmid";
    for (const base of ["https://www.bilibili.com/video/BVexample", "https://www.bilibili.com/bangumi/play/ep123", "https://b23.tv/example"]) {
        const retained = base + "?p=2&t=90&ep_id=123&season_id=456&season_type=1&custom=a%20b&TRACK_ID=keep";
        const input = retained + "&" + tracking.split(" ").map(key => key + "=tracking").join("&") + "&utm_source=share#part";
        assert.equal(links.normalizeURL(input), retained + "#part");
        assert.equal(links.normalizeURL(links.normalizeURL(input)), retained + "#part");
    }
});

test("YouTube tracking is removed without changing video, playlist, index or time", () => {
    for (const base of ["https://www.youtube.com/watch", "https://m.youtube.com/watch", "https://youtu.be/example"]) {
        const retained = base + "?v=example&list=playlist&index=3&t=1m2s&custom=keep";
        assert.equal(links.normalizeURL(retained + "&si=share&pp=feed&feature=share&ab_channel=channel&utm_medium=web&fbclid=x&gclid=y"), retained);
    }
});

test("unknown sites keep queries byte for byte except explicitly global tracking parameters", () => {
    const query = "token=a%2fb+z&signature=X%20Y&track_id=keep&from=keep&si=keep&v=1&list=2&flag&token=second&?utm_source=keep";
    for (const host of ["example.org", "bilibili.com.evil.org", "notyoutube.com", "youtu.be.evil.org"]) {
        const value = "https://" + host + "/资料.zip?" + query + "#fragment?utm_source=keep";
        assert.equal(links.normalizeURL(value), value);
        const tracked = "https://" + host + "/资料.zip?utm_source=remove&" + query + "&fbclid=x&gclid=y&utm_campaign=z#fragment";
        assert.equal(links.normalizeURL(tracked), "https://" + host + "/资料.zip?" + query + "#fragment");
    }
    assert.equal(links.normalizeURL("https://example.org/a.zip?utm_source=x#file"), "https://example.org/a.zip#file");
    assert.equal(links.normalizeURL("https://example.org/a.zip#file?utm_source=keep"), "https://example.org/a.zip#file?utm_source=keep");
    for (const value of [magnet, ed2k, thunder("https://example.org/a.zip"), "invalid"]) {
        assert.equal(links.normalizeURL(value), value);
    }
});

test("collection, selection extraction and handoff deduplicate normalized URLs", () => {
    const base = "https://www.bilibili.com/video/BVexample?p=2&t=30";
    const otherPart = "https://www.bilibili.com/video/BVexample?p=3&t=30";
    const variants = [base + "&track_id=a", base + "&trackid=b", base];
    assert.deepEqual(links.collectLinks(variants, variants.join("\n"), base + "&from_spmid=c"), [base]);
    assert.deepEqual(links.extractLinks([...variants, otherPart].join("\n")), [base, otherPart]);
    const [entry] = links.buildBatches([...variants, otherPart], base + "&vd_source=d");
    assert.deepEqual(new URL(entry).searchParams.getAll("url"), [base, otherPart]);
    assert.equal(new URL(entry).searchParams.get("referrer"), base);
});


test("handoff context encodes request metadata and only accepts a 128-bit token", () => {
    // 合成的 128 位十六进制值，只用来验证格式。
    const token = Array.from({ length: 32 }, (_, i) => (i % 16).toString(16)).join("");
    const [entry] = links.buildBatches(["https://example.org/a.zip"], "https://example.org/page", "", {
        userAgent: "Synthetic Browser/1.0", filename: "/temporary/a file.zip", token, cookie: "synthetic-private"
    });
    const query = new URL(entry).searchParams;
    assert.equal(query.get("ua"), "Synthetic Browser/1.0");
    assert.equal(query.get("filename"), "a file.zip");
    assert.equal(query.get("token"), token);
    assert.equal(entry.includes("synthetic-private"), false);
    assert.equal(query.has("cookie"), false);
    const [invalid] = links.buildBatches(["https://example.org/a.zip"], "", "", { token: "short" });
    assert.equal(new URL(invalid).searchParams.has("token"), false);
});


test("site exceptions normalize domains and use bounded subdomain wildcards", () => {
    const sites = links.excludedSiteList("Example.COM, *.example.org example.com");
    assert.deepEqual(sites, ["example.com", "*.example.org"]);
    for (const url of ["https://example.com/a", "https://cdn.example.org/a", "https://a.b.example.org/a"]) {
        assert.equal(links.isExcludedSite(url, sites), true);
    }
    for (const url of ["https://otherexample.com/a", "https://example.org/a", "https://example.org.evil.test/a", "invalid"]) {
        assert.equal(links.isExcludedSite(url, sites), false);
    }
    assert.deepEqual(links.excludedSiteList(""), []);
    for (const value of ["https://example.com", "example.com/path", "*example.com", "example.*", "-example.com", "example.com\\path", "%65xample.com"]) {
        assert.throws(() => links.excludedSiteList(value), /invalidExcludedSites/);
    }
});

test("request method records retain 200 latest URL and tab pairs for sixty seconds", () => {
    let time = 0;
    const methods = links.requestMethods(() => time);
    const details = { url: "https://example.org/a.zip", tabId: 1, method: "POST" };
    methods.record(details);
    assert.equal(methods.get(details.url, 1), "POST");
    assert.equal(methods.get(details.url, 2), undefined);
    time = 59999;
    assert.equal(methods.get(details.url, 1), "POST");
    time = 60000;
    assert.equal(methods.get(details.url, 1), undefined);
    for (let index = 0; index <= 200; index++) methods.record({ ...details, tabId: index });
    assert.equal(methods.get(details.url, 0), undefined);
    assert.equal(methods.get(details.url, 1), "POST");
    methods.record({ ...details, tabId: 1, method: "get" });
    methods.record({ ...details, tabId: 201 });
    assert.equal(methods.get(details.url, 1), "GET");
    assert.equal(methods.get(details.url, 2), undefined);
    methods.clear();
    assert.equal(methods.get(details.url, 1), undefined);
});
