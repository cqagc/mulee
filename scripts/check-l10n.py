#!/usr/bin/env python3
"""检查编译时提取到的界面文案是否都已进 String Catalog 并译好 en 与 zh-Hant。

命令行 xcodebuild 不会把新文案写回 .xcstrings（只有 Xcode 界面会），漏掉的文案在英文和繁体系统里会直接显示简体中文。
这里读编译产物里的 .stringsdata，与目录逐条比对。

用法：scripts/check-l10n.py <DerivedData 目录> [Debug|Release]
"""
import glob
import json
import os
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
CATALOGS = {
    "Mulee": os.path.join(ROOT, "Mulee/Resources/Localizable.xcstrings"),
}
LANGUAGES = ("en", "zh-Hant")


def translated(entry: dict, language: str) -> bool:
    unit = entry.get("localizations", {}).get(language, {})
    return unit.get("stringUnit", {}).get("state") == "translated" or "variations" in unit


def main() -> int:
    if len(sys.argv) < 2:
        print(__doc__)
        return 2
    derived, configuration = sys.argv[1], (sys.argv[2] if len(sys.argv) > 2 else "Debug")
    problems = []
    for target, catalog_path in CATALOGS.items():
        catalog = json.load(open(catalog_path, encoding="utf-8"))["strings"]
        pattern = os.path.join(derived, f"Build/Intermediates.noindex/{target}.build/{configuration}/{target}.build/**/*.stringsdata")
        files = glob.glob(pattern, recursive=True)
        if not files:
            problems.append(f"{target}：没找到 .stringsdata（{pattern}），先完成一次构建")
            continue
        for path in files:
            data = json.load(open(path, encoding="utf-8"))
            source = os.path.basename(data.get("source", path))
            for entry in data.get("tables", {}).get("Localizable", []):
                key = entry["key"]
                if key not in catalog:
                    problems.append(f"{source}：「{key}」不在字符串目录里")
                elif catalog[key].get("shouldTranslate", True):
                    for language in LANGUAGES:
                        if not translated(catalog[key], language):
                            problems.append(f"{source}：「{key}」缺 {language} 译文")
    for line in sorted(set(problems)):
        print(line)
    if problems:
        print(f"\n共 {len(set(problems))} 处问题。补译后在 docs/GLOSSARY.md 核对术语。")
        return 1
    print("界面文案已全部翻译")
    return 0


if __name__ == "__main__":
    sys.exit(main())
