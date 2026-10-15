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
