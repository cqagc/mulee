#!/usr/bin/env python3
"""检查三个 String Catalog 的 en / zh-Hant / ja 译文及编译提取结果。

命令行 xcodebuild 不会把新文案写回 .xcstrings（只有 Xcode 界面会）。
这里读编译产物里的 .stringsdata，与 App 和 MuleeCore 目录逐条比对。

用法：scripts/check-l10n.py <DerivedData 目录> [Debug|Release]
"""
import glob
import itertools
import json
import os
import re
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
CATALOG_PATHS = (
    "Mulee/Resources/Localizable.xcstrings",
    "Mulee/Resources/InfoPlist.xcstrings",
    "Packages/MuleeCore/Sources/MuleeCore/Resources/Localizable.xcstrings",
)
CATALOGS = {"Mulee": CATALOG_PATHS[0], "MuleeCore": CATALOG_PATHS[2]}
LANGUAGES = ("en", "zh-Hant", "ja")
# 日本語の新字体（国、体、図など）は禁止しない。
JAPANESE_FORBIDDEN = set("载设义链软网视频压缩钥夹传档认误码动连显复读写损坏览删选进暂种绪启关开备实级队拥护储译线绐")
PLACEHOLDER = re.compile(
    r"%(?:(\d+)\$)?[-+#0 ']*(?:\d+|\*)?(?:\.(?:\d+|\*))?"
    r"((?:hh|ll|h|l|L|z|t|j)?[@diuoxXfFeEgGaAcCsSp])"
)


def placeholders(value: str) -> list:
    result = []
    argument = 1
    for match in PLACEHOLDER.finditer(value.replace("%%", "  ")):
        position, specifier = match.groups()
        result.append((int(position) if position else argument, specifier))
        if not position:
            argument += 1
    return sorted(result)


def expanded_values(node: dict) -> list:
    """展开复数和 substitution，以最终句子检查参数。"""
    if "stringUnit" in node:
        values = [node["stringUnit"]["value"]]
        for name, substitution in node.get("substitutions", {}).items():
            variants = expanded_values(substitution)
            argument = substitution["argNum"]
            variants = [PLACEHOLDER.sub(
                lambda match: match.group(0) if match.group(1)
                else f"%{argument}${match.group(2)}", value
            ) for value in variants]
            values = [value.replace(f"%#@{name}@", variant)
                      for value, variant in itertools.product(values, variants)]
        return values
    return [value for variants in node.get("variations", {}).values()
            for variant in variants.values() for value in expanded_values(variant)]


def string_units(node: dict) -> list:
    units = [node["stringUnit"]] if "stringUnit" in node else []
    for variants in node.get("variations", {}).values():
        for variant in variants.values():
            units.extend(string_units(variant))
    for substitution in node.get("substitutions", {}).values():
        units.extend(string_units(substitution))
    return units


def translated(entry: dict, language: str) -> bool:
    units = string_units(entry.get("localizations", {}).get(language, {}))
    return bool(units) and all(unit.get("state") == "translated" for unit in units)


def extracted_strings(derived: str, configuration: str) -> tuple:
    """返回按所属目录分组的提取文案和缺少构建产物的问题。"""
    extracted, problems = {}, []
    for target, catalog_path in CATALOGS.items():
        files = []
        for build_target in (target, target + "-*"):
            pattern = os.path.join(
                derived, f"Build/Intermediates.noindex/**/{target}.build/"
                f"{configuration}/{build_target}.build/**/*.stringsdata"
            )
            files.extend(glob.glob(pattern, recursive=True))
        files = sorted(set(files))
        if not files:
            problems.append(f"{target}：没找到 .stringsdata，先完成一次 {configuration} 构建")
        entries = extracted.setdefault(catalog_path, {})
        for path in files:
            with open(path, encoding="utf-8") as stream:
                data = json.load(stream)
            for entry in data.get("tables", {}).get("Localizable", []):
                if entry.get("shouldTranslate", True):
                    entries[entry["key"]] = entry
    return extracted, problems


def catalog_problems(catalog: dict, label: str) -> list:
    problems = []
    for key, entry in catalog["strings"].items():
        if not entry.get("shouldTranslate", True):
            continue
        localizations = entry.get("localizations", {})
        source = localizations.get(catalog["sourceLanguage"], {"stringUnit": {"value": key}})
        expected = placeholders(expanded_values(source)[0])
        for language in LANGUAGES:
            context = f"{label}：「{key}」[{language}]"
            if not translated(entry, language):
                problems.append(f"{context} 缺译文或状态不是 translated")
            try:
                values = expanded_values(localizations.get(language, {}))
                for value in values:
                    if placeholders(value) != expected or re.search(r"%#@[^@]+@", value):
                        problems.append(f"{context} 占位符不一致")
                    if language == "ja" and JAPANESE_FORBIDDEN.intersection(value):
                        problems.append(f"{context} 含简体专用字")
            except (KeyError, TypeError, ValueError):
                problems.append(f"{context} 变体格式不完整")
    return problems


def main() -> int:
    if len(sys.argv) < 2:
        print(__doc__)
        return 2
    derived, configuration = sys.argv[1], (sys.argv[2] if len(sys.argv) > 2 else "Debug")
    extracted, problems = extracted_strings(derived, configuration)
    for path in CATALOG_PATHS:
        with open(os.path.join(ROOT, path), encoding="utf-8") as stream:
            catalog = json.load(stream)
        problems.extend(catalog_problems(catalog, path))
        for key in extracted.get(path, {}):
            if key not in catalog["strings"]:
                problems.append(f"{path}：「{key}」不在字符串目录里")
    for line in sorted(set(problems)):
        print(line)
    if problems:
        print(f"\n共 {len(set(problems))} 处问题。补译后在 docs/GLOSSARY.md 核对术语。")
        return 1
    print("界面文案已全部翻译（en / zh-Hant / ja）")
    return 0


if __name__ == "__main__":
    sys.exit(main())
