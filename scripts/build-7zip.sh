#!/bin/bash
# 从固定子模块源码构建只依赖系统库的 7zz；Xcode 阶段负责打包和签名。
set -euo pipefail
export LANG=en_US.UTF-8
export LC_ALL=en_US.UTF-8
export MACOSX_DEPLOYMENT_TARGET=26.0

error() { echo "error: build-7zip: $*" >&2; exit 1; }
SRCROOT="${SRCROOT:-$(cd "$(dirname "$0")/.." && pwd)}"
CACHE="${MULEE_THIRDPARTY_CACHE:-$SRCROOT/build/thirdparty}"
STANDALONE=0
if [ "${1:-}" = --standalone ] && [ "$#" = 1 ]; then
  STANDALONE=1
elif [ "$#" != 0 ]; then
  error "用法：$0 [--standalone]"
fi
if [ "$STANDALONE" = 0 ]; then
  : "${TARGET_BUILD_DIR:?需要在 Xcode 构建阶段运行，或传 --standalone}"
  : "${CONTENTS_FOLDER_PATH:?缺少 CONTENTS_FOLDER_PATH}"
fi
[ "$(uname -m)" = arm64 ] || error "仅支持 Apple Silicon arm64 构建机。"
for tool in git make xcrun codesign otool vtool lipo; do
  command -v "$tool" >/dev/null || error "缺少 $tool；请安装 Xcode 命令行工具。"
done
SOURCE="$SRCROOT/ThirdParty/7zip"
# 缓存键始终使用父仓库索引记录的 gitlink，不依赖子模块是否初始化。
REV="$(git -C "$SRCROOT" ls-files -s -- ThirdParty/7zip | awk '$1 == "160000" && $3 == "0" { print $2 }')"
[ -n "$REV" ] || error "找不到子模块 ThirdParty/7zip 的 gitlink"
SDK="$(xcrun --sdk macosx --show-sdk-path)"
CC="$(xcrun -f clang)"
CXX="$(xcrun -f clang++)"
# 不读取构建机的 Homebrew 头文件、库和 pkg-config 搜索路径。
unset CPATH CPLUS_INCLUDE_PATH C_INCLUDE_PATH LIBRARY_PATH PKG_CONFIG_PATH CMAKE_PREFIX_PATH
FLAGS="-arch arm64 -mmacosx-version-min=26.0 -isysroot $SDK"
ARGS=(-f ../../cmpl_mac_arm64.mak "CC=$CC" "CXX=$CXX" "MY_ARCH=$FLAGS")
mkdir -p "$CACHE"
CACHE="$(cd "$CACHE" && pwd -P)"
# 命中后只复制已链接二进制，键无需缓存路径。
KEY="$( {
  printf '%s\n' "$REV" "${ARGS[@]}" "$SDK"
  "$CXX" --version
  make --version
  shasum -a 256 < "$0"
} | shasum -a 256 | awk '{print $1}')"
BUILD="$CACHE/7zip/$KEY"
BIN="$BUILD/bin/7zz"
mkdir -p "$BUILD" "$CACHE/bin"
if [ ! -f "$BUILD/complete" ] || [ ! -x "$BIN" ] || [ ! -f "$BUILD/licenses/License.txt" ]; then
  [ -e "$SOURCE/.git" ] && [ -f "$SOURCE/CPP/7zip/Bundles/Alone2/makefile.gcc" ] \
    || error "ThirdParty/7zip 未初始化；请运行 git submodule update --init --recursive。"
  echo "build-7zip: 编译 7zz（${REV}），日志：$BUILD/build.log"
  rm -rf "$BUILD/source" "$BUILD/bin" "$BUILD/licenses"
  mkdir -p "$BUILD/source" "$BUILD/bin"
  # 只读导出 gitlink 对应提交，make 仅在构建副本中运行。
  git -C "$SOURCE" archive "$REV" | tar -x -C "$BUILD/source"
  set +e
  (
    set -e
    cd "$BUILD/source/CPP/7zip/Bundles/Alone2"
    make -j"${BUILD_JOBS:-8}" "${ARGS[@]}"
    cp b/m_arm64/7zz "$BIN"
    strip -x "$BIN"
    codesign --force --sign - --options runtime "$BIN"
  ) > "$BUILD/build.log" 2>&1
  status=$?
  set -e
  [ "$status" = 0 ] || error "构建失败，见 $BUILD/build.log"
  mkdir -p "$BUILD/licenses"
  cp "$BUILD/source/DOC/License.txt" "$BUILD/licenses/"
else
  echo "build-7zip: 缓存命中 $KEY"
fi
verify_binary() {
  local binary="$1" ref formats feature
  [ "$(lipo -archs "$binary")" = arm64 ] || error "$binary 必须仅包含 arm64。"
  while IFS= read -r ref; do
    case "$ref" in
      /usr/lib/*|/System/*) ;;
      *) error "$binary 引用了非系统库：$ref" ;;
    esac
  done < <(otool -L "$binary" | tail -n +2 | awk '{print $1}')
  [ "$(vtool -show-build "$binary" | awk '$1=="minos" {print $2}')" = 26.0 ] \
    || error "$binary 的 minos 不是 26.0。"
  codesign --verify --strict "$binary"
  formats="$("$binary" i)"
  for feature in 7z zip Rar Rar5 tar gzip Split 7zAES AES256CBC; do
    printf '%s\n' "$formats" | grep -w "$feature" >/dev/null || error "缺少 $feature 支持。"
  done
}
# 原子替换，避免覆盖运行中的签名代码页。
copy_binary() {
  local source="$1" destination="$2"
  cp -f "$source" "$destination.tmp.$$"
  mv -f "$destination.tmp.$$" "$destination"
}
verify_binary "$BIN"
touch "$BUILD/complete"
copy_binary "$BIN" "$CACHE/bin/7zz"
if [ "$STANDALONE" = 1 ]; then
  echo "build-7zip: 完成 $CACHE/bin/7zz"
  exit 0
fi

CONTENTS="$TARGET_BUILD_DIR/$CONTENTS_FOLDER_PATH"
LICENSES="$CONTENTS/Resources/Licenses"
DEST="$CONTENTS/Helpers/7zz"
mkdir -p "$CONTENTS/Helpers" "$LICENSES/7zip"
copy_binary "$BIN" "$DEST"
chmod u+w "$DEST"
IDENTITY="${EXPANDED_CODE_SIGN_IDENTITY:--}"
IDENTITY="${IDENTITY:--}"
SIGN_ARGS=(--force --sign "$IDENTITY" --options runtime)
[ "$IDENTITY" = - ] || SIGN_ARGS+=(--timestamp)
codesign "${SIGN_ARGS[@]}" "$DEST"
verify_binary "$DEST"
cp "$BUILD/licenses/License.txt" "$LICENSES/7zip/"
cat > "$LICENSES/7zip/README.txt" <<NOTICE
7-Zip 26.04 — GNU LGPL-2.1-or-later, BSD licenses and unRAR license restriction.
Source: https://github.com/ip7z/7zip/tree/$REV
Build: scripts/build-7zip.sh; upstream Alone2 macOS arm64 makefile, system libraries only.
NOTICE
if ! grep -F '7zip/License.txt' "$LICENSES/README.txt" >/dev/null 2>&1; then
  cat >> "$LICENSES/README.txt" <<NOTICE
7-Zip 26.04 (GNU LGPL, BSD licenses, unRAR restriction): 7zip/License.txt
  Source: https://github.com/ip7z/7zip/tree/$REV
NOTICE
fi
APP_BUNDLE="$TARGET_BUILD_DIR/${WRAPPER_NAME:-$(dirname "$CONTENTS_FOLDER_PATH")}"
# 只验证 App 自身封印，避免尚未签名的测试 PlugIns；grep 读完整个管道。
if [ -d "$APP_BUNDLE" ] && codesign -dv "$APP_BUNDLE" 2>&1 | grep 'Sealed Resources' >/dev/null \
  && ! codesign --verify --strict "$APP_BUNDLE" >/dev/null 2>&1; then
  SIGN_ARGS=(--force --sign "$IDENTITY" --preserve-metadata=entitlements,flags)
  [ "$IDENTITY" = - ] || SIGN_ARGS+=(--timestamp)
  codesign "${SIGN_ARGS[@]}" "$APP_BUNDLE"
  echo "build-7zip: 已修复 App 增量封印"
fi
echo "build-7zip: 已打包并签名 $DEST"
