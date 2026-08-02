defmodule Cgc2046.Accounts.Calculations.MemberCount do
  @moduledoc """
  P1-4 Workspace.memberCount：成员数量（SQL 批量 count）。

  为什么不用 `calculate(expr(count(memberships)))` 或 `aggregate count`：
  两者生成的子查询都会应用 `WorkspaceMembership` 的 read policy —— 而
  `WorkspaceActorIsOwnerOrAdmin`（SimpleCheck）在子查询 context 中取不到
  workspace_id（filter 是 `parent.id == workspace_id` 形式），只剩「成员本人
  可读自己」分支生效，导致计数被过滤成仅 actor 自己（实测：SQL count=3，
  计算字段返回 1）。

  本实现直接在 Repo 层批量 `GROUP BY workspace_id` 计数，不经过 Ash policy：
  主查询（Workspace read）已受 policy 控制——能读到 workspace 的行才有资格
  展示其成员数（首页社区规模 / 成员管理页）。
  """

  use Ash.Resource.Calculation

  alias Cgc2046.Repo

  @impl true
  def calculate(records, _opts, _context) do
    ids = records |> Enum.map(& &1.id) |> Enum.reject(&is_nil/1)

    counts =
      if ids == [] do
        %{}
      else
        {:ok, result} =
          Ecto.Adapters.SQL.query(
            Repo,
            """
            SELECT workspace_id::text, count(*)::bigint
            FROM workspace_memberships
            WHERE workspace_id = ANY($1::uuid[])
            GROUP BY workspace_id
            """,
            [Enum.map(ids, &Ecto.UUID.dump!/1)]
          )

        Map.new(result.rows, fn [workspace_id, count] -> {workspace_id, count} end)
      end

    Enum.map(records, fn record ->
      case record.id do
        nil -> 0
        id -> Map.get(counts, id, 0)
      end
    end)
  end
end
