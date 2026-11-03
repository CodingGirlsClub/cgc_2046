defmodule Cgc2046.Mcp.Tools.ListRecruitmentCohorts do
  @moduledoc """
  列出工作台全部招募批次（campaign 运营通道）——批次管理面的可编辑发现面
  （list_workspace_events 同款）。

  公开申请页只依赖 `current_recruitment_cohort`（匿名只读 open）；运营 agent
  需要「本台全部批次」（含 draft/closed）来自举 cohort_id 供 update/open/close
  使用——批次无 slug，跨会话只有 id 可寻。

  返回：`cohort_id / name / status / apply_deadline_at / starts_at / ends_at`。
  `status` 可选过滤（draft|open|closed，非法值报错带清单）。按创建时间倒序
  （与 GraphQL listRecruitmentCohorts 同款），封顶 100。

  授权 = Wrapper 成员门 + 领域 actor 读：普通成员仅 open，管理者按领域权限读取。
  """

  use Anubis.Server.Component, type: :tool

  alias Cgc2046.Mcp.Tools.RecruitmentCohortHelpers, as: H
  alias Cgc2046.Mcp.Wrapper
  alias Cgc2046.Recruitment.RecruitmentCohort

  require Ash.Query

  @limit 100

  # 发给调用方 agent 的工具描述（只写契约）；@moduledoc 留给维护者
  @impl true
  def description do
    """
    List recruitment cohorts visible to the caller in a workspace. Members can read open cohorts;
    owners/admins can also read draft/closed cohorts. Optional status filter: draft | open | closed.
    Returns cohort_id, name, status, apply_deadline_at, starts_at and ends_at, newest first, up to
    100 rows. Subsequent update/open/close operations use cohort_id.
    """
  end

  schema do
    field(:workspace_id, {:required, :string}, description: "目标工作台 ID（UUID）")
    field(:status, :string, description: "按状态过滤：draft | open | closed（不提供 = 全部）")
  end

  @impl true
  def execute(params, frame) do
    result =
      Wrapper.run(frame, params, "list_recruitment_cohorts", fn actor, workspace_id, params ->
        with {:ok, status} <- parse_status(params["status"]),
             {:ok, rows} <- read_cohorts(actor, workspace_id, status) do
          {:ok, %{count: length(rows), cohorts: rows}}
        end
      end)

    Cgc2046.Mcp.Tools.Response.to_response(result, frame)
  end

  # 空串/nil = 不过滤；值经 RecruitmentCohort.status_values/1 白名单（域单源，
  # 非法值报错带清单）
  defp parse_status(nil), do: {:ok, nil}
  defp parse_status(""), do: {:ok, nil}

  defp parse_status(status) when is_binary(status) do
    values = RecruitmentCohort.status_values()

    case Enum.find(values, &(to_string(&1) == status)) do
      nil ->
        {:error, "invalid status (expected one of #{Enum.map_join(values, "|", &to_string/1)})"}

      atom ->
        {:ok, atom}
    end
  end

  defp parse_status(_), do: {:error, "status must be a string"}

  # 成员门之后继续走领域 actor 读，状态过滤不能扩大 actor 的可见集合。
  defp read_cohorts(actor, workspace_id, status) do
    RecruitmentCohort
    |> scope_status(status)
    |> Ash.Query.sort(inserted_at: :desc, id: :desc)
    |> Ash.Query.limit(@limit)
    |> Ash.read(actor: actor, tenant: workspace_id)
    |> case do
      {:ok, cohorts} -> {:ok, Enum.map(cohorts, &H.row/1)}
      {:error, _} = err -> err
    end
  end

  # filter 宏不接受任意控制流（if AST 不被识别）——分支在宏外
  defp scope_status(query, nil), do: query
  defp scope_status(query, status), do: Ash.Query.filter(query, status == ^status)
end
