defmodule Cgc2046.Mcp.Tools.CreateRecruitmentCohort do
  @moduledoc """
  创建招募批次（campaign 运营通道，Owner/Admin 管理工具，直接写不进确认流）。

  语义对齐 GraphQL createRecruitmentCohort（同 `Recruitment.RecruitmentCohort
  :create` action）：status 恒 draft（domain default）。draft 批次公开申请页
  不可见、可编辑、无公开面影响，可逆低风险，不进 D-D3 确认流（create_event
  R12 同款依据）；生命周期推进（update/open/close）走确认流工具。

  「同一 workspace 至多一个 open」不变量由 DB 部分唯一索引承载，本工具只造
  draft 不触该约束；开放走 open_recruitment_cohort（确认流）。

  Owner/Admin 专属（ADR-0001 D6/D7，批次写面与 GraphQL 同边界）：Wrapper 默认
  fail-closed member 门 + 工具层 Rbac.manage?/2 判定；业务 create action 的
  WorkspaceActorIsOwnerOrAdmin policy 兜底。
  """
  use Anubis.Server.Component, type: :tool

  alias Cgc2046.Accounts.Rbac
  alias Cgc2046.Mcp.Tools.RecruitmentCohortHelpers, as: H
  alias Cgc2046.Mcp.Wrapper
  alias Cgc2046.Recruitment.RecruitmentCohort

  # 与 RecruitmentCohort :create 的 accept 一一对应（不发明字段）
  @create_fields ~w(name apply_deadline_at starts_at ends_at)

  schema do
    field(:workspace_id, {:required, :string}, description: "目标工作台 ID（UUID）")

    field(:name, {:required, :string}, description: "批次名称（如「第 1 批 · 首批志愿者招募」）")

    field(:apply_deadline_at, {:required, :string},
      description: "申请截止时间（ISO8601，必填——domain allow_nil?: false）"
    )

    field(:starts_at, :string, description: "执行周期开始（ISO8601；不提供 = 未定）")
    field(:ends_at, :string, description: "执行周期结束（ISO8601；不提供 = 未定）")
  end

  @impl true
  def execute(params, frame) do
    result =
      Wrapper.run(frame, params, "create_recruitment_cohort", fn actor, workspace_id, params ->
        with :ok <- authorize(actor, workspace_id) do
          attrs =
            params
            |> take_fields(@create_fields)
            |> H.parse_datetime_attrs()

          case RecruitmentCohort
               |> Ash.Changeset.for_create(:create, attrs, tenant: workspace_id)
               |> Ash.create(actor: actor, tenant: workspace_id) do
            {:ok, cohort} ->
              {:ok, H.row(cohort)}

            {:error, %Ash.Error.Forbidden{}} ->
              {:error,
               "forbidden: not allowed to create recruitment cohort in workspace #{workspace_id}"}

            {:error, err} ->
              {:error, Cgc2046.Mcp.Errors.message(err, "failed to create recruitment cohort")}
          end
        end
      end)

    Cgc2046.Mcp.Tools.Response.to_response(result, frame)
  end

  # Owner/Admin 专属（ADR-0001 D6/D7）：工具层管理角色判定，非管理角色成员快速拒绝
  defp authorize(actor, workspace_id) do
    if Rbac.manage?(actor, workspace_id) do
      :ok
    else
      {:error, "forbidden: owner or admin required to create recruitment cohorts"}
    end
  end

  # 白名单取参（键恒为 string——Wrapper.run 顶层 normalize_keys 已归一；nil 视为
  # 未提供）。时间字段的偏移解析在共享 helper（recruitment_cohort_helpers 单源）
  defp take_fields(params, fields) do
    fields
    |> Enum.filter(fn field -> not is_nil(params[field]) end)
    |> Map.new(fn field -> {String.to_existing_atom(field), params[field]} end)
  end
end
