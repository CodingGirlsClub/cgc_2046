defmodule Cgc2046.Policies.ReadUserByVisibility do
  @moduledoc """
  User read 授权：按 visibility 三档判定「当前 actor 能否读取该用户资料」（2026-08-02 改造）。

  判定矩阵：
  - 本人：永远可读（`id == actor.id`）
  - `:public`：所有登录用户可读
  - `:workspace`：actor 与 owner 同属任一工作区（共同 membership）可读
  - `:only_me`：仅本人可读
  - 匿名（actor nil）：一律不可读（filter 恒假）

  实现说明：使用 `Ash.Policy.FilterCheck` 在 filter 阶段**运行时**构造过滤器——
  actor 的 workspace_id 集合经 BypassReads.shared_workspace_ids/1 取得（旁路
  读取面，唯一允许原始 SQL 的出口），再注入 `exists(workspace_memberships,
  workspace_id in ^actor_ws_ids)` 子查询。

  为什么子查询可行：实测 `exists/2` 表达式生成的 SQL 子查询**不会**叠加
  WorkspaceMembership 的 read policy（与 aggregate count 相反，后者会叠加并
  被过滤，见 BypassReads moduledoc）。SQL 直接 `SELECT 1 FROM
  workspace_memberships WHERE workspace_id = ANY($n) AND users.id = user_id`。
  """

  use Ash.Policy.FilterCheck

  alias Cgc2046.Accounts.BypassReads

  @impl true
  def describe(_opts), do: "用户资料可读：本人 / public / workspace 共享 / only_me（匿名不可读）"

  @impl true
  def filter(nil, _context, _opts) do
    # 匿名：恒假 filter（每行 is_nil(id) 为 false → 0 行；不可 strict 求值，
    # 走 filter 阶段返回空列表，避免暴露用户存在性）
    expr(is_nil(id))
  end

  def filter(actor, _context, _opts) do
    actor_ws_ids = BypassReads.shared_workspace_ids(actor)

    expr(
      id == ^actor.id or
        visibility == :public or
        (visibility == :workspace and
           exists(workspace_memberships, workspace_id in ^actor_ws_ids))
    )
  end
end
