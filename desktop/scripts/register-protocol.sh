#!/usr/bin/env bash
# 便携包的用户级 cgc:// 协议注册（Linux）。解压后运行一次即可，不需要 root。
#
# 为什么要单独一步：`desktop/crates/app/Cargo.toml` 把协议注册交给安装器
# （[[package.metadata.packager.deepLinkProtocols]]），而 tar.gz 便携包不经过
# 安装器——不注册的话，从网页点 cgc:// 深链系统不知道该用哪个程序打开。
# 这里只写用户目录（~/.local/share/applications + xdg-mime default），不影响系统级配置。
set -euo pipefail
self_dir=$(cd "$(dirname "$0")" && pwd)
# 包内布局：脚本在 usr/bin/，desktop entry 在 usr/share/applications/，可执行文件在 usr/bin/。
# 因此要从**包根**（usr/bin 的上两级）找 entry，而不是从脚本所在目录向下找。
pkg_root=$(cd "$self_dir/../.." && pwd)
if [ ! -d "$pkg_root/usr/share/applications" ]; then
  pkg_root="$self_dir"   # 兜底：脚本被放在包根时仍可用
fi

desktop_entry=$(find "$pkg_root/usr/share/applications" -maxdepth 1 -type f -name "*.desktop" 2>/dev/null | head -1)
[ -n "$desktop_entry" ] || {
  echo "FAIL: 在 $pkg_root/usr/share/applications 找不到 .desktop 文件" >&2
  exit 1
}

exe=$(find "$pkg_root" -maxdepth 3 -type f -name "cgc-desktop-app" -perm -u+x | head -1)
[ -n "$exe" ] || {
  echo "FAIL: 找不到 cgc-desktop-app 可执行文件" >&2
  exit 1
}

target_dir="${XDG_DATA_HOME:-$HOME/.local/share}/applications"
mkdir -p "$target_dir"
name=$(basename "$desktop_entry")
# 把 Desktop Entry 的 Exec 指向本次解压的实际路径（便携包位置可变）。
sed -E "s|^Exec=.*|Exec=\"$exe\" %u|" "$desktop_entry" > "$target_dir/$name"
chmod 644 "$target_dir/$name"
echo "installed desktop entry: $target_dir/$name"

if command -v update-desktop-database >/dev/null 2>&1; then
  update-desktop-database "$target_dir" >/dev/null 2>&1 || true
fi
if command -v xdg-mime >/dev/null 2>&1; then
  xdg-mime default "$name" x-scheme-handler/cgc
  echo "registered: xdg-mime default $name x-scheme-handler/cgc"
else
  echo "WARN: 没有 xdg-mime，cgc:// 可能仍需手动指定打开方式" >&2
fi

echo "done. 现在从网页点击 cgc:// 链接应由 $(basename "$exe") 接管。"
echo "撤销：rm '$target_dir/$name' && xdg-mime default '' x-scheme-handler/cgc"
