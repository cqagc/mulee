#!/bin/bash
# 构建发布版：Release 编译 → Developer ID 签名 → 公证并装订 App → 打 DMG → 签名、公证并装订 DMG。
#
# 用法：
#   MULEE_NOTARY_PROFILE=<notarytool 钥匙串配置名> scripts/release.sh
#   不设 MULEE_NOTARY_PROFILE 时只签名、不公证（本机可用，别人下载会被 Gatekeeper 拦）。
#
# 环境变量：
#   MULEE_SIGN_IDENTITY   签名身份，默认 "Developer ID Application"（钥匙串里唯一一张时可以只写前缀）
#   MULEE_TEAM_ID         开发团队，默认读 project.yml 的 DEVELOPMENT_TEAM
#   MULEE_NOTARY_PROFILE  `xcrun notarytool store-credentials` 存的配置名
#
# 产物：build/release/Mulee-<版本>.dmg
set -euo pipefail
export LANG=en_US.UTF-8
export LC_ALL=en_US.UTF-8

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

error() { echo "error: $*" >&2; exit 1; }
step() { echo; echo "==> $*"; }

VERSION="$(awk -F'"' '/MARKETING_VERSION/ {print $2; exit}' project.yml)"
TEAM="${MULEE_TEAM_ID:-$(awk '/DEVELOPMENT_TEAM:/ {print $2; exit}' project.yml)}"
IDENTITY="${MULEE_SIGN_IDENTITY:-Developer ID Application}"
PROFILE="${MULEE_NOTARY_PROFILE:-}"
OUT="$ROOT/build/release"
DERIVED="$OUT/dd"
DMG="$OUT/Mulee-$VERSION.dmg"

[ -n "$VERSION" ] || error "读不到 project.yml 里的 MARKETING_VERSION"
security find-identity -v -p codesigning | grep -q "$IDENTITY" \
  || error "钥匙串里没有签名身份「${IDENTITY}」"

step "Mulee $VERSION · 团队 $TEAM · 签名「${IDENTITY}」"
rm -rf "$OUT"
mkdir -p "$OUT"

step "Release 构建"
xcodegen generate >/dev/null
xcodebuild -project Mulee.xcodeproj -scheme Mulee -configuration Release \
  -destination 'generic/platform=macOS' -derivedDataPath "$DERIVED" \
  CODE_SIGN_STYLE=Manual CODE_SIGN_IDENTITY="$IDENTITY" DEVELOPMENT_TEAM="$TEAM" \
  OTHER_CODE_SIGN_FLAGS=--timestamp \
  build > "$OUT/xcodebuild.log" 2>&1 || { tail -30 "$OUT/xcodebuild.log"; error "构建失败，见 $OUT/xcodebuild.log"; }
APP="$DERIVED/Build/Products/Release/Mulee.app"
[ -d "$APP" ] || error "找不到 $APP"

step "检查签名"
codesign --verify --deep --strict --verbose=2 "$APP" 2>&1 | tail -2
# 每个可执行部件都必须是 Developer ID 签名、带时间戳和硬化运行时，否则公证会被拒。
while IFS= read -r -d '' item; do
  info="$(codesign -dvv "$item" 2>&1)"
  grep -q "Authority=Developer ID Application" <<<"$info" || error "$item 不是 Developer ID 签名"
  grep -q "Timestamp=" <<<"$info" || error "$item 没有安全时间戳"
  grep -q "flags=.*runtime" <<<"$info" || error "$item 没有启用硬化运行时"
done < <(find "$APP" \( -path '*/Contents/MacOS/*' -o -path '*/Contents/Helpers/*' -o -name '*.appex' \) -type f -perm -u+x -print0;
         find "$APP/Contents/PlugIns" -maxdepth 1 -name '*.appex' -print0 2>/dev/null)
echo "全部部件签名合格"

notarize() {
  local file="$1"
  xcrun notarytool submit "$file" --keychain-profile "$PROFILE" --wait --output-format json \
    > "$OUT/notary-$(basename "$file").json" || true
  local status
  status="$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1])).get("status",""))' "$OUT/notary-$(basename "$file").json")"
  if [ "$status" != "Accepted" ]; then
    local id
    id="$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1])).get("id",""))' "$OUT/notary-$(basename "$file").json")"
    [ -n "$id" ] && xcrun notarytool log "$id" --keychain-profile "$PROFILE" "$OUT/notary-log.json" || true
    error "公证未通过（${status}），见 $OUT/notary-log.json"
  fi
}

if [ -n "$PROFILE" ]; then
  step "公证 App"
  ditto -c -k --keepParent "$APP" "$OUT/Mulee.zip"
  notarize "$OUT/Mulee.zip"
  xcrun stapler staple "$APP"
  rm -f "$OUT/Mulee.zip"
else
  echo "未设置 MULEE_NOTARY_PROFILE，跳过公证"
fi

step "打包 DMG"
STAGE="$OUT/dmg"
mkdir -p "$STAGE"
ditto "$APP" "$STAGE/Mulee.app"
ln -s /Applications "$STAGE/Applications"
hdiutil create -volname "Mulee $VERSION" -srcfolder "$STAGE" -fs HFS+ -format UDZO -ov "$DMG" >/dev/null
rm -rf "$STAGE"
codesign --force --sign "$IDENTITY" --timestamp "$DMG"

if [ -n "$PROFILE" ]; then
  step "公证 DMG"
  notarize "$DMG"
  xcrun stapler staple "$DMG"
  step "Gatekeeper 检查"
  spctl -a -vvv -t install "$DMG" 2>&1 | tail -2
  spctl -a -vvv -t execute "$APP" 2>&1 | tail -2
fi

shasum -a 256 "$DMG" | tee "$DMG.sha256"
step "完成：${DMG}（$(du -h "$DMG" | cut -f1)）"
