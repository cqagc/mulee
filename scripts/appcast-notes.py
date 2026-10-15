#!/usr/bin/env python3
"""将双语发版说明中的变化列表写入 Sparkle appcast。

用法：scripts/appcast-notes.py <appcast.xml> <发版说明.md>
"""
import html
import pathlib
import re
import sys
import xml.etree.ElementTree as ET
import xml.parsers.expat

SPARKLE = "http://www.andymatuschak.org/xml-namespaces/sparkle"
HISTORY = "https://github.com/cqagc/mulee/releases"


def inline_html(text):
    """只转换粗体和行内代码，其余内容转义为普通文本。"""
    parts = re.split(r"(`[^`]+`|\*\*[^*]+\*\*)", text)
    result = []
    for part in parts:
        if part.startswith("**") and part.endswith("**"):
            result.append("<strong>" + html.escape(part[2:-2]) + "</strong>")
        elif part.startswith("`") and part.endswith("`"):
            result.append("<code>" + html.escape(part[1:-1]) + "</code>")
        else:
            result.append(html.escape(part))
    return "".join(result)


def changes(notes, heading, ending):
    pattern = (
        r"^[ \t]*(?:#{1,6}[ \t]+)?\*\*" + heading
        + r"\*\*[ \t]*\r?$([\s\S]*?)^[ \t]*" + re.escape(ending)
        + r"[ \t]*\r?$"
    )
    matches = list(re.finditer(pattern, notes, re.MULTILINE))
    if len(matches) != 1:
        raise ValueError("找不到唯一的变化列表：" + ending)
    match = matches[0]
    items = []
    for line in match.group(2).splitlines():
        if not line.strip():
            continue
        bullet = re.match(r"^\s*(?:[-*+]|\d+[.)])[ \t]+(.+)$", line)
        if bullet:
            items.append(bullet.group(1).strip())
        elif items and line[0].isspace():
            items[-1] += " " + line.strip()
        else:
            raise ValueError("变化段落中存在非列表内容：" + line)
    if not items:
        raise ValueError("变化列表为空：" + ending)
    return match.group(1), items


def notes_html(items, language):
    rows = "\n".join("  <li>" + inline_html(item) + "</li>" for item in items)
    return f'''<!DOCTYPE html>
<html lang="{language}">
<head>
<meta charset="utf-8">
<meta name="color-scheme" content="light dark">
<style>
body {{ font-family: -apple-system, sans-serif; font-size: 13px; line-height: 1.5; color: #222; margin: 12px; }}
ul {{ padding-left: 20px; margin: 0; }}
li {{ margin-bottom: 6px; }}
@media (prefers-color-scheme: dark) {{ body {{ color: #eee; }} }}
</style>
</head>
<body>
<ul>
{rows}
</ul>
</body>
</html>'''


def item_spans(data):
    """定位 item 的直接子节点，避免重新序列化 enclosure / 签名。"""
    parser = xml.parsers.expat.ParserCreate(namespace_separator=" ")
    stack = []
    items = []

    def start(name, attributes):
        start_index = parser.CurrentByteIndex
        tag = re.match(rb"<(?:\"[^\"]*\"|'[^']*'|[^'\">])*>", data[start_index:]).group()
        closed_end = start_index + len(tag) if tag.endswith(b"/>") else None
        stack.append((name, start_index, closed_end))
        if [entry[0] for entry in stack] == ["rss", "channel", "item"]:
            items.append([])

    def end(name):
        name, start_index, closed_end = stack.pop()
        end_index = closed_end
        if end_index is None:
            end_index = data.index(b">", parser.CurrentByteIndex) + 1
        if [entry[0] for entry in stack] == ["rss", "channel", "item"]:
            items[-1].append((name, start_index, end_index))

    parser.StartElementHandler = start
    parser.EndElementHandler = end
    parser.Parse(data, True)
    return items


def update_appcast(appcast, notes):
    zh_version, zh_items = changes(notes, r"(0\.\d+\.\d+) 的变化", "以下是全部功能。")
    en_version, en_items = changes(notes, r"Changes in (0\.\d+\.\d+)", "Full feature list:")
    if zh_version != en_version:
        raise ValueError("中英文发版说明版本号不一致")

    data = appcast.read_bytes()
    root = ET.fromstring(data)
    items = root.findall("./channel/item")
    matches = []
    for index, item in enumerate(items):
        version = item.findtext(f"{{{SPARKLE}}}shortVersionString")
        if version is None:
            enclosure = item.find("enclosure")
            if enclosure is not None:
                version = enclosure.get(f"{{{SPARKLE}}}shortVersionString")
        if version is not None and version.strip() == zh_version:
            matches.append(index)
    if len(matches) != 1:
        raise ValueError("发版说明版本与 appcast shortVersionString 不匹配或目标 item 不唯一")

    children = item_spans(data)[matches[0]]
    if not any(name == "enclosure" for name, _, _ in children):
        raise ValueError("目标 item 缺少 enclosure")
    # 英文放在首位，作为没有匹配语言时的默认项；中文匹配 zh-Hans 系语言。
    descriptions = []
    for language, entries in (("en", en_items), ("zh-Hans", zh_items)):
        content = notes_html(entries, language).replace("]]>", "]]]]><![CDATA[>")
        descriptions.append(
            f'<description xml:lang="{language}"><![CDATA[{content}]]></description>'
        )
    descriptions.append(
        f'<sparkle:fullReleaseNotesLink xmlns:sparkle="{SPARKLE}">'
        + HISTORY + '</sparkle:fullReleaseNotesLink>'
    )
    insertion = ("\n    " + "\n    ".join(descriptions) + "\n    ").encode("utf-8")
    edits = [(children[0][1], children[0][1], insertion)]
    replace_names = {
        "description", SPARKLE + " releaseNotesLink", SPARKLE + " fullReleaseNotesLink",
    }
    for name, start, end in children:
        if name in replace_names:
            edits.append((start, end, b""))
    for start, end, replacement in sorted(edits, reverse=True):
        data = data[:start] + replacement + data[end:]
    if not data.startswith(b"<?xml"):
        data = b'<?xml version="1.0" encoding="utf-8"?>\n' + data
    # 输出固定为 UTF-8；保留原始 enclosure 字节和已有 XML 声明。
    data.decode("utf-8")
    ET.fromstring(data)
    appcast.write_bytes(data)


def main():
    if len(sys.argv) != 3:
        print(__doc__, file=sys.stderr)
        return 1
    try:
        update_appcast(pathlib.Path(sys.argv[1]), pathlib.Path(sys.argv[2]).read_text(encoding="utf-8"))
    except (OSError, ValueError, ET.ParseError, xml.parsers.expat.ExpatError) as error:
        print(f"error: {error}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
