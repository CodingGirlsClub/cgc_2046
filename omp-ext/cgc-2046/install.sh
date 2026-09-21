#!/usr/bin/env bash
# omp-ext/cgc-2046 安装脚本
#
# 角色：zip 托管形态的 fallback 安装器（Phase 2 主形态为 plugin/marketplace）。
# 主形态：/marketplace add CodingGirlsClub/cgc-omp-plugins && /marketplace install cgc-2046@cgc-omp-plugins
# 本脚本保留为 zip 托管 fallback（OpenClacky 先例：deploy CI 生成 zip 放静态托管，用户下载解压跑本脚本）。
#
# 子命令：
#   install   安装/升级接入包（拷 agent/skill/extension，merge 写 mcp.json 与 config.yml）
#   remove    卸载接入包（只删本包文件与本条目，保留备份）
#   --dry-run 只打印计划动作，零落盘
#
# 选项：
#   --url <url>   覆盖 MCP server URL（默认生产 https://api.codingirlsclub.com/mcp，dev 可用 http://localhost:4000/mcp）
#
# 安全边界：
#   - token 由 onboarding 流程补入，本脚本不索要、不处理 token
#   - mcp.json 与 config.yml 的 merge 用临时文件 + chmod 600 + 原子替换，保留其他条目与未知字段
#   - 同名已有文件先备份为 *.bak-<时间戳> 再覆盖
#   - install 末尾实测验证守门配置（调一次 confirm 类工具确认弹审批框的指引）
#
# Phase 2 注记：守门配置（config.yml）的写入已改道至 onboarding 收尾步骤（skill 指导下，与 token 写入同场）。
# 本脚本的 config.yml merge 保留为 fallback（zip 形态下无 onboarding skill 指导，仍需脚本写入）。

set -euo pipefail

PACK_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
OMP_AGENT_DIR="${OMP_AGENT_DIR:-$HOME/.omp/agent}"
MCP_JSON="$OMP_AGENT_DIR/mcp.json"
CONFIG_YML="$OMP_AGENT_DIR/config.yml"
MCP_URL="https://api.codingirlsclub.com/mcp"
DRY_RUN=false
ACTION=""

usage() {
  cat <<'EOF'
用法: install.sh <install|remove> [--url <url>] [--dry-run]

子命令:
  install     安装/升级接入包到 ~/.omp/agent/
  remove      从 ~/.omp/agent/ 卸载接入包
  --dry-run   只打印计划动作，零落盘

选项:
  --url <url> 覆盖 MCP server URL（默认生产，dev 用 http://localhost:4000/mcp）

环境变量:
  OMP_AGENT_DIR  覆盖 OMP 用户级目录（默认 ~/.omp/agent，测试用）
EOF
}

log() { echo "[omp-ext/cgc-2046] $*"; }
die() { echo "[omp-ext/cgc-2046] ERROR: $*" >&2; exit 1; }

# 解析参数
while [[ $# -gt 0 ]]; do
  case "$1" in
    install|remove) ACTION="$1"; shift ;;
    --url) MCP_URL="$2"; shift 2 ;;
    --dry-run) DRY_RUN=true; shift ;;
    -h|--help) usage; exit 0 ;;
    *) die "未知参数: $1（见 --help）" ;;
  esac
done

[[ -z "$ACTION" ]] && { usage; exit 1; }

# 备份同名文件
backup_if_exists() {
  local target="$1"
  if [[ -e "$target" ]]; then
    local bak="${target}.bak-$(date +%Y%m%d-%H%M%S)"
    if $DRY_RUN; then
      log "[dry-run] 备份 $target → $bak"
    else
      cp -a "$target" "$bak"
      log "备份 $target → $bak"
    fi
  fi
}

# 拷贝文件（带备份）
install_file() {
  local src="$1" dst="$2"
  [[ ! -f "$src" ]] && die "源文件不存在: $src"
  if $DRY_RUN; then
    log "[dry-run] 安装 $src → $dst"
    return
  fi
  backup_if_exists "$dst"
  mkdir -p "$(dirname "$dst")"
  cp -a "$src" "$dst"
  log "安装 $dst"
}

# merge 写 mcp.json（python3 原子写）
merge_mcp_json() {
  if $DRY_RUN; then
    log "[dry-run] merge 写 $MCP_JSON（cgc-2046 条目，URL: $MCP_URL）"
    return
  fi
  mkdir -p "$OMP_AGENT_DIR"
  MCP_URL="$MCP_URL" MCP_JSON="$MCP_JSON" python3 <<'PYEOF'
import json, os, tempfile

path = os.environ["MCP_JSON"]
url = os.environ["MCP_URL"]

config = {}
if os.path.exists(path):
    with open(path) as f:
        config = json.load(f)

config.setdefault("mcpServers", {})
existing = config["mcpServers"].get("cgc-2046", {})
# 保留已有 headers（含 onboarding 写入的 token），只更新 type/url
config["mcpServers"]["cgc-2046"] = {
    "type": "http",
    "url": url,
    **({"headers": existing["headers"]} if "headers" in existing else {}),
}

fd, tmp = tempfile.mkstemp(dir=os.path.dirname(path), prefix=".mcp.json.", text=True)
try:
    with os.fdopen(fd, "w") as f:
        json.dump(config, f, indent=2, ensure_ascii=False)
    os.chmod(tmp, 0o600)
    os.replace(tmp, path)
except Exception:
    os.unlink(tmp)
    raise

print(f"[omp-ext/cgc-2046] merge 写 {path}（cgc-2046 条目，0600）")
PYEOF
}

# merge 写 config.yml（守门配置）
merge_config_yml() {
  if $DRY_RUN; then
    log "[dry-run] merge 写 $CONFIG_YML（tools.approval.mcp__cgc_2046_confirm_operation: prompt）"
    return
  fi
  mkdir -p "$OMP_AGENT_DIR"
  CONFIG_YML="$CONFIG_YML" python3 <<'PYEOF'
import os, re, tempfile

path = os.environ["CONFIG_YML"]
GUARD_KEY = "mcp__cgc_2046_confirm_operation"
GUARD_LINE = f"    {GUARD_KEY}: prompt"

# 读现有内容
lines = []
if os.path.exists(path):
    with open(path) as f:
        lines = f.readlines()

# 检查是否已有守门配置
content = "".join(lines)
if GUARD_KEY in content:
    print(f"[omp-ext/cgc-2046] {path} 已含守门配置，跳过")
    raise SystemExit(0)

# 找 tools: 节
tools_idx = None
approval_idx = None
for i, line in enumerate(lines):
    if re.match(r"^tools:\s*$", line):
        tools_idx = i
    if tools_idx is not None and re.match(r"^  approval:\s*$", line):
        approval_idx = i
        break

if approval_idx is not None:
    # tools.approval 已存在，插入守门行
    lines.insert(approval_idx + 1, GUARD_LINE + "\n")
elif tools_idx is not None:
    # tools 存在但无 approval，插入 approval 节
    lines.insert(tools_idx + 1, "  approval:\n")
    lines.insert(tools_idx + 2, GUARD_LINE + "\n")
else:
    # 无 tools 节，追加完整块
    if lines and not lines[-1].endswith("\n"):
        lines[-1] += "\n"
    lines.append("\ntools:\n")
    lines.append("  approval:\n")
    lines.append(GUARD_LINE + "\n")

fd, tmp = tempfile.mkstemp(dir=os.path.dirname(path), prefix=".config.yml.", text=True)
try:
    with os.fdopen(fd, "w") as f:
        f.writelines(lines)
    os.chmod(tmp, 0o600)
    os.replace(tmp, path)
except Exception:
    os.unlink(tmp)
    raise

print(f"[omp-ext/cgc-2046] merge 写 {path}（守门配置：{GUARD_KEY}: prompt）")
PYEOF
}

# 实测验证守门配置
verify_guard() {
  if $DRY_RUN; then
    log "[dry-run] 实测验证守门配置（调一次 confirm 类工具确认弹审批框）"
    return
  fi
  log "守门配置已写入。请启动 OMP 后调一次 confirm 类工具（如 confirm_operation）确认弹审批框。"
  log "若未弹框，检查 $CONFIG_YML 是否被 OMP 设置界面重写；恢复方法见 README。"
}

# 卸载
remove_pack() {
  local files=(
    "$OMP_AGENT_DIR/agents/cgc.md"
    "$OMP_AGENT_DIR/skills/cgc2046-onboarding/SKILL.md"
    "$OMP_AGENT_DIR/extensions/cgc-command.ts"
  )
  for f in "${files[@]}"; do
    if [[ -e "$f" ]]; then
      if $DRY_RUN; then
        log "[dry-run] 删除 $f"
      else
        rm "$f"
        log "删除 $f"
      fi
    fi
  done
  # 删 skill 空目录
  if [[ -d "$OMP_AGENT_DIR/skills/cgc2046-onboarding" ]]; then
    if $DRY_RUN; then
      log "[dry-run] 删除空目录 $OMP_AGENT_DIR/skills/cgc2046-onboarding"
    else
      rmdir "$OMP_AGENT_DIR/skills/cgc2046-onboarding" 2>/dev/null || true
    fi
  fi
  # mcp.json 与 config.yml 的条目删除：保留备份，只删本包条目
  if $DRY_RUN; then
    log "[dry-run] 从 $MCP_JSON 删除 cgc-2046 条目，从 $CONFIG_YML 删除守门配置"
  else
    MCP_JSON="$MCP_JSON" python3 <<'PYEOF'
import json, os, tempfile
path = os.environ["MCP_JSON"]
if not os.path.exists(path):
    raise SystemExit(0)
with open(path) as f:
    config = json.load(f)
if "cgc-2046" in config.get("mcpServers", {}):
    del config["mcpServers"]["cgc-2046"]
    fd, tmp = tempfile.mkstemp(dir=os.path.dirname(path), prefix=".mcp.json.", text=True)
    try:
        with os.fdopen(fd, "w") as f:
            json.dump(config, f, indent=2, ensure_ascii=False)
        os.chmod(tmp, 0o600)
        os.replace(tmp, path)
    except Exception:
        os.unlink(tmp)
        raise
    print(f"[omp-ext/cgc-2046] 从 {path} 删除 cgc-2046 条目")
PYEOF
    CONFIG_YML="$CONFIG_YML" python3 <<'PYEOF'
import os, re, tempfile
path = os.environ["CONFIG_YML"]
GUARD_KEY = "mcp__cgc_2046_confirm_operation"
if not os.path.exists(path):
    raise SystemExit(0)
with open(path) as f:
    lines = f.readlines()
new_lines = [l for l in lines if GUARD_KEY not in l]
if len(new_lines) == len(lines):
    raise SystemExit(0)
fd, tmp = tempfile.mkstemp(dir=os.path.dirname(path), prefix=".config.yml.", text=True)
try:
    with os.fdopen(fd, "w") as f:
        f.writelines(new_lines)
    os.chmod(tmp, 0o600)
    os.replace(tmp, path)
except Exception:
    os.unlink(tmp)
    raise
print(f"[omp-ext/cgc-2046] 从 {path} 删除守门配置")
PYEOF
  fi
  log "卸载完成。备份文件（*.bak-*）保留在原位，可手动清理。"
}

# 主流程
case "$ACTION" in
  install)
    log "安装接入包到 $OMP_AGENT_DIR（MCP URL: $MCP_URL）"
    install_file "$PACK_DIR/agents/cgc.md" "$OMP_AGENT_DIR/agents/cgc.md"
    install_file "$PACK_DIR/skills/cgc2046-onboarding/SKILL.md" "$OMP_AGENT_DIR/skills/cgc2046-onboarding/SKILL.md"
    install_file "$PACK_DIR/extensions/cgc-command.ts" "$OMP_AGENT_DIR/extensions/cgc-command.ts"
    merge_mcp_json
    merge_config_yml
    verify_guard
    log "安装完成。启动 OMP 后输入 /cgc 查看状态，或对 agent 说「连接 CGC」开始 onboarding。"
    ;;
  remove)
    log "卸载接入包（保留备份）"
    remove_pack
    ;;
esac
