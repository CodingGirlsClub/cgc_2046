#!/usr/bin/env bash
# 安装包重命名 + 构建元数据：cgc2046-<platform>-<arch>.<ext>（学 pero：版本不写进文件名）。
#
# 为什么文件名不带版本：版本身份由 git tag 承载（desktop-v<base>-dev.<YYYYMMDD>.<n>），
# 同一个 Release 下产物名固定，便于直接给下载链接、重发时 --clobber 覆盖；版本、源码
# commit、签名状态写进同名的 .build.json（消费方可机器读取）。
#
# 版本来源：CI 用 VERSION（tag 去掉 desktop-v 前缀）覆盖；本地回落到 Cargo 包版本。
# commit：CGC_BUILD_COMMIT 覆盖（CI 传完整 SHA），否则取本机 short SHA。
set -euo pipefail
cd "$(dirname "$0")/.."

version="${VERSION:-}"
if [ -z "$version" ]; then
  version=$(cargo metadata --no-deps --format-version 1 2>/dev/null \
    | python3 -c 'import json,sys; print(next(p["version"] for p in json.load(sys.stdin)["packages"] if p["name"]=="cgc-desktop-app"))')
fi
commit="${CGC_BUILD_COMMIT:-$(git rev-parse --short=7 HEAD 2>/dev/null || echo unknown)}"
release_tag="${CGC_RELEASE_TAG:-}"

# 架构段：macOS universal 包由 CI 用 CGC_ARTIFACT_ARCH=universal 指定；
# 其余平台回落到本机架构（打包器只在对应平台跑）。
arch="${CGC_ARTIFACT_ARCH:-$(uname -m)}"
if [ -z "${CGC_ARTIFACT_ARCH:-}" ]; then
  case "$arch" in
    x86_64|amd64) arch=x64 ;;
    arm64|aarch64) arch=aarch64 ;;
  esac
fi

shopt -s nullglob
renamed=0
for f in dist/*; do
  base=$(basename "$f")
  case "$base" in
    *.build.json|*.SHA256SUMS) continue ;;   # 元数据不参与重命名
    *.dmg) ext=dmg; platform=macos ;;
    *.zip) ext=zip; platform=windows ;;
    *.tar.gz) ext=tar.gz; platform=linux ;;
    *) continue ;;
  esac
  target="dist/cgc2046-${platform}-${arch}.${ext}"
  if [ "$f" != "$target" ]; then
    mv -f "$f" "$target"
    echo "renamed: $base -> $(basename "$target")"
    renamed=$((renamed+1))
  fi
  # 构建元数据：与产物同名，消费方读它拿版本与来源 commit。
  meta="dist/cgc2046-${platform}-${arch}.build.json"
  python3 - "$meta" "$version" "$commit" "$release_tag" "$platform" "$arch" <<'PY'
import json, sys
out, version, commit, tag, platform, arch = sys.argv[1:7]
json.dump({
    "schemaVersion": 1,
    "product": "cgc2046",
    "version": version,
    "releaseTag": tag or None,
    "sourceRevision": commit,
    "platform": platform,
    "arch": arch,
    "signing": "unsigned",
    "notarized": False,
}, open(out, "w"), ensure_ascii=False, indent=2)
open(out, "a").write("\n")
PY
  echo "metadata: $(basename "$meta")"
done

if [ "$renamed" -eq 0 ]; then
  echo "no artifact to rename (dist empty or already named)"
else
  echo "artifact name: cgc2046-<platform>-<arch>.<ext>（版本见同名 .build.json）"
fi
