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
  if ! [[ "$base" =~ ^cgc2046_[0-9]+\.[0-9]+\.[0-9]+_[0-9a-f]{7,}_[a-z0-9]+\.dmg$ ]]; then
    echo "FAIL: 产物名缺版本/commit（期望 cgc2046_<version>_<commit>_<arch>.dmg，实际 $base）" >&2
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

for f in dist/*.deb; do
  echo "== deb: $f"
  if command -v dpkg-deb >/dev/null 2>&1; then
    dpkg-deb -c "$f" >/dev/null
    echo "   dpkg-deb -c ok"
    if ! depends=$(dpkg-deb -f "$f" Depends 2>/tmp/cgc-deb-field.err); then
      # control 本身不合法（如 package 名非 ASCII）时 dpkg-deb -f 会直接报错，
      # 这里把原始错误打出来，避免只剩一句「Depends: <empty>」。
      echo "FAIL: deb control 无法被 dpkg 解析：" >&2
      cat /tmp/cgc-deb-field.err >&2 || true
      dpkg-deb -I "$f" >&2 2>/dev/null || true
      exit 1
    fi
    case "$depends" in
      *libsecret-tools*) echo "   dependency ok: libsecret-tools" ;;
      *)
        echo "FAIL: deb 缺少 libsecret-tools 运行时依赖（实际 Depends: ${depends:-<empty>}）" >&2
        dpkg-deb -I "$f" >&2 2>/dev/null || true
        exit 1
        ;;
    esac
    tmp=$(mktemp -d "${TMPDIR:-/tmp}/cgc-deb.XXXXXX")
    dpkg-deb -x "$f" "$tmp"
    if ! grep -R -q 'x-scheme-handler/cgc' "$tmp/usr/share/applications" 2>/dev/null; then
      rm -rf "$tmp"
      echo "FAIL: deb desktop entry 缺少 x-scheme-handler/cgc" >&2
      exit 1
    fi
    rm -rf "$tmp"
    echo "   cgc URL scheme ok"
  else
    echo "   dpkg-deb 不可用（非 Debian 系宿主），跳过结构校验"
  fi
  found=1
done

for f in dist/*.AppImage; do
  echo "== AppImage: $f"
  rm -rf squashfs-root
  "$f" --appimage-extract >/dev/null
  test -x squashfs-root/AppRun
  echo "   --appimage-extract ok"
  if ! grep -R -q 'x-scheme-handler/cgc' squashfs-root/usr/share/applications 2>/dev/null; then
    rm -rf squashfs-root
    echo "FAIL: AppImage desktop entry 缺少 x-scheme-handler/cgc" >&2
    exit 1
  fi
  echo "   cgc URL scheme ok"
  rm -rf squashfs-root
  found=1
done

if [ "$found" -eq 0 ]; then
  echo "FAIL: desktop/dist 下没有任何已知安装包产物" >&2
  exit 1
fi

echo "package verification passed"
