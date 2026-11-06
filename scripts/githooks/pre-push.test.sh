#!/usr/bin/env bash
# scripts/githooks/pre-push 的断言：失败分类必须看输出内容，不能看退出码
# （依赖解析失败与格式 diff 都是 exit 1，#1241）。
# 用 PATH 前置的假 mix 驱动，不需要 Elixir；每个场景在临时 git 仓库里跑。
set -u
HOOK="$(cd "$(dirname "$0")" && pwd)/pre-push"
tmp_root="$(mktemp -d)"
trap 'rm -rf "$tmp_root"' EXIT
fail=0

# setup_repo <name> <deps: yes|no> <backend: yes|no>
setup_repo() {
  local dir="$tmp_root/$1"
  mkdir -p "$dir/backend" "$dir/bin"
  git -C "$dir" init -q
  [ "$3" = yes ] && printf 'defmodule Probe.MixProject do\nend\n' > "$dir/backend/mix.exs"
  [ "$2" = yes ] && mkdir -p "$dir/backend/deps"
  cat > "$dir/bin/mix" <<'MIX'
#!/usr/bin/env bash
printf 'mix %s\n' "$*" >> "$MIX_CALL_LOG"
case "$FAKE_MIX_MODE" in
  ok) exit 0 ;;
  format)
    # 真实 Mix.raise 与 diff 都写 stderr；stdout 为空。写 stdout 会让测试
    # 对 hook 漏掉 `2>&1` 的改动变盲。
    echo "** (Mix) mix format failed due to --check-formatted." >&2
    echo "The following files are not formatted:" >&2
    exit 1 ;;
  format-big)
    # 输出超过管道缓冲：grep -q 提前退出会让上游 printf 收到 SIGPIPE，
    # pipefail 下整条 pipeline 返回 141——分类不能依赖 pipeline 退出码。
    echo "** (Mix) mix format failed due to --check-formatted." >&2
    i=0; while [ "$i" -lt 3000 ]; do echo "lib/file_$i.ex is not formatted" >&2; i=$((i + 1)); done
    exit 1 ;;
  deps)
    echo '** (Mix) Unknown dependency :ecto_sql given to :import_deps in the formatter configuration. Make sure the dependency is listed in your mix.exs for environment :dev and you have run "mix deps.get"' >&2
    exit 1 ;;
esac
MIX
  chmod +x "$dir/bin/mix"
  printf '%s\n' "$dir"
}

# run_hook <dir> <fake mix mode> → $out / $status
run_hook() {
  local dir="$1"
  out=$(cd "$dir" && PATH="$dir/bin:$PATH" MIX_CALL_LOG="$dir/mix-calls.log" \
    FAKE_MIX_MODE="$2" bash "$HOOK" 2>&1)
  status=$?
}

check() { # check <描述> <want_status> <want_text> <forbidden_text>
  local ok=1
  [ "$status" -eq "$2" ] || ok=0
  case "$out" in *"$3"*) ;; *) ok=0 ;; esac
  if [ -n "$4" ]; then case "$out" in *"$4"*) ok=0 ;; esac; fi
  if [ "$ok" -eq 1 ]; then
    echo "ok   $1"
  else
    local shown="${out:0:300}"
    [ "${#out}" -gt 300 ] && shown="$shown…（共 ${#out} 字符）"
    echo "FAIL $1: exit=$status want=$2"
    printf '     output: %s\n' "${shown//$'\n'/ | }"
    fail=1
  fi
}

# 1. 非 backend 仓库：直接放行，不调用 mix。
dir="$(setup_repo no-backend no no)"
run_hook "$dir" ok
check "无 backend/mix.exs：放行" 0 "" "pre-push"
[ -f "$dir/mix-calls.log" ] && { echo "FAIL 无 backend 时不应调用 mix"; fail=1; } || echo "ok   无 backend 时未调用 mix"

# 2. 新 worktree（无 backend/deps）：放行并指向 setup 脚本，不调用 mix。
dir="$(setup_repo no-deps no yes)"
run_hook "$dir" ok
check "无 backend/deps：放行并提示 setup-worktree.sh" 0 "setup-worktree.sh" "格式检查未通过"
[ -f "$dir/mix-calls.log" ] && { echo "FAIL 无 deps 时不应调用 mix"; fail=1; } || echo "ok   无 deps 时未调用 mix"

# 3. deps 就绪且格式干净：放行。
dir="$(setup_repo clean yes yes)"
run_hook "$dir" ok
check "格式干净：放行" 0 "format ok" "跳过"

# 4. 真格式失败：拦截并提示 mix format。
dir="$(setup_repo bad-format yes yes)"
run_hook "$dir" format
check "格式失败：拦截" 1 "格式检查未通过" "跳过"

# 5. 依赖解析失败（同样 exit 1）：放行，提示 deps.get，不得说成格式失败。
#    合成故障：实测空 backend/deps 目录时真实 mix 直接 exit 0，只有目录整体
#    缺失才报 Unknown dependency（已由快路径覆盖）；这里模拟 deps 目录存在
#    但依赖 mix.exs 不全的中间态，作为分类分支的兜底覆盖。
dir="$(setup_repo broken-deps yes yes)"
run_hook "$dir" deps
check "依赖缺失：放行并提示 deps.get" 0 "deps.get" "格式检查未通过"

# 6. 大量未格式化文件（输出超出管道缓冲）：仍必须拦截。
dir="$(setup_repo many-diffs yes yes)"
run_hook "$dir" format-big
check "大输出格式失败：仍拦截" 1 "格式检查未通过" "跳过"

exit $fail
