#!/bin/bash
# Assemble browser-loadable resources without a JS build tool or dependencies.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
OUTPUT="$ROOT/build/extensions"
MODE="${1:---all}"
case "$MODE" in
  --all|--chrome|--safari) ;;
  *) echo "用法：$0 [--all|--chrome|--safari]" >&2; exit 1 ;;
esac

package_extension() {
  local browser="$1" manifest="$2" destination="$OUTPUT/$1"
  mkdir -p "$destination/icons"
  cp "$ROOT/Extensions/$manifest/manifest.json" "$destination/manifest.json"
  cp "$ROOT"/Extensions/Shared/*.js "$ROOT"/Extensions/Shared/*.html \
    "$ROOT"/Extensions/Shared/*.css "$destination/"
  rm -rf "$destination/_locales"
  cp -R "$ROOT/Extensions/Shared/_locales" "$destination/_locales"
  for size in 16 32 48 128; do
    sips -z "$size" "$size" "$ROOT/Design/Brand/mulee-icon-1024.png" \
      --out "$destination/icons/icon-$size.png" >/dev/null
  done
}

if [ "$MODE" != --safari ]; then
  package_extension chrome Chrome
  rm -f "$OUTPUT/mulee-chrome.zip"
  (cd "$OUTPUT" && /usr/bin/zip -q -r mulee-chrome.zip chrome)
  if [ -n "${TARGET_BUILD_DIR:-}" ] && [ -n "${UNLOCALIZED_RESOURCES_FOLDER_PATH:-}" ]; then
    RESOURCE_DIR="$TARGET_BUILD_DIR/$UNLOCALIZED_RESOURCES_FOLDER_PATH/BrowserExtensions"
    mkdir -p "$RESOURCE_DIR"
    rm -rf "$RESOURCE_DIR/chrome"
    cp -R "$OUTPUT/chrome" "$RESOURCE_DIR/chrome"
    cp "$OUTPUT/mulee-chrome.zip" "$RESOURCE_DIR/"
    cp "$ROOT/Mulee/Resources/BrowserExtensionInstall.txt" "$RESOURCE_DIR/"
  fi
fi
if [ "$MODE" != --chrome ]; then
  package_extension safari Safari
  if [ -n "${TARGET_BUILD_DIR:-}" ] && [ -n "${UNLOCALIZED_RESOURCES_FOLDER_PATH:-}" ]; then
    RESOURCE_DIR="$TARGET_BUILD_DIR/$UNLOCALIZED_RESOURCES_FOLDER_PATH"
    mkdir -p "$RESOURCE_DIR"
    cp -R "$OUTPUT/safari/." "$RESOURCE_DIR/"
  fi
fi
