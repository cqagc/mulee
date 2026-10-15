#!/usr/bin/env bash
# 把 GitHub Release 上的 DMG 同步到国内下载镜像 dl.cqagc.com。
# 用法：MULEE_MIRROR_HOST=user@host scripts/publish-cn-mirror.sh 0.1.7
# 结果：https://dl.cqagc.com/mulee/<版本>/Mulee-<版本>.dmg（及 .sha256）
# 发完后把官网 cqagc-com 的 templates/mulee.html、seo.go、mulee_test.go 里的下载地址和版本号一起改掉再部署。
set -euo pipefail

VERSION="${1:?用法：$0 <版本号，如 0.1.7>}"
HOST="${MULEE_MIRROR_HOST:?需要设置 MULEE_MIRROR_HOST（user@host）}"
DMG="Mulee-$VERSION.dmg"
URL="https://dl.cqagc.com/mulee/$VERSION/$DMG"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

gh release download "v$VERSION" --repo cqagc/mulee -p "$DMG" -p "$DMG.sha256" -D "$WORK"
(cd "$WORK" && shasum -a 256 -c "$DMG.sha256")

ssh -o BatchMode=yes "$HOST" "test ! -e /srv/downloads/mulee/$VERSION" \
  || { echo "镜像上已有 ${VERSION}，同版本不覆盖"; exit 1; }
ssh -o BatchMode=yes "$HOST" "mkdir -p /srv/download-staging/mulee-$VERSION"
scp -q "$WORK/$DMG" "$WORK/$DMG.sha256" "$HOST:/srv/download-staging/mulee-$VERSION/"
ssh -o BatchMode=yes "$HOST" "set -e; cd /srv/download-staging/mulee-$VERSION; sha256sum -c $DMG.sha256; \
  chmod 755 .; chmod 644 *; mv /srv/download-staging/mulee-$VERSION /srv/downloads/mulee/$VERSION"

[ "$(curl -s -r 0-0 -o /dev/null -w '%{http_code}' "$URL")" = 206 ] || { echo "Range 校验失败：$URL"; exit 1; }
REMOTE_SUM="$(curl -sf "$URL" | shasum -a 256 | cut -d' ' -f1)"
[ "$REMOTE_SUM" = "$(cut -d' ' -f1 "$WORK/$DMG.sha256")" ] || { echo "公网下载校验不一致"; exit 1; }
echo "已发布：$URL"
