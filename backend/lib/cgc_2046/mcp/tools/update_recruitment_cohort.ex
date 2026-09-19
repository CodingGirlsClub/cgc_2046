defmodule Cgc2046.Mcp.Tools.UpdateRecruitmentCohort do
  @moduledoc """
  编辑招募批次元数据（campaign 运营通道，Owner/Admin 管理工具，确认流
  two-tool 写，D-D3）。

  语义对齐 GraphQL updateRecruitmentCohort（同 `Recruitment.RecruitmentCohort
  :update` action）；状态迁移不经本工具（open/close 各有专用）。open 批次改
  申请截止会改变申请者可见的截止预期，故元数据变更同样走确认流（update_event
  同款纪律）。

  Owner/Admin 专属（ADR-0001 D6/D7）：Wrapper 默认 fail-closed member 门 +
  工具层 Rbac.manage?/2 判定；业务 update action 的
  WorkspaceActorIsOwnerOrAdmin policy 兜底。
  """
  use Anubis.Server.Component, type: :tool

  alias Cgc2046.Accounts.Rbac
  alias Cgc2046.Mcp.Tools.RecruitmentCohortHelpers, as: H
  alias Cgc2046.Mcp.{Confirmation, Wrapper}

  # 与 RecruitmentCohort :update 的 accept 一一对应（不发明字段）
  @updatable_fields ~w(name apply_deadline_at starts_at ends_at)

  schema do
    field(:workspace_id, {:required, :string}, description: "目标工作台 ID（UUID）")
    field(:cohort_id, {:required, :string}, description: "招募批次 ID（UUID）")
    field(:name, :string, description: "批次名称")
    field(:apply_deadline_at, :string, description: "申请截止时间（ISO8601）")
    field(:starts_at, :string, description: "执行周期开始（ISO8601）")
    field(:ends_at, :string, description: "执行周期结束（ISO8601）")
  end

  @impl true
  def execute(params, frame) do
    result =
      Wrapper.run(frame, params, "update_recruitment_cohort", fn actor, workspace_id, params ->
        cohort_id = params["cohort_id"]

        with :ok <- authorize(actor, workspace_id),
             {:ok, cohort} <- H.fetch_cohort(actor, workspace_id, cohort_id),
             {:ok, changes} <- collect_changes(params) do
          summary =
            "更新招募批次「#{cohort.name}」（#{cohort.id}）字段：" <>
              Enum.map_join(changes, "；", fn {field, value} -> "#{field} → #{value}" end)

          Confirmation.request(
            frame.assigns[:current_user],
            "update_recruitment_cohort",
            params,
            summary
          )
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

    # changes 全空不可能到达：第一段 collect_changes 已拒（pending 不会落库）；
    # 真到达即域内 no-op，无害
    with {:ok, cohort} <- H.fetch_cohort(actor, workspace_id, cohort_id),
         {:ok, changes} <- collect_changes(params) do
      case cohort
           |> Ash.Changeset.for_update(:update, changes, tenant: workspace_id)
           |> Ash.update(actor: actor, tenant: workspace_id) do
        {:ok, updated} ->
          {:ok, H.row(updated)}

        {:error, %Ash.Error.Forbidden{}} ->
          {:error,
           "forbidden: not allowed to update recruitment cohort in workspace #{workspace_id}"}

        {:error, err} ->
          {:error, Cgc2046.Mcp.Errors.message(err, "failed to update recruitment cohort")}
      end
    end
  end

  # Owner/Admin 专属（ADR-0001 D6/D7）：工具层管理角色判定，非管理角色成员快速拒绝
  defp authorize(actor, workspace_id) do
    if Rbac.manage?(actor, workspace_id) do
      :ok
    else
      {:error, "forbidden: owner or admin required to update recruitment cohorts"}
    end
  end

  # 白名单 ∩ 入参（键恒为 string——Wrapper.run 顶层 normalize_keys 已归一；nil
  # 视为未提供），保持 @updatable_fields 声明序。时间字段的偏移解析在共享
  # helper（recruitment_cohort_helpers 单源）。两段共用本函数，pending 落库的
  # 原始 params 在 confirm 段重新收集结果一致。全空 = 无可写变更，第一段
  # 快速失败不建 pending。
  defp collect_changes(params) do
    changes =
      @updatable_fields
      |> Enum.filter(fn field -> not is_nil(params[field]) end)
      |> Map.new(fn field -> {String.to_existing_atom(field), params[field]} end)
      |> H.parse_datetime_attrs()

    if map_size(changes) == 0,
      do:
        {:error,
         "nothing to update: provide at least one of #{Enum.join(@updatable_fields, "/")}"},
      else: {:ok, changes}
  end
end
