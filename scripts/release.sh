#!/bin/bash
# 构建发布版：安全与隐私检查 → Release 编译 → Developer ID 签名 → 公证并装订 App → 打 DMG
# → 签名、公证并装订 DMG → 再查一遍 App 和发布文件。任何一步检查不过都不出包。
#
# 用法：
#   MULEE_NOTARY_PROFILE=<notarytool 钥匙串配置名> scripts/release.sh
#   不设 MULEE_NOTARY_PROFILE 时只签名、不公证（本机可用，别人下载会被 Gatekeeper 拦）。
#
# 环境变量：
#   MULEE_SIGN_IDENTITY   签名身份，默认 "Developer ID Application"（钥匙串里唯一一张时可以只写前缀）
#   MULEE_TEAM_ID         开发团队，默认读 project.yml 的 DEVELOPMENT_TEAM
#   MULEE_NOTARY_PROFILE  `xcrun notarytool store-credentials` 存的配置名
#   或者直接用 App Store Connect API 密钥文件（不经过钥匙串，适合锁屏 / 无人值守）：
#   MULEE_NOTARY_KEY=<AuthKey_XXXX.p8 路径> MULEE_NOTARY_KEY_ID=<Key ID> MULEE_NOTARY_ISSUER=<Issuer ID>
#   MULEE_SPARKLE_KEY_FILE  可选的 EdDSA 私钥文件；未设时 sign_update 从钥匙串读取
#   MULEE_PRIVACY_DENYLIST  私有屏蔽词文件，默认 ~/.config/mulee/privacy-denylist.txt（见 scripts/privacy-check.py）
#
# 产物：build/release/Mulee-<版本>.dmg、appcast.xml（有私钥且公证成功时）
set -euo pipefail
export LANG=en_US.UTF-8
export LC_ALL=en_US.UTF-8

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

error() { echo "error: $*" >&2; exit 1; }
step() { echo; echo "==> $*"; }

VERSION="$(awk -F'"' '/MARKETING_VERSION/ {print $2; exit}' project.yml)"
BUILD_VERSION="$(awk -F'"' '/CURRENT_PROJECT_VERSION/ {print $2; exit}' project.yml)"
TEAM="${MULEE_TEAM_ID:-$(awk '/DEVELOPMENT_TEAM:/ {print $2; exit}' project.yml)}"
IDENTITY="${MULEE_SIGN_IDENTITY:-Developer ID Application}"
PROFILE="${MULEE_NOTARY_PROFILE:-}"
NOTARY_AUTH=()
if [ -n "${MULEE_NOTARY_KEY:-}" ]; then
  [ -f "$MULEE_NOTARY_KEY" ] || error "找不到密钥文件 $MULEE_NOTARY_KEY"
  NOTARY_AUTH=(--key "$MULEE_NOTARY_KEY" --key-id "${MULEE_NOTARY_KEY_ID:?需要 MULEE_NOTARY_KEY_ID}" --issuer "${MULEE_NOTARY_ISSUER:?需要 MULEE_NOTARY_ISSUER}")
elif [ -n "$PROFILE" ]; then
  NOTARY_AUTH=(--keychain-profile "$PROFILE")
fi
OUT="$ROOT/build/release"
DERIVED="$OUT/dd"
DMG="$OUT/Mulee-$VERSION.dmg"

[ -n "$VERSION" ] || error "读不到 project.yml 里的 MARKETING_VERSION"
security find-identity -v -p codesigning | grep -q "$IDENTITY" \
  || error "钥匙串里没有签名身份「${IDENTITY}」"

step "Mulee $VERSION · 团队 $TEAM · 签名「${IDENTITY}」"

step "安全与隐私检查（仓库全部历史）"
[ -z "$(git status --porcelain --untracked-files=normal)" ] || error "工作区有未提交的改动，提交后再发版"
python3 -I scripts/privacy-check.py || error "仓库里有不能公开的内容，见上面的列表"
rm -rf "$OUT"
mkdir -p "$OUT"

step "Release 构建"
xcodegen generate >/dev/null
xcodebuild -project Mulee.xcodeproj -scheme Mulee -configuration Release \
  -destination 'generic/platform=macOS' -derivedDataPath "$DERIVED" \
  CODE_SIGN_STYLE=Manual CODE_SIGN_IDENTITY="$IDENTITY" DEVELOPMENT_TEAM="$TEAM" \
  OTHER_CODE_SIGN_FLAGS=--timestamp CODE_SIGN_INJECT_BASE_ENTITLEMENTS=NO \
  build > "$OUT/xcodebuild.log" 2>&1 || { tail -30 "$OUT/xcodebuild.log"; error "构建失败，见 $OUT/xcodebuild.log"; }
APP="$DERIVED/Build/Products/Release/Mulee.app"
[ -d "$APP" ] || error "找不到 $APP"

step "检查翻译"
python3 -I scripts/check-l10n.py "$DERIVED" Release || error "有文案没翻译，见上面的列表"

step "检查签名"
codesign --verify --deep --strict --verbose=2 "$APP" 2>&1 | tail -2
# 每个可执行部件都必须是 Developer ID 签名、带时间戳和硬化运行时，否则公证会被拒。
while IFS= read -r -d '' item; do
  info="$(codesign -dvv "$item" 2>&1)"
  grep -q "Authority=Developer ID Application" <<<"$info" || error "$item 不是 Developer ID 签名"
  grep -q "Timestamp=" <<<"$info" || error "$item 没有安全时间戳"
  grep -q "flags=.*runtime" <<<"$info" || error "$item 没有启用硬化运行时"
  ! codesign -d --entitlements - "$item" 2>/dev/null | grep -q get-task-allow || error "$item 带有调试权限 get-task-allow，公证会被拒"
done < <(find "$APP" -type f -perm -u+x -print0 | while IFS= read -r -d '' executable; do
           # 包括 Sparkle Framework 主程序、Autoupdate、Updater.app、全部 XPC 服务。
           if file -b "$executable" | grep -q 'Mach-O'; then
             printf '%s\0' "$executable"
           fi
         done)
echo "全部部件签名合格"

notarize() {
  local file="$1"
  xcrun notarytool submit "$file" "${NOTARY_AUTH[@]}" --wait --output-format json \
    > "$OUT/notary-$(basename "$file").json" 2> "$OUT/notary-$(basename "$file").err" || true
  [ -s "$OUT/notary-$(basename "$file").json" ] || { cat "$OUT/notary-$(basename "$file").err" >&2; error "提交公证失败"; }
  local status
  status="$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1])).get("status",""))' "$OUT/notary-$(basename "$file").json")"
  if [ "$status" != "Accepted" ]; then
    local id
    id="$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1])).get("id",""))' "$OUT/notary-$(basename "$file").json")"
    [ -n "$id" ] && xcrun notarytool log "$id" "${NOTARY_AUTH[@]}" "$OUT/notary-log.json" || true
    error "公证未通过（${status}），见 $OUT/notary-log.json"
  fi
}

if [ ${#NOTARY_AUTH[@]} -gt 0 ]; then
  step "公证 App"
  ditto -c -k --keepParent "$APP" "$OUT/Mulee.zip"
  notarize "$OUT/Mulee.zip"
  xcrun stapler staple "$APP"
  rm -f "$OUT/Mulee.zip"
else
  echo "未设置公证凭据（MULEE_NOTARY_PROFILE 或 MULEE_NOTARY_KEY），跳过公证"
fi

step "打包 DMG"
STAGE="$OUT/dmg"
mkdir -p "$STAGE"
ditto "$APP" "$STAGE/Mulee.app"
ln -s /Applications "$STAGE/Applications"
hdiutil create -volname "Mulee $VERSION" -srcfolder "$STAGE" -fs HFS+ -format UDZO -ov "$DMG" >/dev/null
rm -rf "$STAGE"
codesign --force --sign "$IDENTITY" --timestamp "$DMG"

if [ ${#NOTARY_AUTH[@]} -gt 0 ]; then
  step "公证 DMG"
  notarize "$DMG"
  xcrun stapler staple "$DMG"
  step "Gatekeeper 检查"
  spctl -a -vvv -t install "$DMG" 2>&1 | tail -2
  spctl -a -vvv -t execute "$APP" 2>&1 | tail -2
fi

if [ ${#NOTARY_AUTH[@]} -gt 0 ]; then
  step "生成 Sparkle appcast"
  SIGN_UPDATE="$(find "$DERIVED/SourcePackages/artifacts/sparkle" -type f -path '*/bin/sign_update' -print -quit)"
  [ -x "$SIGN_UPDATE" ] || error "找不到 SwiftPM Sparkle 的 bin/sign_update"
  SPARKLE_ARGS=()
  HAS_SPARKLE_KEY=1
  if [ -n "${MULEE_SPARKLE_KEY_FILE:-}" ]; then
    if [ -f "$MULEE_SPARKLE_KEY_FILE" ]; then
      SPARKLE_ARGS+=(--ed-key-file "$MULEE_SPARKLE_KEY_FILE")
    else
      HAS_SPARKLE_KEY=0
      echo "没有 Sparkle 私钥文件，跳过 appcast：$MULEE_SPARKLE_KEY_FILE"
    fi
  elif ! "$(dirname "$SIGN_UPDATE")/generate_keys" -p > /dev/null 2> "$OUT/sparkle-sign.log"; then
    HAS_SPARKLE_KEY=0
    echo "钥匙串没有可用 Sparkle 私钥，跳过 appcast，详见 $OUT/sparkle-sign.log"
  fi
  if [ "$HAS_SPARKLE_KEY" = 1 ]; then
    if SIGNATURE="$("$SIGN_UPDATE" "${SPARKLE_ARGS[@]}" -p "$DMG" 2> "$OUT/sparkle-sign.log")"; then
      python3 - "$APP" "$DMG" "$VERSION" "$BUILD_VERSION" "$SIGNATURE" "$OUT/appcast.xml" <<'PY'
import base64
import datetime
import email.utils
import pathlib
import plistlib
import sys
import xml.etree.ElementTree as ET

app, dmg, version, build, signature, output = sys.argv[1:]
info = plistlib.loads((pathlib.Path(app) / "Contents/Info.plist").read_bytes())
if info["CFBundleShortVersionString"] != version or info["CFBundleVersion"] != build:
    raise SystemExit("App 版本与 project.yml 不一致，拒绝生成 appcast")
if len(base64.b64decode(signature, validate=True)) != 64:
    raise SystemExit("Sparkle 签名长度无效")
namespace = "http://www.andymatuschak.org/xml-namespaces/sparkle"
ET.register_namespace("sparkle", namespace)
rss = ET.Element("rss", {"version": "2.0"})
channel = ET.SubElement(rss, "channel")
ET.SubElement(channel, "title").text = "Mulee"
ET.SubElement(channel, "link").text = "https://github.com/cqagc/mulee/releases"
item = ET.SubElement(channel, "item")
ET.SubElement(item, "title").text = f"Mulee {version}"
ET.SubElement(item, "pubDate").text = email.utils.format_datetime(datetime.datetime.now(datetime.timezone.utc))
ET.SubElement(item, f"{{{namespace}}}version").text = build
ET.SubElement(item, f"{{{namespace}}}shortVersionString").text = version
ET.SubElement(item, f"{{{namespace}}}minimumSystemVersion").text = "26.0"
ET.SubElement(item, f"{{{namespace}}}releaseNotesLink").text = f"https://github.com/cqagc/mulee/releases/tag/v{version}"
ET.SubElement(item, "enclosure", {
    "url": f"https://github.com/cqagc/mulee/releases/download/v{version}/Mulee-{version}.dmg",
    "length": str(pathlib.Path(dmg).stat().st_size),
    "type": "application/octet-stream",
    f"{{{namespace}}}edSignature": signature,
})
ET.indent(rss, space="  ")
ET.ElementTree(rss).write(output, encoding="utf-8", xml_declaration=True)
PY
      echo "已生成 $OUT/appcast.xml（DMG 装订后的最终字节签名）"
    else
      error "Sparkle 更新签名失败，见 $OUT/sparkle-sign.log"
    fi
  fi
else
  echo "DMG 未公证装订，跳过 Sparkle appcast"
fi

# 校验文件里只写文件名，不带构建机的绝对路径。
(cd "$OUT" && shasum -a 256 "$(basename "$DMG")" | tee "$(basename "$DMG").sha256")

step "安全与隐私检查（App 包和发布文件）"
CHECK_FILES=(--file "$DMG.sha256")
[ -f "$OUT/appcast.xml" ] && CHECK_FILES+=(--file "$OUT/appcast.xml")
python3 -I scripts/privacy-check.py --app "$APP" "${CHECK_FILES[@]}" \
  || error "App 包或发布文件里有构建路径、内部地址等不能公开的内容"
step "完成：${DMG}（$(du -h "$DMG" | cut -f1)）"
