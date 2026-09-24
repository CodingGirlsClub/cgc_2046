#!/usr/bin/env bash
# 守门配置写入的沙盒三变体测试（Phase 2 守门链复验）
#
# 覆盖 onboarding skill 第 4 步的守门写入命令：
#   变体 1：空 config.yml（全新写入）
#   变体 2：已有 tools.approval（merge 插入）
#   变体 3：已含 GUARD_KEY（幂等跳过）
#
# 运行：bash omp-plugin/cgc-2046/guard-config.test.sh
# 退出码：0 = 全绿，非 0 = 有断言失败

set -euo pipefail

TEST_HOME=$(mktemp -d)
trap 'rm -rf "$TEST_HOME"' EXIT

export HOME="$TEST_HOME"
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

assert_file_contains() { assert "$1" "grep -q '$3' '$2'"; }
assert_file_not_contains() { assert "$1" "! grep -q '$3' '$2' 2>/dev/null"; }
assert_file_mode() { assert "$1" "[[ \$(stat -f '%Lp' '$2' 2>/dev/null || stat -c '%a' '$2' 2>/dev/null) == '$3' ]]"; }

# 守门写入命令（从 SKILL.md 第 4 步抽取）
write_guard() {
python3 -c '
import os, re, tempfile

path = os.path.expanduser("~/.omp/agent/config.yml")
GUARD_KEY = "mcp__cgc_2046_confirm_operation"
GUARD_LINE = f"    {GUARD_KEY}: prompt"

lines = []
if os.path.exists(path):
    with open(path) as f:
        lines = f.readlines()

content = "".join(lines)
if GUARD_KEY in content:
    print("OK: guard config already present")
    raise SystemExit(0)

tools_idx = None
approval_idx = None
for i, line in enumerate(lines):
    if re.match(r"^tools:\s*$", line):
        tools_idx = i
    if tools_idx is not None and re.match(r"^  approval:\s*$", line):
        approval_idx = i
        break

if approval_idx is not None:
    lines.insert(approval_idx + 1, GUARD_LINE + "\n")
elif tools_idx is not None:
    lines.insert(tools_idx + 1, "  approval:\n")
    lines.insert(tools_idx + 2, GUARD_LINE + "\n")
else:
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

print("OK: guard config written")
'
}

echo "== 变体 1: 空 config.yml（全新写入） =="
mkdir -p "$TEST_HOME/.omp/agent"
write_guard >/dev/null
assert_file_contains "守门配置写入" "$TEST_HOME/.omp/agent/config.yml" 'mcp__cgc_2046_confirm_operation: prompt'
assert_file_mode "权限 600" "$TEST_HOME/.omp/agent/config.yml" "600"

echo "== 变体 2: 已有 tools.approval（merge 插入） =="
cat > "$TEST_HOME/.omp/agent/config.yml" <<'EOF'
tools:
  approval:
    bash: prompt
otherSetting: true
EOF
write_guard >/dev/null
assert_file_contains "守门配置插入" "$TEST_HOME/.omp/agent/config.yml" 'mcp__cgc_2046_confirm_operation: prompt'
assert_file_contains "已有策略保留" "$TEST_HOME/.omp/agent/config.yml" 'bash: prompt'
assert_file_contains "其他设置保留" "$TEST_HOME/.omp/agent/config.yml" 'otherSetting: true'

echo "== 变体 3: 已含 GUARD_KEY（幂等跳过） =="
write_guard >/dev/null
assert "幂等跳过（无重复）" "[[ \$(grep -c 'mcp__cgc_2046_confirm_operation' '$TEST_HOME/.omp/agent/config.yml') == 1 ]]"

echo ""
echo "== 结果: $PASS 通过, $FAIL 失败 =="
[[ $FAIL -eq 0 ]] && exit 0 || exit 1
