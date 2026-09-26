defmodule Cgc2046.Mcp.Tools.CloseRecruitmentCohort do
  @moduledoc """
  关闭招募批次：open → closed（campaign 运营通道，Owner/Admin 管理工具，确认流
  two-tool 写，D-D3）。

  语义对齐 GraphQL closeRecruitmentCohort（同 `Recruitment.RecruitmentCohort
  :close` action）。关闭后不再放行新申请，在途申请照常走完；closed 非终态
  （可 open 重开），但状态迁移影响公开申请页，仍走确认流。

  非 open 快速失败（不建 pending，launch_event 同款纪律）：draft 无需关闭
  （不 open 即可），closed 已关闭。

  Owner/Admin 专属（ADR-0001 D6/D7）：Wrapper 默认 fail-closed member 门 +
  工具层 Rbac.manage?/2 判定；业务 update action policy 兜底。
  """
  use Anubis.Server.Component, type: :tool

  alias Cgc2046.Accounts.Rbac
  alias Cgc2046.Mcp.Tools.RecruitmentCohortHelpers, as: H
  alias Cgc2046.Mcp.{Confirmation, Wrapper}

  # 发给调用方 agent 的工具描述（只写契约）；@moduledoc 留给维护者
  @impl true
  def description do
    """
    工作台 Owner/Admin 专用：关闭一个开放中（open）的招募批次。关闭后不再接受新申请，已提交的申请
    照常处理；之后可以重新开放。批次不是 open 时（draft 不需要关闭）直接返回错误。
    走确认流：第一次调用只返回 needs_confirmation + pending_id + summary，
    用户确认后调 confirm_operation(pending_id) 才执行。
    """
  end

  schema do
    field(:workspace_id, {:required, :string}, description: "目标工作台 ID（UUID）")
    field(:cohort_id, {:required, :string}, description: "待关闭招募批次 ID（UUID，须为 open）")
  end

  @impl true
  def execute(params, frame) do
    result =
      Wrapper.run(frame, params, "close_recruitment_cohort", fn actor, workspace_id, params ->
        cohort_id = params["cohort_id"]

        with :ok <- authorize(actor, workspace_id),
             {:ok, cohort} <- H.fetch_cohort(actor, workspace_id, cohort_id) do
          case cohort.status do
            :open ->
              Confirmation.request(
                frame.assigns[:current_user],
                "close_recruitment_cohort",
                params,
                "关闭招募批次「#{cohort.name}」（#{cohort.id}）：open → closed。" <>
                  "关闭后不再放行新申请，在途申请照常走完；后续可用 open_recruitment_cohort 重新开放"
              )

            :draft ->
              {:error, "cannot close from status=draft（draft 无需关闭，不 open 即可）"}

            :closed ->
              {:error, "cannot close from status=closed（批次已关闭）"}
          end
        end
      end)

    Cgc2046.Mcp.Tools.Response.to_response(result, frame)
  end

  @doc """
  确认后真正执行（由 `Confirmation.execute/3` 直接分派调用）。
  params 为 pending 落库的 redact 后参数（本工具参数无敏感键，直接可用）。
  """
  @spec execute_confirmed(term(), map()) :: {:ok, map()} | {:error, String.t()}
  def execute_confirmed(actor, params) do
    workspace_id = params["workspace_id"]
    cohort_id = params["cohort_id"]

    with {:ok, cohort} <- H.fetch_cohort(actor, workspace_id, cohort_id) do
      # 并发竞态（确认窗口内状态已被迁移）由域内状态语义兜底：closed → closed
      # 为同值 update，无害；不静默吞 Forbidden
      case cohort
           |> Ash.Changeset.for_update(:close, %{}, tenant: workspace_id)
           |> Ash.update(actor: actor, tenant: workspace_id) do
        {:ok, closed} ->
          {:ok, H.row(closed)}

        {:error, %Ash.Error.Forbidden{}} ->
          {:error,
           "forbidden: not allowed to close recruitment cohort in workspace #{workspace_id}"}

        {:error, err} ->
          {:error, Cgc2046.Mcp.Errors.message(err, "failed to close recruitment cohort")}
      end
    end
  end

  # Owner/Admin 专属（ADR-0001 D6/D7）：工具层管理角色判定，非管理角色成员快速拒绝
  defp authorize(actor, workspace_id) do
    if Rbac.manage?(actor, workspace_id) do
      :ok
    else
      {:error, "forbidden: owner or admin required to close recruitment cohorts"}
    end
  end
end
