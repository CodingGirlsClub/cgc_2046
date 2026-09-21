#!/usr/bin/env bash
# omp-plugin/cgc-2046 安装脚本测试
#
# 覆盖 plan U4 的六个测试场景：
#   1. 干净环境 install：agent/skill/extension 落位，mcp.json 生成且权限 600，config.yml 含守门配置
#   2. 重复 install：幂等，无重复条目，已有同名文件产生新备份
#   3. 已含其他 MCP server 的 mcp.json 与已含其他工具策略的 config.yml：merge 后其他条目与未知字段保留
#   4. remove：本包文件与本条目消失，其他 server 与用户自建 agents/skills/工具策略不受影响
#   5. --dry-run：仅打印计划，零落盘
#   6. install 后实测验证：守门配置写入 config.yml（调一次 confirm 类工具确认弹审批框的指引输出）
#
# 运行：bash omp-plugin/cgc-2046/install.test.sh
# 退出码：0 = 全绿，非 0 = 有断言失败

set -euo pipefail

PACK_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TEST_HOME=$(mktemp -d)
trap 'rm -rf "$TEST_HOME"' EXIT

export OMP_AGENT_DIR="$TEST_HOME/.omp/agent"
PASS=0
FAIL=0

assert() {
  local desc="$1" cmd="$2"
  if eval "$cmd"; then
    echo "  ✓ $desc"
    PASS=$((PASS + 1))
  else
    echo "  ✗ $desc"
    FAIL=$((FAIL + 1))
  fi
}

assert_file_exists() { assert "$1" "[[ -f '$2' ]]"; }
assert_file_not_exists() { assert "$1" "[[ ! -e '$2' ]]"; }
assert_file_contains() { assert "$1" "grep -q '$3' '$2'"; }
assert_file_not_contains() { assert "$1" "! grep -q '$3' '$2' 2>/dev/null"; }
assert_file_mode() { assert "$1" "[[ \$(stat -f '%Lp' '$2' 2>/dev/null || stat -c '%a' '$2' 2>/dev/null) == '$3' ]]"; }

echo "== 场景 1: 干净环境 install =="
bash "$PACK_DIR/install.sh" install >/dev/null
assert_file_exists "agent 落位" "$OMP_AGENT_DIR/agents/cgc.md"
assert_file_exists "skill 落位" "$OMP_AGENT_DIR/skills/cgc2046-onboarding/SKILL.md"
assert_file_exists "extension 落位" "$OMP_AGENT_DIR/extensions/cgc-command.ts"
assert_file_exists "mcp.json 生成" "$OMP_AGENT_DIR/mcp.json"
assert_file_mode "mcp.json 权限 600" "$OMP_AGENT_DIR/mcp.json" "600"
assert_file_contains "mcp.json 含 cgc-2046 条目" "$OMP_AGENT_DIR/mcp.json" '"cgc-2046"'
assert_file_contains "mcp.json 含生产 URL" "$OMP_AGENT_DIR/mcp.json" 'api.codingirlsclub.com/mcp'
assert_file_exists "config.yml 生成" "$OMP_AGENT_DIR/config.yml"
assert_file_contains "config.yml 含守门配置" "$OMP_AGENT_DIR/config.yml" 'mcp__cgc_2046_confirm_operation: prompt'

echo "== 场景 2: 重复 install（幂等 + 备份 + token 保留） =="
echo "modified" > "$OMP_AGENT_DIR/agents/cgc.md"
# 模拟 onboarding 已写入 token
python3 -c '
import json, os
path = os.environ["OMP_AGENT_DIR"] + "/mcp.json"
with open(path) as f:
    config = json.load(f)
config["mcpServers"]["cgc-2046"]["headers"] = {"Authorization": "Bearer test-token-123"}
with open(path, "w") as f:
    json.dump(config, f, indent=2)
'
bash "$PACK_DIR/install.sh" install >/dev/null
assert_file_contains "agent 被覆盖为新版本" "$OMP_AGENT_DIR/agents/cgc.md" 'CGC-2046 平台助手'
assert "备份文件产生" "ls '$OMP_AGENT_DIR/agents/cgc.md.bak-'* >/dev/null 2>&1"
assert "mcp.json 无重复条目" "[[ \$(grep -c '\"cgc-2046\"' '$OMP_AGENT_DIR/mcp.json') == 1 ]]"
assert "config.yml 无重复守门配置" "[[ \$(grep -c 'mcp__cgc_2046_confirm_operation' '$OMP_AGENT_DIR/config.yml') == 1 ]]"
assert_file_contains "重复 install 保留 token" "$OMP_AGENT_DIR/mcp.json" 'test-token-123'

echo "== 场景 3: 已有其他 server/策略的 merge 保留 =="
cat > "$OMP_AGENT_DIR/mcp.json" <<'EOF'
{
  "mcpServers": {
    "other-server": {"type": "http", "url": "https://other.example.com/mcp"}
  },
  "customField": "preserved"
}
EOF
cat > "$OMP_AGENT_DIR/config.yml" <<'EOF'
tools:
  approval:
    bash: prompt
otherSetting: true
EOF
bash "$PACK_DIR/install.sh" install >/dev/null
assert_file_contains "其他 server 保留" "$OMP_AGENT_DIR/mcp.json" '"other-server"'
assert_file_contains "未知字段保留" "$OMP_AGENT_DIR/mcp.json" '"customField"'
assert_file_contains "cgc-2046 条目加入" "$OMP_AGENT_DIR/mcp.json" '"cgc-2046"'
assert_file_contains "其他工具策略保留" "$OMP_AGENT_DIR/config.yml" 'bash: prompt'
assert_file_contains "其他设置保留" "$OMP_AGENT_DIR/config.yml" 'otherSetting: true'
assert_file_contains "守门配置加入" "$OMP_AGENT_DIR/config.yml" 'mcp__cgc_2046_confirm_operation: prompt'

echo "== 场景 4: remove（只删本包，保留其他） =="
bash "$PACK_DIR/install.sh" remove >/dev/null
assert_file_not_exists "agent 删除" "$OMP_AGENT_DIR/agents/cgc.md"
assert_file_not_exists "skill 删除" "$OMP_AGENT_DIR/skills/cgc2046-onboarding/SKILL.md"
assert_file_not_exists "extension 删除" "$OMP_AGENT_DIR/extensions/cgc-command.ts"
assert_file_not_contains "mcp.json 无 cgc-2046" "$OMP_AGENT_DIR/mcp.json" '"cgc-2046"'
assert_file_contains "mcp.json 其他 server 保留" "$OMP_AGENT_DIR/mcp.json" '"other-server"'
assert_file_not_contains "config.yml 无守门配置" "$OMP_AGENT_DIR/config.yml" 'mcp__cgc_2046_confirm_operation'
assert_file_contains "config.yml 其他策略保留" "$OMP_AGENT_DIR/config.yml" 'bash: prompt'
assert "备份文件保留" "ls '$OMP_AGENT_DIR/agents/cgc.md.bak-'* >/dev/null 2>&1"

echo "== 场景 5: --dry-run（零落盘） =="
rm -rf "$TEST_HOME"
mkdir -p "$TEST_HOME"
export OMP_AGENT_DIR="$TEST_HOME/.omp/agent"
bash "$PACK_DIR/install.sh" install --dry-run >/dev/null
assert_file_not_exists "dry-run 无 agent 落盘" "$OMP_AGENT_DIR/agents/cgc.md"
assert_file_not_exists "dry-run 无 mcp.json" "$OMP_AGENT_DIR/mcp.json"
assert_file_not_exists "dry-run 无 config.yml" "$OMP_AGENT_DIR/config.yml"

echo "== 场景 6: install 后实测验证指引 =="
OUTPUT=$(bash "$PACK_DIR/install.sh" install 2>&1)
assert "输出含守门验证指引" "echo '$OUTPUT' | grep -q 'confirm 类工具.*确认弹审批框'"

echo ""
echo "== 结果: $PASS 通过, $FAIL 失败 =="
[[ $FAIL -eq 0 ]] && exit 0 || exit 1
