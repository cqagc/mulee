#!/bin/bash
# 从固定子模块源码构建 arm64 / macOS 26 的静态 amuled；Xcode 阶段负责打包和签名。
# --standalone 另编 amulecmd 供 scripts/test-amuled.sh 使用，不把它放进 App。
set -euo pipefail
export LANG=en_US.UTF-8
export LC_ALL=en_US.UTF-8

error() { echo "error: $*" >&2; exit 1; }
SRCROOT="${SRCROOT:-$(cd "$(dirname "$0")/.." && pwd)}"
CACHE="${MULEE_THIRDPARTY_CACHE:-$SRCROOT/build/thirdparty}"
STANDALONE=OFF
case "${1:-}" in
  --standalone) STANDALONE=ON ;;
  "")
    : "${TARGET_BUILD_DIR:?需要在 Xcode 构建阶段运行，或传 --standalone}"
    : "${CONTENTS_FOLDER_PATH:?缺少 CONTENTS_FOLDER_PATH}"
    ;;
  *) error "用法：$0 [--standalone]" ;;
esac
[ "$(uname -m)" = arm64 ] || error "仅支持 Apple Silicon arm64 构建机。"
for tool in cmake git make xcrun codesign otool shasum; do
  command -v "$tool" >/dev/null || error "缺少 ${tool}；请安装 Xcode Command Line Tools 和 brew install cmake boost。"
done
BOOST=/opt/homebrew/opt/boost
[ -f "$BOOST/include/boost/asio.hpp" ] || error "缺少 Boost 头文件：请运行 brew install boost（需要 ${BOOST}）。"
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
AMULE_REV="$(submodule_revision amule)"
WX_REV="$(submodule_revision wxWidgets)"
CRYPTO_REV="$(submodule_revision cryptopp)"
SDK="$(xcrun --sdk macosx --show-sdk-path)"
CC="$(xcrun -f clang)"
CXX="$(xcrun -f clang++)"
export MACOSX_DEPLOYMENT_TARGET=26.0
# 避免调用者的 Homebrew include / lib / pkg-config 环境影响静态依赖选择。
unset CPATH CPLUS_INCLUDE_PATH C_INCLUDE_PATH LIBRARY_PATH PKG_CONFIG_PATH CMAKE_PREFIX_PATH
export PKG_CONFIG_LIBDIR="$SDK/usr/lib/pkgconfig"
JOBS="${BUILD_JOBS:-8}"
FLAGS="-O2 -DNDEBUG -arch arm64 -mmacosx-version-min=26.0 -isysroot $SDK"
# wx 3.2 的 base-only configure 漏掉 macOS 平台宏；ObjC++ 工具代码仍使用 AppKit 类型。
WX_CPPFLAGS="-D__WXMAC__ -D__WXOSX__"
WX_OBJCXXFLAGS="$FLAGS -std=c++17 -include AppKit/AppKit.h"
WX_ARGS=(--with-osx_cocoa "--with-macosx-sdk=$SDK" --disable-gui --disable-shared --enable-unicode --disable-debug
  --disable-precomp-headers --disable-tests
  --with-regex=builtin --with-expat=builtin --with-zlib=sys
  --without-libcurl --with-urlsession --without-liblzma
  --without-libpng --without-libjpeg --without-libtiff
  --enable-macosx_arch=arm64 --with-macosx-version-min=26.0)
AMULE_ARGS=(-DCMAKE_BUILD_TYPE=Release -DCMAKE_OSX_ARCHITECTURES=arm64
  -DCMAKE_OSX_DEPLOYMENT_TARGET=26.0 -DCMAKE_CXX_STANDARD=17
  -DCMAKE_CXX_STANDARD_REQUIRED=ON -DBUILD_SHARED_LIBS=OFF
  -DBUILD_DAEMON=ON -DBUILD_MONOLITHIC=OFF -DBUILD_REMOTEGUI=OFF
  -DBUILD_WEBSERVER=OFF -DBUILD_AMULEAPI=OFF -DBUILD_ED2K=OFF
  -DBUILD_CAS=OFF -DBUILD_WXCAS=OFF -DBUILD_ALC=OFF -DBUILD_ALCC=OFF
  -DBUILD_FILEVIEW=OFF -DBUILD_EVERYTHING=OFF -DBUILD_TESTING=OFF
  -DENABLE_NLS=OFF -DENABLE_IP2COUNTRY=OFF -DENABLE_BFD=OFF
  -DENABLE_UPNP=OFF -DENABLE_VERSION_CHECK=OFF -DDOWNLOAD_AND_BUILD_DEPS=OFF
  -DCMAKE_DISABLE_FIND_PACKAGE_CURL=ON -DUSE_SYSTEM_PICOJSON=OFF)
hash() { shasum -a 256 | awk '{print $1}'; }
TOOLCHAIN="$("$CXX" --version) $(xcrun --sdk macosx --show-sdk-version)"
WX_KEY="$(printf '%s\n' "$WX_REV" "$FLAGS" "$WX_CPPFLAGS" "$WX_OBJCXXFLAGS" "$TOOLCHAIN" "${WX_ARGS[@]}" | hash)"
CRYPTO_KEY="$(printf '%s\n' "$CRYPTO_REV" "$FLAGS -std=c++17" "$TOOLCHAIN" | hash)"
KEY="$(printf '%s\n' "$AMULE_REV" "$WX_KEY" "$CRYPTO_KEY" "$STANDALONE" \
  "${AMULE_ARGS[@]}" "$(hash < "$BOOST/include/boost/version.hpp")" "$(hash < "$0")" | hash)"
# wx-config / CMake 内的绝对路径仅在编译时使用；命中后复制已链接二进制，键无需缓存路径。
mkdir -p "$CACHE"
CACHE="$(cd "$CACHE" && pwd -P)"
WX="$CACHE/amuled/wx-$WX_KEY"
CRYPTO="$CACHE/amuled/cryptopp-$CRYPTO_KEY"
BUILD="$CACHE/amuled/$KEY"
mkdir -p "$CACHE/bin" "$BUILD"
# git archive 只读导出精确提交；不带 .git，不会修改子模块或 Git 状态。
export_source() {
  local module="$1" dest="$2"
  [ -e "$SRCROOT/ThirdParty/$module/.git" ] \
    || error "子模块 ThirdParty/$module 未初始化；请由主控运行 git submodule update --init --recursive。"
  mkdir -p "$dest"
  git -C "$SRCROOT/ThirdParty/$module" archive HEAD | tar -x -C "$dest"
  if [ "$module" = wxWidgets ]; then
    local nested expected actual
    for nested in 3rdparty/pcre src/expat; do
      expected="$(git -C "$SRCROOT/ThirdParty/$module" rev-parse "HEAD:$nested")"
      [ -e "$SRCROOT/ThirdParty/$module/$nested/.git" ] \
        || error "wxWidgets 嵌套子模块 $nested 未初始化；请由主控递归初始化子模块。"
      actual="$(git -C "$SRCROOT/ThirdParty/$module/$nested" rev-parse HEAD)"
      [ "$actual" = "$expected" ] || error "wxWidgets/$nested 提交与父模块锁定值不同。"
      mkdir -p "$dest/$nested"
      git -C "$SRCROOT/ThirdParty/$module/$nested" archive HEAD | tar -x -C "$dest/$nested"
    done
  fi
}
if [ ! -f "$WX/complete" ]; then
  mkdir -p "$WX/build"
  export_source wxWidgets "$WX/source"
  echo "build-amuled: 编译 wxWidgets base + net（${WX_REV}）"
  (
    cd "$WX/build"
    CC="$CC" CXX="$CXX" CPPFLAGS="$WX_CPPFLAGS" CFLAGS="$FLAGS" CXXFLAGS="$FLAGS -std=c++17" \
      OBJCXXFLAGS="$WX_OBJCXXFLAGS" \
      LDFLAGS="-arch arm64 -mmacosx-version-min=26.0 -isysroot $SDK" \
      "$WX/source/configure" --prefix="$WX/prefix" "${WX_ARGS[@]}"
    make -j "$JOBS" wxbase wxnet \
      "$WX/build/lib/libwxregexu-3.2.a" "$WX/build/lib/libwxexpat-3.2.a"
  )
  touch "$WX/complete"
fi
if [ ! -f "$CRYPTO/complete" ]; then
  export_source cryptopp "$CRYPTO/source"
  echo "build-amuled: 编译 Crypto++ 静态库（${CRYPTO_REV}）"
  make -C "$CRYPTO/source" -j "$JOBS" static CXX="$CXX" \
    CXXFLAGS="$FLAGS -std=c++17"
  mkdir -p "$CRYPTO/include/cryptopp"
  cp "$CRYPTO/source/"*.h "$CRYPTO/include/cryptopp/"
  touch "$CRYPTO/complete"
fi
if [ ! -f "$BUILD/complete" ]; then
  export_source amule "$BUILD/source"
  echo "build-amuled: 编译 amuled（${AMULE_REV}；amulecmd=${STANDALONE}）"
  cmake -S "$BUILD/source" -B "$BUILD/build" -G 'Unix Makefiles' \
    "${AMULE_ARGS[@]}" "-DBUILD_AMULECMD=$STANDALONE" \
    "-DCMAKE_C_COMPILER=$CC" "-DCMAKE_CXX_COMPILER=$CXX" \
    "-DCMAKE_OSX_SYSROOT=$SDK" \
    "-DCMAKE_CXX_FLAGS=$WX_CPPFLAGS -I$CRYPTO/include -I$BOOST/include" \
    '-DCMAKE_EXE_LINKER_FLAGS=-framework AppKit' \
    "-DCRYPTOPP_INCLUDE_DIR=$CRYPTO/include" \
    "-DCRYPTOPP_LIBRARY=$CRYPTO/source/libcryptopp.a" \
    "-DwxWidgets_CONFIG_EXECUTABLE=$WX/build/wx-config" \
    '-DwxWidgets_CONFIG_OPTIONS=--static;--inplace' -DwxWidgets_USE_STATIC=ON \
    "-DCMAKE_PREFIX_PATH=$BOOST" \
    "-DZLIB_INCLUDE_DIR=$SDK/usr/include" "-DZLIB_LIBRARY=$SDK/usr/lib/libz.tbd" \
    -DHAVE_LIBREADLINE=OFF -DHAVE_READLINE_HISTORY=OFF
  TARGETS=(amuled)
  [ "$STANDALONE" = OFF ] || TARGETS+=(amulecmd)
  cmake --build "$BUILD/build" --parallel "$JOBS" --target "${TARGETS[@]}"
  mkdir -p "$BUILD/bin"
  for name in "${TARGETS[@]}"; do
    cp "$BUILD/build/src/$name" "$BUILD/bin/$name"
    strip -x "$BUILD/bin/$name"
    codesign --force --sign - --options runtime "$BUILD/bin/$name"
  done
  mkdir -p "$BUILD/licenses/"{amule,picojson}
  cp "$BUILD/source/LICENSE.md" "$BUILD/licenses/amule/"
  cp "$BUILD/source/src/libwebcommon/picojson.LICENSE" "$BUILD/licenses/picojson/"
  mkdir -p "$BUILD/licenses/"{wxWidgets,pcre2,expat}
  cp "$WX/source/docs/"{licence,lgpl,gpl}.txt "$BUILD/licenses/wxWidgets/"
  cp "$WX/source/3rdparty/pcre/LICENCE" "$BUILD/licenses/pcre2/"
  cp "$WX/source/src/expat/expat/COPYING" "$BUILD/licenses/expat/"
  mkdir -p "$BUILD/licenses/"{cryptopp,boost}
  cp "$CRYPTO/source/License.txt" "$BUILD/licenses/cryptopp/"
  # Homebrew Boost 没有附许可证；Crypto++ 附带同一份 BSL-1.0 原文。
  sed -n '/^Boost Software License - Version 1.0/,/^CRYPTOGAMS License/{ /^CRYPTOGAMS License/d; p; }' \
    "$CRYPTO/source/License.txt" | tr -d '\r' > "$BUILD/licenses/boost/LICENSE_1_0.txt"
  touch "$BUILD/complete"
else
  echo "build-amuled: 缓存命中 $KEY"
fi
verify_binary() {
  local binary="$1" ref
  [ "$(lipo -archs "$binary")" = arm64 ] || error "$binary 必须仅包含 arm64。"
  while IFS= read -r ref; do
    case "$ref" in
      /usr/lib/*|/System/*) ;;
      *) error "$binary 残留非系统动态依赖：$ref" ;;
    esac
  done < <(otool -L "$binary" | tail -n +2 | awk '{print $1}')
  [ "$(vtool -show-build "$binary" | awk '$1=="minos" {print $2}')" = 26.0 ] \
    || error "$binary 的 LC_BUILD_VERSION minos 不是 26.0。"
  codesign --verify --strict "$binary"
}
# 原子替换，避免增量构建覆盖正在运行的已签名映像，引起 CODESIGNING Invalid Page。
copy_binary() {
  local source="$1" destination="$2" staging
  staging="$destination.tmp.$$"
  cp -f "$source" "$staging"
  mv -f "$staging" "$destination"
}
verify_binary "$BUILD/bin/amuled"
copy_binary "$BUILD/bin/amuled" "$CACHE/bin/amuled"
if [ "$STANDALONE" = ON ]; then
  verify_binary "$BUILD/bin/amulecmd"
  copy_binary "$BUILD/bin/amulecmd" "$CACHE/bin/amulecmd"
  echo "build-amuled: 完成 $CACHE/bin/{amuled,amulecmd}"
  exit 0
fi

# ---------- Xcode 打包 / 签名 ----------
CONTENTS="$TARGET_BUILD_DIR/$CONTENTS_FOLDER_PATH"
LICENSES="$CONTENTS/Resources/Licenses"
mkdir -p "$CONTENTS/Helpers" "$LICENSES"
BIN_DEST="$CONTENTS/Helpers/amuled"
copy_binary "$BUILD/bin/amuled" "$BIN_DEST"
chmod u+w "$BIN_DEST"
IDENTITY="${EXPANDED_CODE_SIGN_IDENTITY:--}"
IDENTITY="${IDENTITY:--}"
if [ "$IDENTITY" = - ]; then
  codesign --force --sign - --options runtime "$BIN_DEST"
else
  codesign --force --sign "$IDENTITY" --options runtime --timestamp "$BIN_DEST"
fi
verify_binary "$BIN_DEST"
# 只写本引擎自己的目录；Boost 与 BT helper 共用同名许可证。
for component in amule wxWidgets cryptopp boost pcre2 expat picojson; do
  mkdir -p "$LICENSES/$component"
done
cp -R "$BUILD/licenses/" "$LICENSES/"
cat > "$LICENSES/amule/README.txt" <<NOTICE
amuled 3.1.0 — GPL-2.0-or-later
Source: https://github.com/amule-org/amule/tree/$AMULE_REV
wxWidgets 3.2.12 — wxWindows Library Licence 3.1 (LGPL with linking exception)
Source: https://github.com/wxWidgets/wxWidgets/tree/$WX_REV
Crypto++ 8.9.0 — compilation BSL-1.0; individual files public domain.
License.txt also records CRYPTOGAMS terms (32-bit ARM Linux code is not used here).
Source: https://github.com/weidai11/cryptopp/tree/$CRYPTO_REV
Boost $(sed -n 's/^#define BOOST_LIB_VERSION "\(.*\)"/\1/p' "$BOOST/include/boost/version.hpp") — BSL-1.0, headers only; shared Licenses/boost/LICENSE_1_0.txt.
Source: https://www.boost.org/
PCRE2 — wxWidgets vendored version; BSD terms and PCRE2 linking exception (see pcre2/LICENCE).
picojson 1.3.0 — BSD-2-Clause (aMule credential persistence).
Expat — MIT, vendored with wxWidgets; supplied for completeness, XML library is not linked.
System zlib and Apple frameworks are not redistributed.
The exact source revisions above and scripts/build-amuled.sh are required build materials.
NOTICE
APP_BUNDLE="$TARGET_BUILD_DIR/${WRAPPER_NAME:-$(dirname "$CONTENTS_FOLDER_PATH")}"
# 与 bundle-aria2.sh 一致：只验证 App 自身封印，避免尚未签名的测试 PlugIns。
# grep 必须读完整个输出；grep -q 提前关闭管道会让 codesign 在 pipefail 下返回 141。
if [ -d "$APP_BUNDLE" ] && codesign -dv "$APP_BUNDLE" 2>&1 | grep 'Sealed Resources' >/dev/null \
  && ! codesign --verify --strict "$APP_BUNDLE" >/dev/null 2>&1; then
  SIGN_ARGS=(--force --sign "$IDENTITY" "--preserve-metadata=entitlements,flags")
  [ "$IDENTITY" = - ] || SIGN_ARGS+=(--timestamp)
  if codesign "${SIGN_ARGS[@]}" "$APP_BUNDLE"; then
    echo "build-amuled: 已重签 ${APP_BUNDLE}（封印已失效）"
  else
    echo "warning: build-amuled: App 重签失败，交给 Xcode 的 CodeSign 阶段处理。" >&2
  fi
fi
echo "build-amuled: 完成 $BIN_DEST"
