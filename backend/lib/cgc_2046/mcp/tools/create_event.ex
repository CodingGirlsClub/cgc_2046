defmodule Cgc2046.Mcp.Tools.CreateEvent do
  @moduledoc """
  创建活动草稿（role-agent-journeys-v2 S3，Owner/Admin 管理工具，直接写不进确认流）。

  语义对齐 GraphQL createEvent（同 `Events.Event :create` action）：status 恒 draft
  （domain change 强制），slug 缺省由 domain 生成 `e-<hex>`；title 必填
  （活动无课程的 provisional_title 零输入草稿机制）。

  直接写依据：创建私密 draft 可逆/低风险（R12），不进 D-D3 确认流；生命周期
  推进（launch/close/cancel）与元数据变更（update_event）走确认流工具。

  挂载继承可见（#596）：带 initiative_id 建场时，域内锁 initiative 行解析出的
  「本次生效的继承结果」随响应回传——`initiative`（id/name/slug，未挂载为 null）
  与 `inherited`（事件字段 → `%{value, source}`；source = locked（平台锁死，写后
  不可改）/ default（挂载时按规则快照，之后可改）；无继承为 `{}`）。挂载前可用
  `preview_initiative_mount` 读四规则的原始值与锁态。

  解除挂载来源标记（#630）：响应恒带 `detached_rule_provenance`（持久化属性
  `event.detached_rule_provenance`，不是 `inheritance_of/1` 的 metadata；新建恒
  nil，形状同 GraphQL `Event.detachedRuleProvenance` 列）。

  Owner/Admin 专属：默认 fail-closed member 门 + 工具层管理角色判定；
  业务 create action 的 `WorkspaceActorIsOwnerOrAdmin` policy 兜底。
  """
  use Anubis.Server.Component, type: :tool

  alias Cgc2046.Accounts.Rbac
  alias Cgc2046.Events.Event
  alias Cgc2046.Initiatives.RuleInheritance
  alias Cgc2046.Mcp.Wrapper

  # 与 Event :create 的 accept 一一对应（不发明字段）；nil = 未提供
  @create_fields ~w(title description curriculum_enabled curriculum_requirements
                    enrollment_policy capacity registration_deadline starts_at ends_at
                    venue visibility slug sponsorship_enabled sponsorship_tiers
                    sponsorship_deadline pricing_enabled price_tiers course_revision_id
                    initiative_id deposit_enabled deposit_amount_cents min_age min_participants)

  # 字段白名单单源（#511）：batch_create_events 行级取参与本工具共用同一清单，
  # 不复制（防两处漂移）。行级取参逻辑判别法相同（nil = 未提供；false 是合法
  # 显式值，不能用 || 收集）。
  @doc "create action 的字段白名单（batch_create_events 行级取参共用，单源不复制）"
  @spec create_fields() :: [String.t()]
  def create_fields, do: @create_fields

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

    field(:course_revision_id, :string,
      description: "配套课程锚点（published course revision UUID；不提供=无配套课）"
    )

    field(:initiative_id, :string,
      description:
        "草稿所属 Initiative UUID（须为 open 且四规则齐备）；挂载会按规则强制写入押金/年龄/人数/报名截止，生效结果见响应 inherited"
    )

    field(:deposit_enabled, :boolean, description: "是否收取活动押金")
    field(:deposit_amount_cents, :integer, description: "押金金额（分）")
    field(:min_age, :integer, description: "最低年龄；不提供=无门槛")
    field(:min_participants, :integer, description: "最低成班人数；不提供=不判定")
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
                 pricing_enabled: event.pricing_enabled,
                 # #630：恒在（新建恒 nil），与 #596 的 initiative/inherited 同款
                 # 「agent 无需判键存在」纪律。持久化属性，非 metadata。
                 detached_rule_provenance: event.detached_rule_provenance
               }
               |> Map.merge(RuleInheritance.inheritance_of(event))}

            {:error, %Ash.Error.Forbidden{}} ->
              {:error, "forbidden: not allowed to create event in workspace #{workspace_id}"}

            {:error, err} ->
              {:error, Cgc2046.Mcp.Errors.message(err, "failed to create event")}
          end
        end
      end)

    Cgc2046.Mcp.Tools.Response.to_response(result, frame)
  end

  # Owner/Admin 专属（S3）：工具层管理角色判定，非管理角色成员快速拒绝
  defp authorize(actor, workspace_id) do
    if Rbac.manage?(actor, workspace_id) do
      :ok
    else
      {:error, "forbidden: owner or admin required to create events"}
    end
  end

  # 白名单取参（键恒为 string——Wrapper.run 顶层 normalize_keys 已归一，工具内
  # 不再双键收参；固定字段名 to_existing_atom 不污染 atom 表）；nil 值视为未提供
  # （本工具不支持显式置空）。false 是合法显式值（sponsorship_enabled /
  # curriculum_enabled 域默认 true，用户明确传 false 必须落库），不能用 ||
  # 收集（false || nil → nil 会被当未提供丢弃）。
  defp take_fields(params, fields) do
    fields
    |> Enum.filter(fn field -> not is_nil(take_value(params, field)) end)
    |> Map.new(fn field -> {String.to_existing_atom(field), take_value(params, field)} end)
  end

  defp take_value(params, field), do: Map.get(params, field)
end
