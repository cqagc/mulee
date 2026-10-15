#!/bin/bash
# 从固定子模块源码构建只依赖系统库的 aria2c；Xcode 阶段负责打包和签名。
set -euo pipefail
export LANG=en_US.UTF-8
export LC_ALL=en_US.UTF-8
export MACOSX_DEPLOYMENT_TARGET=26.0

error() { echo "error: build-aria2: $*" >&2; exit 1; }
SRCROOT="${SRCROOT:-$(cd "$(dirname "$0")/.." && pwd)}"
CACHE="${MULEE_THIRDPARTY_CACHE:-$SRCROOT/build/thirdparty}"
SRCROOT="$(cd "$SRCROOT" && pwd -P)"
mkdir -p "$CACHE"
CACHE="$(cd "$CACHE" && pwd -P)"
# -ffile-prefix-map 同时清理 __FILE__/assert 宏与 DWARF 源码路径。
PREFIX_FLAGS="-ffile-prefix-map=$HOME=home -ffile-prefix-map=$SRCROOT=. -ffile-prefix-map=$CACHE=build/thirdparty"
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
for tool in autoreconf automake glibtoolize autopoint pkg-config git make xcrun codesign otool vtool lipo; do
  command -v "$tool" >/dev/null || error "缺少 $tool；请安装 Xcode 命令行工具及 autoconf automake libtool gettext pkgconf。"
done
SOURCE="$SRCROOT/ThirdParty/aria2"
# 空子模块目录中的 git 会向上找到父仓库，因此先检查模块自身的 .git。
submodule_revision() {
  local module="$1" revision
  if [ -e "$SRCROOT/ThirdParty/$module/.git" ]; then
    git -C "$SRCROOT/ThirdParty/$module" rev-parse HEAD
  else
    revision="$(git -C "$SRCROOT" ls-files -s -- "ThirdParty/$module" | awk '$1 == "160000" && $3 == "0" { print $2 }')"
    [ -n "$revision" ] || error "找不到子模块 ThirdParty/$module 的 gitlink"
    printf '%s\n' "$revision"
  fi
}
REV="$(submodule_revision aria2)"
SDK="$(xcrun --sdk macosx --show-sdk-path)"
CC="$(xcrun -f clang)"
CXX="$(xcrun -f clang++)"
# 不读取构建机的 Homebrew 头文件、库和 pkg-config 搜索路径。
unset CPATH CPLUS_INCLUDE_PATH C_INCLUDE_PATH LIBRARY_PATH PKG_CONFIG_PATH CMAKE_PREFIX_PATH
export PKG_CONFIG_LIBDIR="$SDK/usr/lib/pkgconfig"
FLAGS="-O2 -DNDEBUG -arch arm64 -mmacosx-version-min=26.0 -isysroot $SDK $PREFIX_FLAGS"
ARGS=(--with-appletls --without-openssl --without-gnutls
  --disable-bittorrent --disable-metalink --without-sqlite3
  --without-libxml2 --without-libexpat --without-libssh2 --without-libcares
  --disable-nls --with-libz --without-libuv --without-libnettle
  --without-libgmp --without-libgcrypt --disable-shared --disable-libaria2)
mkdir -p "$CACHE"
CACHE="$(cd "$CACHE" && pwd -P)"
# configure 的绝对路径只供源码构建使用；命中后只复制已链接二进制，键无需缓存路径。
KEY="$( {
  printf '%s\n' "$REV" "$FLAGS" '-stdlib=libc++' "${ARGS[@]}" "$SDK"
  "$CXX" --version
  autoreconf --version
  automake --version
  glibtoolize --version
  autopoint --version
  pkg-config --version
  shasum -a 256 < "$0"
} | shasum -a 256 | awk '{print $1}')"
BUILD="$CACHE/aria2/$KEY"
BIN="$BUILD/bin/aria2c"
mkdir -p "$BUILD" "$CACHE/bin"
if [ ! -f "$BUILD/complete" ] || [ ! -x "$BIN" ]; then
  [ -e "$SOURCE/.git" ] && [ -f "$SOURCE/configure.ac" ] \
    || error "ThirdParty/aria2 未初始化；请运行 git submodule update --init --recursive。"
  echo "build-aria2: 编译 AppleTLS aria2c（${REV}），日志：$BUILD/build.log"
  rm -rf "$BUILD/source" "$BUILD/obj" "$BUILD/bin"
  mkdir -p "$BUILD/source" "$BUILD/obj" "$BUILD/bin"
  # 只读导出精确提交，autoreconf 和 configure 均在构建副本中运行。
  git -C "$SOURCE" archive "$REV" | tar -x -C "$BUILD/source"
  set +e
  (
    set -e
    cd "$BUILD/source"
    autoreconf -i
    cd "$BUILD/obj"
    CC="$CC" CXX="$CXX" CPPFLAGS= CFLAGS="$FLAGS" CXXFLAGS="$FLAGS -stdlib=libc++" \
      LDFLAGS="-arch arm64 -mmacosx-version-min=26.0 -isysroot $SDK -stdlib=libc++" \
      ZLIB_CFLAGS="-I$SDK/usr/include" ZLIB_LIBS="-L$SDK/usr/lib -lz" \
      "$BUILD/source/configure" "${ARGS[@]}"
    make -j"${BUILD_JOBS:-8}" -C deps
    make -j"${BUILD_JOBS:-8}" -C src aria2c
    cp src/aria2c "$BIN"
    strip -x "$BIN"
    codesign --force --sign - --options runtime "$BIN"
  ) > "$BUILD/build.log" 2>&1
  status=$?
  set -e
  [ "$status" = 0 ] || error "构建失败，见 $BUILD/build.log"
  mkdir -p "$BUILD/licenses"
  cp "$BUILD/source/COPYING" "$BUILD/source/LICENSE.OpenSSL" "$BUILD/licenses/"
else
  echo "build-aria2: 缓存命中 $KEY"
fi
verify_binary() {
  local binary="$1" ref version
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
  version="$("$binary" --version)"
  printf '%s\n' "$version" | grep 'Enabled Features:.*HTTPS' >/dev/null || error "缺少 HTTPS。"
  printf '%s\n' "$version" | grep 'Enabled Features:.*GZip' >/dev/null || error "缺少 GZip。"
  printf '%s\n' "$version" | grep 'AppleTLS' >/dev/null || error "未使用 AppleTLS。"
}
# 原子替换，避免覆盖运行中的签名代码页。
copy_binary() {
  local source="$1" destination="$2"
  cp -f "$source" "$destination.tmp.$$"
  mv -f "$destination.tmp.$$" "$destination"
}
verify_binary "$BIN"
touch "$BUILD/complete"
copy_binary "$BIN" "$CACHE/bin/aria2c"
if [ "$STANDALONE" = 1 ]; then
  echo "build-aria2: 完成 $CACHE/bin/aria2c"
  exit 0
fi

CONTENTS="$TARGET_BUILD_DIR/$CONTENTS_FOLDER_PATH"
LICENSES="$CONTENTS/Resources/Licenses"
DEST="$CONTENTS/Helpers/aria2c"
# 清除旧动态版资源，仅删除本引擎原先携带的 Homebrew 许可证。
rm -rf "$CONTENTS/Frameworks/aria2" "$CONTENTS/Resources/aria2"
for component in aria2 openssl@4 libssh2 c-ares sqlite gettext ca-certificates; do
  rm -rf "$LICENSES/$component"
done
mkdir -p "$CONTENTS/Helpers" "$LICENSES/aria2"
copy_binary "$BIN" "$DEST"
chmod u+w "$DEST"
IDENTITY="${EXPANDED_CODE_SIGN_IDENTITY:--}"
IDENTITY="${IDENTITY:--}"
SIGN_ARGS=(--force --sign "$IDENTITY" --options runtime)
[ "$IDENTITY" = - ] || SIGN_ARGS+=(--timestamp)
codesign "${SIGN_ARGS[@]}" "$DEST"
verify_binary "$DEST"
cp "$BUILD/licenses/COPYING" "$BUILD/licenses/LICENSE.OpenSSL" "$LICENSES/aria2/"
cat > "$LICENSES/aria2/README.txt" <<NOTICE
aria2 1.37.0 — GPL-2.0-or-later with OpenSSL linking exception (LICENSE.OpenSSL).
Source: https://github.com/aria2/aria2/tree/$REV
Build: scripts/build-aria2.sh; HTTP / HTTPS / FTP, AppleTLS and system zlib.
AppleTLS uses system Keychain trust. System libraries are not redistributed.
NOTICE
# 重建总索引也清除旧 Homebrew 条目；后续引擎阶段会追加各自说明。
cat > "$LICENSES/README.txt" <<NOTICE
Mulee bundles third-party software; license texts are in the named subdirectories.
aria2 1.37.0 (GPL-2.0-or-later with OpenSSL exception): aria2/COPYING, aria2/LICENSE.OpenSSL
  Source: https://github.com/aria2/aria2/tree/$REV
NOTICE
APP_BUNDLE="$TARGET_BUILD_DIR/${WRAPPER_NAME:-$(dirname "$CONTENTS_FOLDER_PATH")}"
# 只验证 App 自身封印，避免尚未签名的测试 PlugIns；grep 读完整个管道。
if [ -d "$APP_BUNDLE" ] && codesign -dv "$APP_BUNDLE" 2>&1 | grep 'Sealed Resources' >/dev/null \
  && ! codesign --verify --strict "$APP_BUNDLE" >/dev/null 2>&1; then
  SIGN_ARGS=(--force --sign "$IDENTITY" --preserve-metadata=entitlements,flags)
  [ "$IDENTITY" = - ] || SIGN_ARGS+=(--timestamp)
  codesign "${SIGN_ARGS[@]}" "$APP_BUNDLE"
  echo "build-aria2: 已修复 App 增量封印"
fi
echo "build-aria2: 已打包并签名 $DEST"
