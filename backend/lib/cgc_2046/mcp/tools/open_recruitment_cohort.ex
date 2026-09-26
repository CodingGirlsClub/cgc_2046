defmodule Cgc2046.Mcp.Tools.OpenRecruitmentCohort do
  @moduledoc """
  开放招募批次：draft | closed → open（campaign 运营通道，Owner/Admin 管理工具，
  确认流 two-tool 写，D-D3）。

  语义对齐 GraphQL openRecruitmentCohort（同 `Recruitment.RecruitmentCohort
  :open` action）。开放即公开申请页批次卡生效、申请入口开启。「同一 workspace
  至多一个 open」由 DB 部分唯一索引兜底，撞线转稳定业务错误
  `recruitment_cohort_open_conflict`（域 handle_write_error），本工具层不重复
  造约束。

  非 draft/closed 快速失败（不建 pending，launch_event 同款纪律）。

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
    工作台 Owner/Admin 专用：开放一个招募批次（draft 或 closed → open），公开申请页随即显示并接受申请。
    同一工作台同时只能有一个开放中的批次，冲突时返回 recruitment_cohort_open_conflict。批次不是 draft 或
    closed 时直接返回错误。
    走确认流：第一次调用只返回 needs_confirmation + pending_id + summary，
    用户确认后调 confirm_operation(pending_id) 才执行。
    """
  end

  schema do
    field(:workspace_id, {:required, :string}, description: "目标工作台 ID（UUID）")
    field(:cohort_id, {:required, :string}, description: "待开放招募批次 ID（UUID，须为 draft 或 closed）")
  end

  @impl true
  def execute(params, frame) do
    result =
      Wrapper.run(frame, params, "open_recruitment_cohort", fn actor, workspace_id, params ->
        cohort_id = params["cohort_id"]

        with :ok <- authorize(actor, workspace_id),
             {:ok, cohort} <- H.fetch_cohort(actor, workspace_id, cohort_id) do
          if cohort.status == :open do
            {:error, "cannot open from status=open（批次已在开放中；同台先关旧批才开新批）"}
          else
            Confirmation.request(
              frame.assigns[:current_user],
              "open_recruitment_cohort",
              params,
              "开放招募批次「#{cohort.name}」（#{cohort.id}）：#{cohort.status} → open。" <>
                "开放后批次在公开申请页可见、申请入口开启"
            )
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
      # 并发竞态（确认窗口内他批次先 open）由域的 DB 部分唯一索引在 confirm
      # 段兜底：撞线转稳定业务错误，不静默
      case cohort
           |> Ash.Changeset.for_update(:open, %{}, tenant: workspace_id)
           |> Ash.update(actor: actor, tenant: workspace_id) do
        {:ok, opened} ->
          {:ok, H.row(opened)}

        {:error, %Ash.Error.Forbidden{}} ->
          {:error,
           "forbidden: not allowed to open recruitment cohort in workspace #{workspace_id}"}

        {:error, err} ->
          {:error, Cgc2046.Mcp.Errors.message(err, "failed to open recruitment cohort")}
      end
    end
  end

  # Owner/Admin 专属（ADR-0001 D6/D7）：工具层管理角色判定，非管理角色成员快速拒绝
  defp authorize(actor, workspace_id) do
    if Rbac.manage?(actor, workspace_id) do
      :ok
    else
      {:error, "forbidden: owner or admin required to open recruitment cohorts"}
    end
  end
end
