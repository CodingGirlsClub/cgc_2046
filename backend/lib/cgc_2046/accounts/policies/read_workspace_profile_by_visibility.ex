defmodule Cgc2046.Accounts.Policies.ReadWorkspaceProfileByVisibility do
  @moduledoc """
  WorkspaceProfile 读取授权：按 visibility 三档判定「当前 actor 能否读取该
  workspace 档案」（ADR-0004，per-workspace 语义）。

  判定矩阵：
  - 本人：永远可读（`user_id == actor.id`）
  - `:public`：所有登录用户可读
  - `:workspace`：**目标 workspace 成员**可读——actor 在该档案所属 workspace
    有 membership（区别于全局 User 的"任一 workspace"语义）
  - `:only_me`：仅本人可读
  - 匿名（actor nil）：一律不可读（filter 恒假）

  实现说明：FilterCheck 在 filter 阶段**运行时**构造过滤器，用 `exists/2`
  子查询判断 actor 是否为目标 workspace 成员（实测 exists 子查询不叠加
  WorkspaceMembership read policy，见 BypassReads moduledoc）。
  """
  use Ash.Policy.FilterCheck

  @impl true
  def describe(_opts), do: "workspace profile 可读：本人 / public / 目标 workspace 成员 / only_me（匿名不可读）"

  @impl true
  def filter(nil, _context, _opts) do
    # 匿名：恒假 filter（每行 is_nil(id) 为 false → 0 行）
    expr(is_nil(id))
  end

  def filter(actor, _context, _opts) do
    expr(
      user_id == ^actor.id or
        visibility == :public or
        (visibility == :workspace and
           exists(workspace_memberships, user_id == ^actor.id))
    )
  end
end
