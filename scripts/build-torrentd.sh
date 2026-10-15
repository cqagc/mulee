#!/bin/bash
# 静态构建 BT 辅助进程；也供 Xcode postBuildScripts 打包使用。
set -euo pipefail
export LANG=en_US.UTF-8
export LC_ALL=en_US.UTF-8
export MACOSX_DEPLOYMENT_TARGET=26.0

error() { echo "error: mulee-torrentd: $*" >&2; exit 1; }
SRCROOT="${SRCROOT:-$(cd "$(dirname "$0")/.." && pwd)}"
CACHE="${MULEE_THIRDPARTY_CACHE:-$SRCROOT/build/thirdparty}"
STANDALONE=0
if [ "${1:-}" = "--standalone" ] && [ "$#" = 1 ]; then
  STANDALONE=1
elif [ "$#" != 0 ]; then
  error "用法：$0 [--standalone]"
fi
for tool in cmake clang++; do
  command -v "$tool" >/dev/null || error "缺少 $tool；请安装 Xcode 命令行工具并运行 brew install cmake boost"
done
BOOST=/opt/homebrew/opt/boost
[ -f "$BOOST/include/boost/json/src.hpp" ] || error "缺少 Boost；请运行 brew install cmake boost"
for sub in openssl libtorrent; do
  [ -f "$SRCROOT/ThirdParty/$sub/.git" ] && [ -d "$SRCROOT/ThirdParty/$sub/include" ] \
    || error "子模块 $sub 未初始化；请运行 git submodule update --init --recursive"
done

mkdir -p "$CACHE"
CACHE="$(cd "$CACHE" && pwd)"
JOBS="$(sysctl -n hw.logicalcpu)"
OPENSSL_FLAGS=(darwin64-arm64-cc no-shared no-tests no-docs no-apps -mmacosx-version-min=26.0 --openssldir=/private/etc/ssl)
LT_FLAGS=(-DCMAKE_BUILD_TYPE=Release -DBUILD_SHARED_LIBS=OFF -DCMAKE_OSX_ARCHITECTURES=arm64
  -DCMAKE_OSX_DEPLOYMENT_TARGET=26.0 -DOPENSSL_USE_STATIC_LIBS=TRUE
  -Ddeprecated-functions=OFF -Dpython-bindings=OFF -Dbuild_tools=OFF
  "-DBoost_ROOT=$BOOST" -DCMAKE_CXX_STANDARD=17)
KEY="$( {
  git -C "$SRCROOT/ThirdParty/openssl" rev-parse HEAD
  git -C "$SRCROOT/ThirdParty/libtorrent" rev-parse HEAD
  printf '%s\n' "${OPENSSL_FLAGS[@]}" "${LT_FLAGS[@]}" "$CACHE"
  clang++ --version
  xcrun --show-sdk-path
  cat "$BOOST/include/boost/version.hpp"
} | shasum -a 256 | awk '{print $1}')"
DEPS="$CACHE/$KEY"
SSL="$DEPS/openssl"
LT="$DEPS/libtorrent"
mkdir -p "$DEPS" "$CACHE/bin"
if [ ! -f "$DEPS/complete" ] || [ ! -f "$SSL/lib/libcrypto.a" ] || [ ! -f "$LT/lib/libtorrent-rasterbar.a" ]; then
  echo "mulee-torrentd: 首次构建静态依赖（约 8 分钟），日志：$DEPS"
  rm -rf "$DEPS/openssl-src" "$DEPS/libtorrent-build" "$SSL" "$LT"
  mkdir -p "$DEPS/openssl-src"
  # 在源码副本中构建，绝不写子模块。
  rsync -a --exclude .git "$SRCROOT/ThirdParty/openssl/" "$DEPS/openssl-src/"
  (
    cd "$DEPS/openssl-src"
    ./Configure "${OPENSSL_FLAGS[@]}" "--prefix=$SSL"
    make -j"$JOBS"
    make install_sw
  ) > "$DEPS/openssl.log" 2>&1 || error "OpenSSL 构建失败，见 $DEPS/openssl.log"
  cmake -S "$SRCROOT/ThirdParty/libtorrent" -B "$DEPS/libtorrent-build" -G 'Unix Makefiles' \
    "${LT_FLAGS[@]}" "-DOPENSSL_ROOT_DIR=$SSL" "-DCMAKE_INSTALL_PREFIX=$LT" \
    > "$DEPS/libtorrent.log" 2>&1 \
    && cmake --build "$DEPS/libtorrent-build" -j"$JOBS" >> "$DEPS/libtorrent.log" 2>&1 \
    && cmake --install "$DEPS/libtorrent-build" >> "$DEPS/libtorrent.log" 2>&1 \
    || error "libtorrent 构建失败，见 $DEPS/libtorrent.log"
  touch "$DEPS/complete"
else
  echo "mulee-torrentd: 静态依赖缓存命中 $KEY"
fi

BIN="$CACHE/bin/mulee-torrentd"
clang++ -std=c++17 -O2 -arch arm64 -mmacosx-version-min=26.0 -Wl,-dead_strip \
  -DBOOST_ASIO_ENABLE_CANCELIO -DBOOST_ASIO_NO_DEPRECATED -DTORRENT_NO_DEPRECATE \
  -DTORRENT_USE_OPENSSL -DTORRENT_USE_LIBCRYPTO -DTORRENT_SSL_PEERS \
  -DOPENSSL_NO_SSL2 -DOPENSSL_NO_SSL3 -DOPENSSL_NO_TLS1 -DOPENSSL_NO_TLS1_1 -DOPENSSL_NO_DTLS1 \
  -I"$LT/include" -I"$SSL/include" -I"$BOOST/include" \
  "$SRCROOT"/Helpers/mulee-torrentd/*.cpp \
  "$LT/lib/libtorrent-rasterbar.a" "$SSL/lib/libssl.a" "$SSL/lib/libcrypto.a" \
  -framework CoreFoundation -framework SystemConfiguration -o "$BIN.tmp"
while IFS= read -r ref; do
  case "$ref" in
    /usr/lib/*|/System/*) ;;
    *) error "辅助进程引用了非系统库：$ref" ;;
  esac
done < <(otool -L "$BIN.tmp" | tail -n +2 | awk '{print $1}')
mv -f "$BIN.tmp" "$BIN"
if [ "$STANDALONE" = 1 ]; then
  echo "mulee-torrentd: $BIN"
  exit 0
fi

: "${TARGET_BUILD_DIR:?需要在 Xcode 构建阶段中运行，或传 --standalone}"
: "${CONTENTS_FOLDER_PATH:?缺少 CONTENTS_FOLDER_PATH}"
CONTENTS="$TARGET_BUILD_DIR/$CONTENTS_FOLDER_PATH"
DEST="$CONTENTS/Helpers/mulee-torrentd"
LICENSES="$CONTENTS/Resources/Licenses"
mkdir -p "$(dirname "$DEST")" "$LICENSES/libtorrent" "$LICENSES/openssl" "$LICENSES/boost"
cp -f "$BIN" "$DEST"
chmod u+w "$DEST"
IDENTITY="${EXPANDED_CODE_SIGN_IDENTITY:--}"
[ -n "$IDENTITY" ] || IDENTITY=-
if [ "$IDENTITY" = - ]; then
  codesign --force --sign - --options runtime "$DEST"
else
  codesign --force --sign "$IDENTITY" --options runtime --timestamp "$DEST"
fi
cp -f "$SRCROOT/ThirdParty/libtorrent/COPYING" "$LICENSES/libtorrent/"
cp -f "$SRCROOT/ThirdParty/openssl/LICENSE.txt" "$LICENSES/openssl/"
# Homebrew Boost does not ship the top-level license. libtorrent's aggregate
# LICENSE includes the unmodified BSL-1.0 text; extract that complete section.
awk '/^Boost Software License - Version 1.0/ { copy=1 } copy && /^---/ { exit } copy { print }' \
  "$SRCROOT/ThirdParty/libtorrent/LICENSE" > "$LICENSES/boost/LICENSE_1_0.txt"
[ -s "$LICENSES/boost/LICENSE_1_0.txt" ] || error "找不到 Boost 许可证文本"
cat >> "$LICENSES/README.txt" <<NOTICE
libtorrent-rasterbar 2.0.15 (BSD-3-Clause): libtorrent/COPYING
  Source: https://github.com/arvidn/libtorrent/tree/$(git -C "$SRCROOT/ThirdParty/libtorrent" rev-parse HEAD)
OpenSSL 3.5.9 (Apache-2.0): openssl/LICENSE.txt
  Source: https://github.com/openssl/openssl/tree/$(git -C "$SRCROOT/ThirdParty/openssl" rev-parse HEAD)
Boost (BSL-1.0): boost/LICENSE_1_0.txt
  Source: https://www.boost.org/
NOTICE

# 增量构建可能没有后续 Xcode CodeSign；沿用 aria2 的封印修复方式。
APP_BUNDLE="$TARGET_BUILD_DIR/${WRAPPER_NAME:-$(dirname "$CONTENTS_FOLDER_PATH")}"
if [ -d "$APP_BUNDLE" ] && codesign -dv "$APP_BUNDLE" 2>&1 | grep -q 'Sealed Resources' \
  && ! codesign --verify --strict "$APP_BUNDLE" >/dev/null 2>&1; then
  if [ "$IDENTITY" = - ]; then
    codesign --force --sign - --preserve-metadata=entitlements,flags "$APP_BUNDLE"
  else
    codesign --force --sign "$IDENTITY" --timestamp --preserve-metadata=entitlements,flags "$APP_BUNDLE"
  fi
fi
echo "mulee-torrentd: 已打包并签名 $DEST"
