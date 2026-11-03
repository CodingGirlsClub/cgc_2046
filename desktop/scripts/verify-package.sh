#!/usr/bin/env bash
# 校验 cargo-packager 产物「结构上可安装」。CI 与本地共用。
# 未签名产物是预期状态（证书暂无，签名/公证归 epic-6）：这里记录真实签名状态，不因未签名失败。
set -euo pipefail
cd "$(dirname "$0")/.."

found=0
shopt -s nullglob

# 端点断言（fail-closed）：安装包必须指向官方域。Bearer token、登录密码、下单请求
# 与 MCP lease token 都走这条通道，端点错了轻则内测包不可用，重则把凭据发给站外主机。
# 官方域是 codingirlsclub.com；codinggirlsclub.com 不是我们的服务域（曾拼错一次）。
BIN="target/release/cgc-desktop-app"
if [ -f "$BIN" ]; then
  grep -aq "https://api.codingirlsclub.com/api/graphql" "$BIN" || {
    echo "FAIL: 二进制缺官方端点（期望打包时注入 CGC_DEFAULT_API_URL=https://api.codingirlsclub.com/api/graphql）" >&2
    exit 1
  }
  if grep -aq "codinggirlsclub.com/api" "$BIN"; then
    echo "FAIL: 二进制含错拼域 codinggirlsclub.com（官方域是 codingirlsclub.com）" >&2
    exit 1
  fi
  echo "endpoint assertion ok: $BIN"
fi

for f in dist/*.dmg; do
  echo "== dmg: $f"
  base=$(basename "$f")
  if ! [[ "$base" =~ ^cgc2046-macos-[a-z0-9]+\.dmg$ ]]; then
    echo "FAIL: 产物名不符合 cgc2046-macos-<arch>.dmg（实际 $base）；版本应写在同名 .build.json" >&2
    exit 1
  fi
  echo "   name ok: $base"
  hdiutil verify "$f" >/dev/null
  echo "   hdiutil verify ok"

  if codesign -dv "$f" >/dev/null 2>&1; then
    echo "   signature: signed"
  else
    echo "   signature: unsigned（预期，epic-6 接管签名）"
  fi

  mnt=$(mktemp -d "${TMPDIR:-/tmp}/cgc-dmg.XXXXXX")
  hdiutil attach -nobrowse -readonly -mountpoint "$mnt" "$f" >/dev/null
  app=$(ls -d "$mnt"/*.app 2>/dev/null | head -1)
  test -n "$app" || { hdiutil detach "$mnt" -force >/dev/null 2>&1 || true; echo "FAIL: dmg 内没有 .app" >&2; exit 1; }
  echo "   app bundle ok: $(basename "$app")"
  test -e "$mnt/Applications" || { hdiutil detach "$mnt" -force >/dev/null 2>&1 || true; echo "FAIL: dmg 内缺 Applications 链接" >&2; exit 1; }
  echo "   Applications link ok"
  # universal 包必须真的同时含 arm64 与 x86_64——lipo 静默产出单架构时，
  # 表面上「包能打出来」，实际 Intel 用户装不上。
  if [ "${CGC_ARTIFACT_ARCH:-}" = "universal" ]; then
    bin=$(ls "$app/Contents/MacOS"/* 2>/dev/null | head -1)
    archs=$(lipo -archs "$bin" 2>/dev/null || true)
    case "$archs" in
      *arm64*x86_64*|*x86_64*arm64*) echo "   universal ok: $archs" ;;
      *)
        hdiutil detach "$mnt" -force >/dev/null 2>&1 || true
        echo "FAIL: dmg 内二进制不是 universal（lipo -archs: ${archs:-<unknown>}）" >&2
        exit 1
        ;;
    esac
  fi
  if ! plutil -p "$app/Contents/Info.plist" | grep -q '"cgc"'; then
    hdiutil detach "$mnt" -force >/dev/null || true
    echo "FAIL: app Info.plist 缺少 cgc URL scheme" >&2
    exit 1
  fi
  echo "   cgc URL scheme ok"
  hdiutil detach "$mnt" -force >/dev/null
  rmdir "$mnt" 2>/dev/null || true
  found=1
done

for f in dist/*.tar.gz; do
  echo "== tar.gz: $f"
  base=$(basename "$f")
  if ! [[ "$base" =~ ^cgc2046-linux-[a-z0-9]+\.tar\.gz$ ]]; then
    echo "FAIL: 产物名不符合 cgc2046-linux-<arch>.tar.gz（实际 $base）" >&2
    exit 1
  fi
  echo "   name ok: $base"
  tmp=$(mktemp -d "${TMPDIR:-/tmp}/cgc-tar.XXXXXX")
  tar -xzf "$f" -C "$tmp"
  bin=$(find "$tmp" -type f -name "cgc-desktop-app" -perm -u+x | head -1)
  if [ -z "$bin" ]; then
    rm -rf "$tmp"
    echo "FAIL: tar.gz 内找不到可执行的 cgc-desktop-app" >&2
    exit 1
  fi
  echo "   binary ok: ${bin#"$tmp"/}"
  # 只认实际会被桌面环境读取的 .desktop 文件：随包的 register-protocol.sh 本身也含
  # `x-scheme-handler/cgc` 字面量，全目录 grep 会让缺 entry 的包蒙混过关。
  entry=$(find "$tmp/usr/share/applications" -maxdepth 1 -type f -name "*.desktop" 2>/dev/null | head -1)
  if [ -z "$entry" ] || ! grep -q 'x-scheme-handler/cgc' "$entry"; then
    rm -rf "$tmp"
    echo "FAIL: tar.gz 缺声明 x-scheme-handler/cgc 的 desktop entry（usr/share/applications/*.desktop）" >&2
    exit 1
  fi
  echo "   cgc URL scheme ok"
  rm -rf "$tmp"
  found=1
done

# 每个产物都必须有同名 .build.json：版本不在文件名里，元数据是唯一读取来源。
for f in dist/*.dmg dist/*.tar.gz dist/*.zip; do
  [ -e "$f" ] || continue
  case "$f" in
    *.tar.gz) meta="${f%.tar.gz}.build.json" ;;
    *) meta="${f%.*}.build.json" ;;
  esac
  if [ ! -f "$meta" ]; then
    echo "FAIL: 缺构建元数据 $meta（版本/commit 只能从这里读）" >&2
    exit 1
  fi
  python3 - "$meta" <<'PYMETA'
import json, os, sys
path = sys.argv[1]
meta = json.load(open(path))
for key in ("version", "sourceRevision", "platform", "arch"):
    if not meta.get(key):
        sys.exit(f"FAIL: {path} 缺 {key}")
want_version = os.environ.get("VERSION", "").replace("desktop-v", "")
if want_version and meta["version"] != want_version:
    sys.exit(f"FAIL: build.json version={meta['version']} 与预期 {want_version} 不一致")
want_commit = os.environ.get("CGC_BUILD_COMMIT", "")
if want_commit and meta["sourceRevision"] != want_commit:
    sys.exit("FAIL: build.json sourceRevision 与 CI commit 不一致")
PYMETA
  echo "   metadata ok: $(basename "$meta")"
done

if [ "$found" -eq 0 ]; then
  echo "FAIL: desktop/dist 下没有任何已知安装包产物" >&2
  exit 1
fi

echo "package verification passed"
