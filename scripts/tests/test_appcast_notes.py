"""离线验证 appcast 发版说明生成及签名字段保留。"""
import pathlib
import runpy
import subprocess
import sys
import tempfile
import unittest
import xml.etree.ElementTree as ET

SCRIPT = pathlib.Path(__file__).resolve().parents[1] / "appcast-notes.py"
UPDATE = runpy.run_path(str(SCRIPT))["update_appcast"]
SPARKLE = "http://www.andymatuschak.org/xml-namespaces/sparkle"
ENCLOSURE = (
    '<enclosure url="https://example.org/Mulee.dmg?a=1&amp;b=2"\n'
    '      length="123" type="application/octet-stream" sparkle:edSignature="fake-signature==" />'
)
APPCAST = f'''<?xml version="1.0" encoding="utf-8"?>
<rss version="2.0" xmlns:sparkle="{SPARKLE}">
  <channel>
    <item>
      <title>Mulee 0.4.2</title>
      <sparkle:shortVersionString>0.4.2</sparkle:shortVersionString>
      <sparkle:releaseNotesLink>https://example.org/old</sparkle:releaseNotesLink>
      <description>Old notes</description>
      <sparkle:fullReleaseNotesLink>https://example.org/history</sparkle:fullReleaseNotesLink>
      {ENCLOSURE}
    </item>
  </channel>
</rss>
'''
NOTES = '''发版说明

**0.4.2 的变化**
- 修复「**下载**」与“窗口”里的 <>&。
- 支持 `a < b & c`。
  保留续行。

以下是全部功能。
- 不应包含这条完整功能。

**Changes in 0.4.2**
* Fix **downloads** with <>& and "quotes".
1. Keep `inline code`.

Full feature list:
- Excluded full feature.
'''


class AppcastNotesTests(unittest.TestCase):
    def setUp(self):
        self.directory = tempfile.TemporaryDirectory()
        self.addCleanup(self.directory.cleanup)
        self.appcast = pathlib.Path(self.directory.name) / "appcast.xml"
        self.appcast.write_text(APPCAST, encoding="utf-8")

    def descriptions(self):
        return ET.parse(self.appcast).findall("./channel/item/description")

    def assert_rejected(self, notes):
        before = self.appcast.read_bytes()
        with self.assertRaises(ValueError):
            UPDATE(self.appcast, notes)
        self.assertEqual(self.appcast.read_bytes(), before)

    def test_localized_html_and_links(self):
        UPDATE(self.appcast, NOTES)
        descriptions = self.descriptions()
        self.assertEqual(
            [node.get("{http://www.w3.org/XML/1998/namespace}lang") for node in descriptions],
            ["en", "zh-Hans"],
        )
        english, chinese = [node.text for node in descriptions]
        self.assertIn("<strong>downloads</strong>", english)
        self.assertIn("「<strong>下载</strong>」与“窗口”", chinese)
        self.assertIn("&lt;&gt;&amp;", chinese)
        self.assertIn("&lt;&gt;&amp;", english)
        self.assertIn("<code>a &lt; b &amp; c</code>。 保留续行。", chinese)
        for content in (english, chinese):
            self.assertIn("font-family: -apple-system", content)
            self.assertIn("font-size: 13px", content)
            self.assertIn("@media (prefers-color-scheme: dark)", content)
            self.assertNotIn("<script", content)
            self.assertNotIn("完整功能", content)
            self.assertNotIn("Excluded full feature", content)
        item = ET.parse(self.appcast).find("./channel/item")
        self.assertIsNone(item.find(f"{{{SPARKLE}}}releaseNotesLink"))
        links = item.findall(f"{{{SPARKLE}}}fullReleaseNotesLink")
        self.assertEqual([node.text for node in links], ["https://github.com/cqagc/mulee/releases"])
        data = self.appcast.read_bytes()
        self.assertTrue(data.startswith(b'<?xml version="1.0" encoding="utf-8"?>'))
        self.assertEqual(data.count(b"<![CDATA["), 2)
        self.assertIn(ENCLOSURE.encode("utf-8"), data)

    def test_only_matching_item_changes(self):
        other = '<item><sparkle:shortVersionString>0.4.1</sparkle:shortVersionString><description>Keep me</description><enclosure sparkle:edSignature="old" /></item>'
        self.appcast.write_text(APPCAST.replace("  </channel>", other + "\n  </channel>"), encoding="utf-8")
        UPDATE(self.appcast, NOTES)
        self.assertIn(other, self.appcast.read_text(encoding="utf-8"))

    def test_repeated_run_replaces_descriptions(self):
        UPDATE(self.appcast, NOTES)
        UPDATE(self.appcast, NOTES.replace("修复", "改善"))
        self.assertEqual(len(self.descriptions()), 2)
        self.assertIn("改善", self.descriptions()[1].text)
        self.assertIn(ENCLOSURE, self.appcast.read_text(encoding="utf-8"))

    def test_self_closing_nodes_without_whitespace(self):
        data = APPCAST.replace("<description>Old notes</description>", "<description/>")
        data = data.replace(" />\n    </item>", " /></item>")
        self.appcast.write_text(data, encoding="utf-8")
        UPDATE(self.appcast, NOTES)
        self.assertEqual(len(self.descriptions()), 2)
        self.assertIn(ENCLOSURE, self.appcast.read_text(encoding="utf-8"))

    def test_missing_sections_or_terminators(self):
        for marker in ("**0.4.2 的变化**", "**Changes in 0.4.2**", "以下是全部功能。", "Full feature list:"):
            with self.subTest(marker=marker):
                self.assert_rejected(NOTES.replace(marker, "Missing"))

    def test_mismatched_versions(self):
        self.assert_rejected(NOTES.replace("Changes in 0.4.2", "Changes in 0.4.3"))
        self.assert_rejected(NOTES.replace("0.4.2", "0.4.3"))

    def test_empty_or_non_list_section(self):
        self.assert_rejected(NOTES.replace("* Fix **downloads** with <>& and \"quotes\".\n1. Keep `inline code`.", ""))
        self.assert_rejected(NOTES.replace("* Fix", "Fix"))

    def test_duplicate_matching_item(self):
        root = ET.fromstring(APPCAST)
        item = ET.tostring(root.find("./channel/item"), encoding="unicode")
        self.appcast.write_text(APPCAST.replace("  </channel>", item + "\n  </channel>"), encoding="utf-8")
        self.assert_rejected(NOTES)

    def test_missing_enclosure(self):
        self.appcast.write_text(APPCAST.replace(ENCLOSURE, ""), encoding="utf-8")
        self.assert_rejected(NOTES)

    def test_crlf_notes_and_xml_declaration(self):
        self.appcast.write_text(APPCAST.split("\n", 1)[1], encoding="utf-8")
        UPDATE(self.appcast, NOTES.replace("\n", "\r\n"))
        self.assertTrue(self.appcast.read_bytes().startswith(b"<?xml"))
        self.assertEqual(len(self.descriptions()), 2)

    def test_enclosure_version_attribute(self):
        data = APPCAST.replace("      <sparkle:shortVersionString>0.4.2</sparkle:shortVersionString>\n", "")
        data = data.replace('<enclosure url=', '<enclosure sparkle:shortVersionString="0.4.2" url=')
        self.appcast.write_text(data, encoding="utf-8")
        UPDATE(self.appcast, NOTES)
        self.assertEqual(len(self.descriptions()), 2)
        self.assertIn('sparkle:edSignature="fake-signature=="', self.appcast.read_text(encoding="utf-8"))

    def test_cli_success_and_failure(self):
        notes = pathlib.Path(self.directory.name) / "notes.md"
        notes.write_text(NOTES, encoding="utf-8")
        result = subprocess.run([sys.executable, "-I", str(SCRIPT), str(self.appcast), str(notes)], capture_output=True)
        self.assertEqual(result.returncode, 0, result.stderr)
        before = self.appcast.read_bytes()
        notes.write_text("No changes", encoding="utf-8")
        result = subprocess.run([sys.executable, "-I", str(SCRIPT), str(self.appcast), str(notes)], capture_output=True)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn(b"error:", result.stderr)
        self.assertEqual(self.appcast.read_bytes(), before)
        result = subprocess.run([sys.executable, "-I", str(SCRIPT)], capture_output=True)
        self.assertNotEqual(result.returncode, 0)


if __name__ == "__main__":
    unittest.main()
