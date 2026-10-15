#!/bin/sh
# 从 Design/Brand 下的 SVG 母版重新生成 App 图标与菜单栏模板图。依赖：brew install librsvg
set -eu
cd "$(dirname "$0")/.."
B=Design/Brand
A=Mulee/Resources/Assets.xcassets
for s in 16 32 128 256 512; do
  rsvg-convert -w "$s" -h "$s" "$B/mulee-icon.svg" -o "$A/AppIcon.appiconset/icon_${s}x${s}.png"
  d=$((s * 2))
  rsvg-convert -w "$d" -h "$d" "$B/mulee-icon.svg" -o "$A/AppIcon.appiconset/icon_${s}x${s}@2x.png"
done
rsvg-convert -f pdf -w 18 -h 18 "$B/mulee-mark.svg" -o "$A/MenuBarIcon.imageset/MenuBarIcon.pdf"
rsvg-convert -f pdf -w 64 -h 64 "$B/mulee-mark.svg" -o "$A/BrandMark.imageset/BrandMark.pdf"
rsvg-convert -w 1024 "$B/mulee-icon.svg" -o "$B/mulee-icon-1024.png"
echo "icons regenerated"
