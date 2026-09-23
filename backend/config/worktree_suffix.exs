# worktree 并行隔离的库名后缀，dev.exs / test.exs 经 Code.eval_file 共用。
# 在附属 git worktree 里运行时返回 "_<slug>"（slug 取当前分支，detached HEAD 取
# worktree 目录名），同机多个 worktree 各用各的库；主 checkout、CI 的普通 checkout、
# 非 git 目录或没有 git 时返回 ""，即共享库名。slug 规则与既有按分支命名的库一致。
git = fn args -> System.cmd("git", args, stderr_to_stdout: true) end

try do
  {out, 0} =
    git.([
      "rev-parse",
      "--path-format=absolute",
      "--git-dir",
      "--git-common-dir",
      "--show-toplevel"
    ])

  [git_dir, common_dir, toplevel] = String.split(out, "\n", trim: true)

  if git_dir == common_dir do
    ""
  else
    {branch, 0} = git.(["branch", "--show-current"])

    name =
      case String.trim(branch) do
        "" -> Path.basename(toplevel)
        branch -> branch
      end

    "_" <>
      (name |> String.downcase() |> String.replace(~r/[^a-z0-9]+/, "_") |> String.slice(0, 45))
  end
rescue
  _ -> ""
end
