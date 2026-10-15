#!/bin/bash
# 把 aria2c 及其 Homebrew dylib 打包进 Mulee.app（由 Xcode 的 postBuildScripts 阶段调用）。
# 构建机需要 `brew install aria2`（或用 ARIA2C_SOURCE 指向一个 aria2c），运行方不需要。
# 产物：Contents/Helpers/aria2c、Contents/Frameworks/aria2/*.dylib、
#       Contents/Frameworks/aria2/ossl-modules/legacy.dylib、
#       Contents/Resources/aria2/cert.pem、Contents/Resources/Licenses/。
# 注意：Homebrew 的 libcrypto 把 MODULESDIR / OPENSSLDIR 写死成 /opt/homebrew 路径，
# 引擎启动 aria2c 时必须设 OPENSSL_MODULES=<App>/Contents/Frameworks/aria2/ossl-modules
# 并传 --ca-certificate=<App>/Contents/Resources/aria2/cert.pem（见 docs/BUILDING.md）。
# 说明见 docs/BUILDING.md。
#
# 沙盒：脚本要读 /opt/homebrew，且输入集合（间接依赖）事先不可知，没法逐个声明为
# inputFiles，所以 project.yml 里对 Mulee target 关闭了 ENABLE_USER_SCRIPT_SANDBOXING。
#
# 签名顺序：本阶段位于 Xcode 对 App 最终签名之前；Xcode 随后会重新签 App 并把
# Helpers / Frameworks 下已签好的内容封进 App 的资源封印，所以 --deep --strict 验证能通过。
# 但增量构建时 Xcode 不会重签，所以脚本末尾会检查封印、失效时自己重签 App。
set -euo pipefail
export LANG=en_US.UTF-8
export LC_ALL=en_US.UTF-8

error() { echo "error: $*" >&2; exit 1; }
warning() { echo "warning: $*" >&2; }

: "${TARGET_BUILD_DIR:?需要在 Xcode 构建阶段中运行（缺少 TARGET_BUILD_DIR）}"
: "${CONTENTS_FOLDER_PATH:?缺少 CONTENTS_FOLDER_PATH}"
SRCROOT="${SRCROOT:-$(cd "$(dirname "$0")/.." && pwd)}"

# ---------- 1. 来源 ----------
SOURCE="${ARIA2C_SOURCE:-}"
if [ -z "$SOURCE" ]; then
  if BREW_PREFIX="$(brew --prefix aria2 2>/dev/null)" && [ -x "$BREW_PREFIX/bin/aria2c" ]; then
    SOURCE="$BREW_PREFIX/bin/aria2c"
  elif [ -x /opt/homebrew/opt/aria2/bin/aria2c ]; then
    SOURCE=/opt/homebrew/opt/aria2/bin/aria2c
  fi
fi
if [ -z "$SOURCE" ] || [ ! -x "$SOURCE" ]; then
  error "找不到 aria2c。请先运行 brew install aria2，或用环境变量 ARIA2C_SOURCE 指定 aria2c 的路径。"
fi
echo "bundle-aria2: 来源 $SOURCE"

CONTENTS="$TARGET_BUILD_DIR/$CONTENTS_FOLDER_PATH"
HELPERS="$CONTENTS/Helpers"
LIBDIR="$CONTENTS/Frameworks/aria2"
MODDIR="$LIBDIR/ossl-modules"
RESDIR="$CONTENTS/Resources/aria2"
LICENSES="$CONTENTS/Resources/Licenses"

rm -rf "$LIBDIR" "$RESDIR" "$LICENSES" "$HELPERS/aria2c"
mkdir -p "$HELPERS" "$LIBDIR" "$RESDIR" "$LICENSES"

is_system() {
  case "$1" in
    /usr/lib/*|/System/*) return 0 ;;
    *) return 1 ;;
  esac
}

# install_name_tool 每次都会警告签名失效，而我们最后会重新签名，所以过滤掉这条（真正的错误照常输出）
install_name_tool() {
  command install_name_tool "$@" 2> >(grep -v "will invalidate the code signature" >&2) || return 1
}

# 一个 Mach-O 的直接依赖（第一行是自身 ID / 路径，跳过）
deps_of() { otool -L "$1" | tail -n +2 | awk '{print $1}'; }

rpaths_of() {
  otool -l "$1" | awk '$1=="cmd" && $2=="LC_RPATH" {f=1} f && $1=="path" {print $2; f=0}'
}

# 把依赖引用解析成源文件系统上的真实路径：$1=引用 $2=引用方的源文件
resolve_ref() {
  local ref="$1" from="$2" dir rp cand
  dir="$(dirname "$from")"
  case "$ref" in
    /*) cand="$ref" ;;
    @loader_path/*) cand="$dir/${ref#@loader_path/}" ;;
    @executable_path/*) cand="$(dirname "$SOURCE")/${ref#@executable_path/}" ;;
    @rpath/*)
      cand=""
      while IFS= read -r rp; do
        [ -n "$rp" ] || continue
        case "$rp" in
          @loader_path*) rp="$dir${rp#@loader_path}" ;;
          @executable_path*) rp="$(dirname "$SOURCE")${rp#@executable_path}" ;;
        esac
        if [ -e "$rp/${ref#@rpath/}" ]; then cand="$rp/${ref#@rpath/}"; break; fi
      done < <(rpaths_of "$from")
      if [ -z "$cand" ]; then
        for rp in "$dir" /opt/homebrew/lib; do
          [ -e "$rp/${ref#@rpath/}" ] && { cand="$rp/${ref#@rpath/}"; break; }
        done
      fi
      ;;
    *) cand="$ref" ;;
  esac
  [ -n "$cand" ] && [ -e "$cand" ] || error "无法解析 $from 的依赖 $ref"
  # 真实路径（解开 Homebrew 的符号链接，后面要靠它定位 Cellar）
  realpath "$cand"
}

# ---------- 2. 拷贝 aria2c + 递归收集 dylib ----------
BIN_DEST="$HELPERS/aria2c"
cp -f "$SOURCE" "$BIN_DEST"
chmod u+w "$BIN_DEST"
SOURCE_REAL="$(realpath "$SOURCE")"

# 队列：每项 "源真实路径|目标文件"；已处理的 dylib 名字记在 SEEN 里（bash 3.2 没有关联数组）
QUEUE=("$SOURCE_REAL|$BIN_DEST")
SEEN=""
DYLIBS=()
SOURCES=("$SOURCE_REAL")
while [ "${#QUEUE[@]}" -gt 0 ]; do
  item="${QUEUE[0]}"
  QUEUE=("${QUEUE[@]:1}")
  src="${item%%|*}"
  dest="${item#*|}"
  case "$dest" in
    "$MODDIR"/*) loader_prefix="@loader_path/../" ;;
    *) loader_prefix="@loader_path/" ;;
  esac
  while IFS= read -r ref; do
    [ -n "$ref" ] || continue
    is_system "$ref" && continue
    real="$(resolve_ref "$ref" "$src")"
    name="$(basename "$real")"
    [ "$real" = "$src" ] && continue   # dylib 的 ID 行不在 tail 之后，保险起见
    case "$SEEN" in
      *"|$name|"*) ;;
      *)
        SEEN="$SEEN|$name|"
        cp -f "$real" "$LIBDIR/$name"
        chmod u+w "$LIBDIR/$name"
        DYLIBS+=("$name")
        SOURCES+=("$real")
        QUEUE+=("$real|$LIBDIR/$name")
        case "$name" in
          libcrypto.*)
            # OpenSSL 的 provider 模块（legacy.dylib）：aria2 启动时要加载
            mkdir -p "$MODDIR"
            for mod in "$(dirname "$real")"/ossl-modules/*.dylib; do
              [ -f "$mod" ] || continue
              cp -f "$mod" "$MODDIR/$(basename "$mod")"
              chmod u+w "$MODDIR/$(basename "$mod")"
              QUEUE+=("$(realpath "$mod")|$MODDIR/$(basename "$mod")")
            done
            ;;
        esac
        ;;
    esac
    if [ "$dest" = "$BIN_DEST" ]; then
      new_ref="@executable_path/../Frameworks/aria2/$name"
    else
      new_ref="$loader_prefix$name"
    fi
    install_name_tool -change "$ref" "$new_ref" "$dest"
  done < <(deps_of "$src")
  case "$dest" in
    "$MODDIR"/*) install_name_tool -id "@loader_path/$(basename "$dest")" "$dest" ;;
    "$BIN_DEST") ;;
    *) install_name_tool -id "@executable_path/../Frameworks/aria2/$(basename "$dest")" "$dest" ;;
  esac
  # 删掉所有绝对路径的 rpath（指向 /opt/homebrew 的）
  while IFS= read -r rp; do
    case "$rp" in
      /*) install_name_tool -delete_rpath "$rp" "$dest" ;;
    esac
  done < <(rpaths_of "$dest")
done
echo "bundle-aria2: 已收集 ${#DYLIBS[@]} 个 dylib：${DYLIBS[*]}"

# CA 证书包（Homebrew 的 libcrypto 找的是写死的 /opt/homebrew/etc/openssl@4/cert.pem，包外不可用）
CA_SOURCE="${ARIA2_CA_BUNDLE:-}"
if [ -z "$CA_SOURCE" ]; then
  CA_PREFIX="$(brew --prefix ca-certificates 2>/dev/null || true)"
  CA_SOURCE="$CA_PREFIX/share/ca-certificates/cacert.pem"
fi
[ -f "$CA_SOURCE" ] || error "找不到 CA 证书包（${CA_SOURCE}）。请 brew install ca-certificates，或用 ARIA2_CA_BUNDLE 指定 PEM 文件。"
cp -f "$CA_SOURCE" "$RESDIR/cert.pem"
chmod u+w "$RESDIR/cert.pem"
CA_REAL="$(realpath "$CA_SOURCE")"

# 校验：不允许残留非系统的绝对路径或 /opt/homebrew 引用
for f in "$BIN_DEST" "$LIBDIR"/*.dylib "$MODDIR"/*.dylib; do
  [ -f "$f" ] || continue
  while IFS= read -r ref; do
    is_system "$ref" && continue
    case "$ref" in
      @executable_path/../Frameworks/aria2/*|@loader_path/*) ;;
      *) error "$(basename "$f") 仍然引用 $ref" ;;
    esac
  done < <(deps_of "$f")
done

# ---------- 3. 签名 ----------
IDENTITY="${EXPANDED_CODE_SIGN_IDENTITY:-}"
if [ -z "$IDENTITY" ] || [ "$IDENTITY" = "-" ]; then
  ADHOC=1
  IDENTITY="-"
else
  ADHOC=0
fi
for f in "$LIBDIR"/*.dylib "$MODDIR"/*.dylib; do
  [ -f "$f" ] || continue
  if [ "$ADHOC" = 1 ]; then
    codesign --force --sign - "$f"
  else
    codesign --force --sign "$IDENTITY" --timestamp "$f"
  fi
done
if [ "$ADHOC" = 1 ]; then
  # ad-hoc 没有 Team ID，hardened runtime 下加载同包 dylib 需要关闭库验证（仅开发构建）
  codesign --force --sign - --options runtime \
    --entitlements "$SRCROOT/Mulee/Resources/Aria2Helper-adhoc.entitlements" "$BIN_DEST"
else
  codesign --force --sign "$IDENTITY" --options runtime --timestamp "$BIN_DEST"
fi
echo "bundle-aria2: 已签名（$([ "$ADHOC" = 1 ] && echo ad-hoc || echo "$IDENTITY")）"

# ---------- 4. 许可证 ----------
CELLAR_ROOT="$(brew --cellar 2>/dev/null || echo /opt/homebrew/Cellar)"
SEEN_KEGS=""
README="$LICENSES/README.txt"
{
  echo "Mulee bundles the following third-party software (aria2c and the libraries it needs)."
  echo "License texts are in the sub-folder named after each package."
  echo
} > "$README"

for real in "${SOURCES[@]}"; do
  case "$real" in
    "$CELLAR_ROOT"/*)
      rel="${real#"$CELLAR_ROOT"/}"
      pkg="${rel%%/*}"
      rest="${rel#*/}"
      ver="${rest%%/*}"
      keg="$CELLAR_ROOT/$pkg/$ver"
      ;;
    *)
      pkg="$(basename "$real")"; ver="unknown"; keg=""
      warning "${real} 不在 Homebrew Cellar 里，无法收集许可证"
      ;;
  esac
  case "$SEEN_KEGS" in *"|$pkg|"*) continue ;; esac
  SEEN_KEGS="$SEEN_KEGS|$pkg|"
  mkdir -p "$LICENSES/$pkg"
  found=0
  if [ -n "$keg" ]; then
    for cand in "$keg"/COPYING* "$keg"/LICENSE* "$keg"/LICENCE* "$keg"/COPYRIGHT* "$keg"/NOTICE*; do
      [ -f "$cand" ] || continue
      cp -f "$cand" "$LICENSES/$pkg/"
      chmod u+w "$LICENSES/$pkg/$(basename "$cand")"
      found=1
    done
  fi
  [ "$found" = 1 ] || warning "${pkg} ${ver}：Cellar 里没有找到许可证文件（请在 docs/BUILDING.md 核对其许可证条款）"
  license="unknown"; homepage="unknown"; srcurl="unknown"
  if info="$(brew info --json=v2 "$pkg" 2>/dev/null)"; then
    meta="$(printf '%s' "$info" | /usr/bin/python3 -I -c '
import json, sys
f = json.load(sys.stdin)["formulae"][0]
print(f.get("license") or "unknown")
print(f.get("homepage") or "unknown")
print(((f.get("urls") or {}).get("stable") or {}).get("url") or "unknown")
' 2>/dev/null || true)"
    if [ -n "$meta" ]; then
      license="$(printf '%s\n' "$meta" | sed -n 1p)"
      homepage="$(printf '%s\n' "$meta" | sed -n 2p)"
      srcurl="$(printf '%s\n' "$meta" | sed -n 3p)"
    fi
  fi
  [ "$license" != "unknown" ] || warning "${pkg}：brew 没有给出许可证信息"
  {
    echo "$pkg $ver"
    echo "  License:  $license"
    [ "$found" = 1 ] || echo "  (no license file shipped with this package)"
    echo "  Homepage: $homepage"
    echo "  Source:   $srcurl"
    if [ "$pkg" = "aria2" ]; then
      echo "  Note:     aria2 is GPL-2.0-or-later with an additional exception permitting linking with OpenSSL (see LICENSE.OpenSSL)."
    fi
    echo
  } >> "$README"
done

# CA 证书包（Mozilla，MPL-2.0）
CA_VER="$(basename "$(dirname "$(dirname "$(dirname "$CA_REAL")")")")"
mkdir -p "$LICENSES/ca-certificates"
cat > "$LICENSES/ca-certificates/NOTICE.txt" <<NOTICE
Resources/aria2/cert.pem is the Mozilla CA certificate bundle (as extracted by curl, via Homebrew
ca-certificates $CA_VER). It is licensed under the Mozilla Public License, v. 2.0.
License text: https://www.mozilla.org/MPL/2.0/
Source of the data: https://curl.se/docs/caextract.html
(certdata.txt in the Mozilla source tree, security/nss/lib/ckfw/builtins/certdata.txt)
NOTICE
{
  echo "ca-certificates (Mozilla CA bundle) $CA_VER"
  echo "  License:  MPL-2.0 (see ca-certificates/NOTICE.txt)"
  echo "  Homepage: https://curl.se/docs/caextract.html"
  echo "  Source:   https://curl.se/ca/cacert-$CA_VER.pem"
  echo
} >> "$README"
# 增量构建时 Xcode 认为 App 没变，不会重新签名，而本脚本刚刚改过包内文件，App 的封印可能已经失效。
# 失效就用同一个身份重签 App 本身（保留 Xcode 签上的 entitlements / flags）；全量构建时 Xcode 随后会再签一遍。
APP_BUNDLE="$TARGET_BUILD_DIR/${WRAPPER_NAME:-$(dirname "$CONTENTS_FOLDER_PATH")}"
# 只处理 Xcode 已经签过（有资源封印）的 App；全量构建时此刻 App 还没签，Xcode 随后会签。
# 只校验 App 自身的封印（不加 --deep）：跑测试时 PlugIns/ 下的 MuleeTests.xctest 由测试 target 另行签名，
# 递归校验会把它算进来，导致误判并重签失败。
if [ -d "$APP_BUNDLE" ] && codesign -dv "$APP_BUNDLE" 2>&1 | grep -q "Sealed Resources" \
  && ! codesign --verify --strict "$APP_BUNDLE" >/dev/null 2>&1; then
  if [ "$ADHOC" = 1 ]; then
    resign_status=0
    codesign --force --sign - --preserve-metadata=entitlements,flags "$APP_BUNDLE" || resign_status=$?
  else
    resign_status=0
    codesign --force --sign "$IDENTITY" --timestamp --preserve-metadata=entitlements,flags "$APP_BUNDLE" || resign_status=$?
  fi
  if [ "$resign_status" = 0 ]; then
    echo "bundle-aria2: 已重签 ${APP_BUNDLE}（封印已失效）"
  else
    # 不中断构建：Xcode 自己的 CodeSign 步骤会再签一次；发版构建另有 codesign --verify 把关。
    echo "warning: bundle-aria2: 重签 ${APP_BUNDLE} 失败（退出码 ${resign_status}），交给 Xcode 的签名步骤处理"
  fi
fi
echo "bundle-aria2: 完成"
