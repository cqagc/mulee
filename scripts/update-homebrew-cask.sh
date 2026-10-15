#!/bin/bash
# 生成 Homebrew cask：brew install cqagc/tap/mulee
#
# 用法：scripts/update-homebrew-cask.sh <homebrew-tap 仓库目录> [DMG 路径]
#   DMG 默认取 build/release/Mulee-<版本>.dmg。脚本只写文件，提交和推送 tap 仓库由发版的人确认后做。
#   发布 GitHub Release（非草稿）之后再推送 cask，否则下载地址不可用。
set -euo pipefail
export LANG=en_US.UTF-8
export LC_ALL=en_US.UTF-8

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TAP="${1:?用法：$0 <homebrew-tap 仓库目录> [DMG 路径]}"
VERSION="$(awk -F'"' '/MARKETING_VERSION/ {print $2; exit}' "$ROOT/project.yml")"
DMG="${2:-$ROOT/build/release/Mulee-$VERSION.dmg}"
[ -f "$DMG" ] || { echo "error: 找不到 ${DMG}，先运行 scripts/release.sh" >&2; exit 1; }
SHA="$(shasum -a 256 "$DMG" | awk '{print $1}')"

mkdir -p "$TAP/Casks"
cat > "$TAP/Casks/mulee.rb" <<EOF
cask "mulee" do
  version "$VERSION"
  sha256 "$SHA"

  url "https://github.com/cqagc/mulee/releases/download/v#{version}/Mulee-#{version}.dmg"
  name "Mulee"
  desc "Downloader for HTTP, BitTorrent, eD2k and video sites"
  homepage "https://github.com/cqagc/mulee"

  livecheck do
    url :url
    strategy :github_latest
  end

  auto_updates true
  depends_on arch: :arm64
  depends_on macos: :tahoe

  app "Mulee.app"

  zap trash: [
    "~/Library/Application Support/Mulee",
    "~/Library/Caches/com.cqagc.mulee",
    "~/Library/HTTPStorages/com.cqagc.mulee",
    "~/Library/Preferences/com.cqagc.mulee.plist",
  ]
end
EOF
echo "已写入 $TAP/Casks/mulee.rb（${VERSION}，sha256 ${SHA}）"
