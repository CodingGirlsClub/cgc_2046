#!/usr/bin/env bash
# docs-only.sh 的断言（CI changes job 每次先跑它，失败则 changes 变红、
# docs_only 为空、下游全量跑——既可见又 fail-closed）。
set -u
cd "$(dirname "$0")" || exit 1
fail=0
check() { # check <期望> <描述> <stdin 内容>
  local got
  got=$(printf '%s' "$3" | bash ./docs-only.sh)
  if [ "$got" = "docs_only=$1" ]; then echo "ok   $2"; else echo "FAIL $2: got $got, want docs_only=$1"; fail=1; fi
}
check true  "纯文档（docs 嵌套 + 根 md）"       $'docs/a/b.md\nCHANGELOG.md\ndocs/img/x.png\n'
check false "文档 + 代码"                      $'docs/a.md\nbackend/lib/x.ex\n'
check false "含 .github/**"                    $'docs/a.md\n.github/workflows/ci.yml\n'
check false "空列表"                           ''
check false "仅空行（API 失败的输出）"          $'\n\n'
check false "子目录 md 不是根 md"               $'web/README.md\n'
check false "rename：旧路径在代码目录"          $'docs/moved.md\nbackend/old.md\n'
check false "根目录非 md 文件"                  $'package.json\n'
check false "根目录 md 之外混入代码"            $'README.md\nscripts/x.sh\n'
exit $fail
