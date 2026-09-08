defmodule Cgc2046.Mcp.Tools.CreateEvent do
  @moduledoc """
  创建活动草稿（role-agent-journeys-v2 S3，Owner/Admin 管理工具，直接写不进确认流）。

  语义对齐 GraphQL createEvent（同 `Events.Event :create` action）：status 恒 draft
  （domain change 强制），slug 缺省由 domain 生成 `e-<hex>`；title 必填
  （活动无课程的 provisional_title 零输入草稿机制）。

  直接写依据：创建私密 draft 可逆/低风险（R12），不进 D-D3 确认流；生命周期
  推进（launch/close/cancel）与元数据变更（update_event）走确认流工具。

  Owner/Admin 专属：默认 fail-closed member 门 + 工具层管理角色判定；
  业务 create action 的 `WorkspaceActorIsOwnerOrAdmin` policy 兜底。
  """
  use Anubis.Server.Component, type: :tool

  alias Cgc2046.Accounts.{MembershipContext, Role}
  alias Cgc2046.Events.Event
  alias Cgc2046.Mcp.Wrapper

  # 与 Event :create 的 accept 一一对应（不发明字段）；nil = 未提供
  @create_fields ~w(title description curriculum_enabled curriculum_requirements
                    enrollment_policy capacity registration_deadline starts_at ends_at
                    venue visibility slug sponsorship_enabled sponsorship_tiers
                    sponsorship_deadline pricing_enabled price_tiers)

  schema do
    field(:workspace_id, {:required, :string}, description: "目标工作台 ID（UUID）")
    field(:title, {:required, :string}, description: "活动标题")
    field(:description, :string, description: "公开展示文案")
    field(:slug, :string, description: "公开 URL 段（小写 [a-z0-9-]；缺省由平台生成 e-<hex>）")

    field(:visibility, :string, description: "可见性：public 公开 / workspace 仅工作台（默认 public）")

    field(:enrollment_policy, :string, description: "报名策略：open / request / invite_only（默认 open）")
    field(:capacity, :integer, description: "报名名额上限（≥1；不提供 = 不限）")
    field(:registration_deadline, :string, description: "报名截止时间（ISO8601；不提供 = 不设截止）")
    field(:starts_at, :string, description: "活动开始时间（ISO8601；不提供 = 未定）")
    field(:ends_at, :string, description: "活动结束时间（ISO8601，须晚于 starts_at）")
    field(:venue, :map, description: "结构化场地（country/province/city/district 四键；不提供 = 线上或未定）")

    field(:sponsorship_enabled, :boolean, description: "是否开放赞助入口（默认 true；tiers 未配置时入口隐藏）")

    field(:sponsorship_tiers, {:list, :map},
      description: "赞助档位配置（SponsorshipTier 形状：%{id, name, amount_cents, ...}）"
    )

    field(:sponsorship_deadline, :string, description: "赞助意向截止（ISO8601；不提供 = 长期开放）")
    field(:pricing_enabled, :boolean, description: "是否收费（默认 false；true 时报名须选档并完成支付）")

    field(:price_tiers, {:list, :map},
      description: "价格档位配置（PriceTier 形状：%{id, name, amount_cents, ...}）"
    )

    field(:curriculum_enabled, :boolean, description: "是否启用教研 workflow（默认 true）")
    field(:curriculum_requirements, :map, description: "教研材料需求（audience/duration/sections 等）")
  end

  @impl true
  def execute(params, frame) do
    result =
      Wrapper.run(frame, params, "create_event", fn actor, workspace_id, params ->
        with :ok <- authorize(actor, workspace_id) do
          input = take_fields(params, @create_fields)

          case Event
               |> Ash.Changeset.for_create(:create, input, tenant: workspace_id)
               |> Ash.create(actor: actor, tenant: workspace_id) do
            {:ok, event} ->
              {:ok,
               %{
                 event_id: event.id,
                 title: event.title,
                 slug: event.slug,
                 status: to_string(event.status),
                 visibility: to_string(event.visibility),
                 pricing_enabled: event.pricing_enabled
               }}

            {:error, %Ash.Error.Forbidden{}} ->
              {:error, "forbidden: not allowed to create event in workspace #{workspace_id}"}

            {:error, %Ash.Error.Invalid{} = err} ->
              {:error, Exception.message(err)}

            {:error, _} ->
              {:error, "failed to create event"}
          end
        end
      end)

    Cgc2046.Mcp.Tools.Response.to_response(result, frame)
  end

  # Owner/Admin 专属（S3）：工具层管理角色判定，非管理角色成员快速拒绝
  defp authorize(actor, workspace_id) do
    if actor |> MembershipContext.role_names(workspace_id) |> Enum.any?(&Role.manage_role?/1) do
      :ok
    else
      {:error, "forbidden: owner or admin required to create events"}
    end
  end

  # 白名单取参（string/atom 键双兼容；固定字段名 to_existing_atom 不污染 atom 表）；
  # nil 值视为未提供（本工具不支持显式置空）
  defp take_fields(params, fields) do
    fields
    |> Enum.filter(fn field ->
      value = params[field] || params[String.to_existing_atom(field)]
      not is_nil(value)
    end)
    |> Map.new(fn field ->
      {String.to_existing_atom(field), params[field] || params[String.to_existing_atom(field)]}
    end)
  end
end
