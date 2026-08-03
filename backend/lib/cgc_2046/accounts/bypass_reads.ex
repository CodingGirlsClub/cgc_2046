defmodule Cgc2046.Accounts.BypassReads do
  @moduledoc """
  旁路读取面（#3 原始 SQL 逃生舱收敛）：本模块是**唯一允许原始 SQL 的出口**。

  ## 安全契约（成文，2026-08-02）

  - 主查询仍受 policy 门控：旁路读取只服务于**已经过 policy 的查询** ——
    能读到 workspace 行才有资格展示其成员数（首页社区规模 / 成员管理页）；
    能读 workspace_membership 行才有资格展示其平铺展示字段。
  - 旁路仅限两类读取：**聚合**（`member_count/1`）与**平铺展示字段**（
    `WorkspaceMembership.user_email` / `user_display_name` 的 LEFT JOIN 表达式）。
    平铺字段为**契约归类**：实现仍是资源内 Ash 表达式（见 workspace_membership.ex），
    本模块不承接其代码，只承接其契约与 quirk 知识。不做整行 / 整表旁路。
  - 新的旁路读路径**先查这里，不要发明第四个逃生舱**（如 JoinRequest 审批
    展示申请人邮箱：沿用平铺字段模式）。

  ## 为什么不能走 Ash 正常路径（quirk 知识，唯一出处）

  - `expr(count(memberships))` / aggregate count：生成的子查询会叠加
    `WorkspaceMembership` read policy，而 `WorkspaceActorIsOwnerOrAdmin`
    （SimpleCheck）在子查询 context 取不到 workspace_id（filter 是
    `parent.id == workspace_id` 形式），只剩「成员本人可读自己」分支 →
    计数被过滤成仅 actor 自己（实测：SQL count=3，计算字段返回 1）。
  - `exists/2` 子查询**不会**叠加 read policy（与 aggregate count 相反）——
    但 `ReadUserByVisibility` 仍需先取得 actor 的 workspace_id 集合注入
    `workspace_id in ^actor_ws_ids`，该集合查询同样旁路
    （`shared_workspace_ids/1`）。
  - `user_email` / `user_display_name`：嵌套 `user` 关系加载会被 User read
    policy 过滤为 null（User 默认 only_me 仅本人可读），故用 SQL 表达式
    LEFT JOIN users 平铺，不经 user read policy。

  ## 错误姿态（与收敛前一致）

  两处查询均 `{:ok, result} = Ecto.Adapters.SQL.query(...)` 严格匹配：DB 失败
  直接抛出（调用方在 policy / 计算字段热路径，失败即 500，无降级）。非法
  UUID 输入在 `Ecto.UUID.dump!/1` 阶段即抛 ArgumentError。
  """

  alias Cgc2046.Accounts.User
  alias Cgc2046.Repo

  @doc """
  按工作台批量统计成员数（GROUP BY workspace_id，不经 membership read policy）。
  返回 `%{workspace_id => count}`；无成员的工作台不出现（调用方 `Map.get(_, 0)`
  兜底）；空输入返回 `%{}`（空数组下 `workspace_id = ANY($1::uuid[])` 恒 0 行）。
  """
  @spec member_count([String.t()]) :: %{String.t() => non_neg_integer}
  def member_count(workspace_ids) do
    {:ok, result} =
      Ecto.Adapters.SQL.query(
        Repo,
        """
        SELECT workspace_id::text, count(*)::bigint
        FROM workspace_memberships
        WHERE workspace_id = ANY($1::uuid[])
        GROUP BY workspace_id
        """,
        [Enum.map(workspace_ids, &Ecto.UUID.dump!/1)]
      )

    Map.new(result.rows, fn [workspace_id, count] -> {workspace_id, count} end)
  end

  @doc """
  目标工作台当前持有 owner 角色的成员数（按 membership 去重，一人多角色算 1 次）。
  不经 membership read policy（与 member_count/1 同一逃生舱契约）。
  DB 失败直接抛（与 member_count/1 一致）。非 owner 的 membership 不计数。
  """
  @spec owner_count(String.t()) :: non_neg_integer
  def owner_count(workspace_id) do
    {:ok, result} =
      Ecto.Adapters.SQL.query(
        Repo,
        """
        SELECT count(DISTINCT wm.id)::bigint
        FROM workspace_memberships wm
        JOIN membership_roles mr ON mr.membership_id = wm.id
        JOIN roles r ON r.id = mr.role_id
        WHERE wm.workspace_id = $1 AND r.name = 'owner'
        """,
        [Ecto.UUID.dump!(workspace_id)]
      )

    case result.rows do
      [[count]] -> count
      [] -> 0
    end
  end

  @doc """
  actor 加入的全部工作台 id（不经 membership read policy；供
  ReadUserByVisibility 注入 exists 子查询）。非成员返回 `[]`。
  """
  @spec shared_workspace_ids(%User{}) :: [String.t()]
  def shared_workspace_ids(actor) do
    {:ok, result} =
      Ecto.Adapters.SQL.query(
        Repo,
        "SELECT workspace_id::text FROM workspace_memberships WHERE user_id = $1",
        [Ecto.UUID.dump!(actor.id)]
      )

    Enum.map(result.rows, fn [workspace_id] -> workspace_id end)
  end
end
