defmodule Cgc2046.Mcp.Tools.ListMyTasks do
  @moduledoc """
  读取 actor 在目标工作台的待办任务（role-agent-journeys-v2 S1，R8 v0；R20）。

  任务读面 = 两类聚合：

  1. `Cgc2046.PendingApprovals`（报名 / 加入申请 / 赞助三类 pending 行，
     已按 actor 的 owner/admin 成员资格在查询层预收窄），过滤到本工作台；
  2. 课程教研流程行（S5 接入，R20）——本工作台非终态 prep run 按 actor 角色
     分派可认领 / 待我生产 / 待我审核三行；S1 先留接口（`prep_tasks/2` 恒
     返回空列表），S5 填充实现。

  member-only + workspace_id 必填（fail-closed 默认，无豁免 meta）；工作台按
  id 以 actor 授权读取，不存在 → error。
  """
  use Anubis.Server.Component, type: :tool

  alias Cgc2046.Accounts.Workspace
  alias Cgc2046.Mcp.Wrapper
  alias Cgc2046.PendingApprovals

  schema do
    field(:workspace_id, {:required, :string}, description: "目标工作台 ID（UUID）")
  end

  @impl true
  def execute(params, frame) do
    result =
      Wrapper.run(frame, params, "list_my_tasks", fn actor, workspace_id, _params ->
        with {:ok, workspace} <- fetch_workspace(workspace_id, actor),
             {:ok, rows} <- PendingApprovals.list(actor) do
          approval_tasks = Enum.filter(rows, &(&1.workspace_id == workspace.id))

          tasks = approval_tasks ++ prep_tasks(actor, workspace)

          {:ok, %{tasks: tasks, count: length(tasks), workspace_id: workspace.id}}
        end
      end)

    Cgc2046.Mcp.Tools.Response.to_response(result, frame)
  end

  # 成员身份已由 Wrapper member-only 门保证，此处以 actor 授权读工作台（invite_only
  # 工作台非成员不可读，与门语义一致）。
  defp fetch_workspace(workspace_id, actor) do
    case Workspace
         |> Ash.Query.for_read(:get_by_id, %{id: workspace_id})
         |> Ash.read_one(actor: actor) do
      {:ok, nil} -> {:error, "workspace not found: #{workspace_id}"}
      {:ok, workspace} -> {:ok, workspace}
      {:error, _} -> {:error, "failed to load workspace"}
    end
  end

  # ── 课程教研任务行（S5 接口留位）───────────────────────────────────
  # S5 接入：本工作台非终态 course_preparation run 按 actor 角色分派
  # course_prep_claimable / course_prep_authoring / course_prep_review 三类行
  # （行形状含 course_id / prep_state / context_title，与 PendingApprovals 行
  # 并列返回）。S1 恒为空——prep run 尚不存在。
  defp prep_tasks(_actor, _workspace), do: []
end
