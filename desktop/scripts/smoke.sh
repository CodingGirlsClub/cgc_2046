#!/usr/bin/env bash
# 三平台冒烟回归（story 1.12）：可无人值守执行的本地/CI 部分。
#
# 用法：bash scripts/smoke.sh [--quick]
#   --quick  跳过 release 构建（只跑 lint + 测试 + 边界/许可）
#
# 三平台 CI matrix（待 .github 人工合并后接入）：
#   macOS (macos-14, aarch64) / Windows (windows-2022, x64) / Linux (ubuntu-24.04, x64)
#   每平台：rustup 1.98.1 → bash scripts/smoke.sh（Windows 用 Git Bash 或 PowerShell 等价步骤）
# 真机 GUI 项（启动、滚动、对话）不在本脚本内，见 epic-7 验收清单。
set -euo pipefail
cd "$(dirname "$0")/.."

echo "== platform: $(uname -s) $(uname -m) =="
echo "== rust: $(rustc --version) =="
export RUSTUP_TOOLCHAIN="${RUSTUP_TOOLCHAIN:-1.98.1}"

echo "== fmt =="
cargo fmt --all -- --check

echo "== clippy =="
cargo clippy --workspace --all-targets -- -D warnings

echo "== tests =="
cargo test --workspace

echo "== dependency boundaries =="
python3 scripts/check_dependencies.py

echo "== licenses + SBOM =="
python3 scripts/check_licenses.py

if [ "${1:-}" != "--quick" ]; then
  echo "== release build =="
  cargo build --release -p cgc-desktop-app
fi

echo "SMOKE OK: $(uname -s) $(uname -m)"
