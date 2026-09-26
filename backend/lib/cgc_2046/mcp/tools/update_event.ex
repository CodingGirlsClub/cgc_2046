defmodule Cgc2046.Mcp.Tools.UpdateEvent do
  @moduledoc """
  更新活动元数据（role-agent-journeys-v2 S3，Owner/Admin 管理工具，确认流
  two-tool 写，D-D3）。

  语义对齐 GraphQL updateEvent（同 `Events.Event :update` action）：可更新
  字段 = domain accept 列表（title/description/slug/visibility/enrollment_policy/
  capacity/registration_deadline/starts_at/ends_at/venue/sponsorship_enabled/
  sponsorship_tiers/sponsorship_deadline/pricing_enabled/price_tiers/
  curriculum_enabled/curriculum_requirements）；status 走专用生命周期工具，
  不在此改。

  高风险依据：定价变更（pricing_enabled true→false）会同事务批量免缴待支付报名
  （`Cgc2046.Admission.Changes.WaivePendingOnFeeSlotDisable`，R9/KTD4）——资金相关
  副作用必须经用户确认。pending 摘要精确列出将变更的字段与新值；true→false 时
  追加批量免缴影响摘要（待支付笔数计入）。nil 值视为未提供（不支持显式置空）。

  押金重开例外（#616）：`deposit_enabled` false→true 必须同调用携带正整数
  `deposit_amount_cents`，否则第一段快速拒绝（不建 pending）——旧金额静默
  复活防护；携带金额的调用摘要自然含 `deposit_amount_cents` 行。

  挂载继承可见（#596）：确认后落库的结果带 `initiative`（id/name/slug，未挂载为
  null）与 `inherited`（事件字段 → `%{value, source}`；source = locked（平台锁死，
  每次写入都被强制重写，改成别的值会被拒绝）/ default（仅本次改挂载时按规则
  快照））。未改挂载的普通更新只回 locked 项，与「本次生效」语义一致。

  解除挂载来源标记（#630/#632）：响应恒带 `detached_rule_provenance`（持久化属性
  `event.detached_rule_provenance`，不是 metadata；无标记为 nil）——活动被
  detach（本工具 `detach_initiative: true`，或网站 / GraphQL 侧把 initiative_id
  置 nil）后仍留在场上的锁死规则强制值及其来源 Initiative，形状同 GraphQL 列。
  initiative_id 传 nil 仍视为未提供（nil ≠ detach，解除须用布尔开关）；经本工具
  编辑标记内字段会逐字段清除标记（域内 `prepare_event_changes/2` 同事务处理）。

  Owner/Admin 专属：默认 fail-closed member 门 + 工具层管理角色判定（第一段
  快速拒绝省 pending）；confirm 段由 update policy 兜底。
  """
  use Anubis.Server.Component, type: :tool

  alias Cgc2046.Accounts.Rbac
  alias Cgc2046.Events.Event
  alias Cgc2046.Initiatives.RuleInheritance
  alias Cgc2046.Mcp.{Confirmation, Wrapper}

  require Ash.Query

  # 与 Event :update 的 accept 一一对应（不发明字段）
  @updatable_fields ~w(title description slug visibility enrollment_policy capacity
                       registration_deadline starts_at ends_at venue sponsorship_enabled
                       sponsorship_tiers sponsorship_deadline pricing_enabled price_tiers
                       curriculum_enabled curriculum_requirements course_revision_id initiative_id
                       deposit_enabled deposit_amount_cents min_age min_participants)

  # 发给调用方 agent 的工具描述（只写契约）；@moduledoc 留给维护者
  @impl true
  def description do
    """
    工作台 Owner/Admin 专用：修改活动信息（标题、描述、slug、可见性、报名策略、名额、报名截止、起止时间、
    场地、赞助、定价、押金、年龄与成班人数、教研设置、配套课程、挂载）。只传要改的字段；传 null 视为不
    修改，不能用来清空。状态由 launch / close / cancel 工具修改。pricing_enabled 从 true 改为 false 会
    同时免缴全部待支付报名（摘要列出笔数）；改价只影响之后的新订单。重新开启押金（deposit_enabled 从
    false 改为 true）必须同时传正整数 deposit_amount_cents。initiative_id 挂载或更换挂载，按规则强制写入
    押金 / 年龄 / 人数 / 报名截止；解除挂载用 detach_initiative: true（不能与 initiative_id 同传，仅 draft
    可用）。结果含 initiative、inherited（生效的继承值及来源：locked 每次写入都会强制保持、改成别的值会被
    拒绝；default 只在改挂载时快照）与 detached_rule_provenance（解除挂载后保留的锁定值来源，修改对应字段
    即清除该标记）。
    走确认流：第一次调用只返回 needs_confirmation + pending_id + summary，
    用户确认后调 confirm_operation(pending_id) 才执行。
    """
  end

  schema do
    field(:workspace_id, {:required, :string}, description: "目标工作台 ID（UUID）")
    field(:event_id, {:required, :string}, description: "活动 ID（UUID）")
    field(:title, :string, description: "活动标题")
    field(:description, :string, description: "公开展示文案")
    field(:slug, :string, description: "公开 URL 段（小写 [a-z0-9-]）")
    field(:visibility, :string, description: "可见性：public / workspace（可随时双向切换，D9）")
    field(:enrollment_policy, :string, description: "报名策略：open / request / invite_only")
    field(:capacity, :integer, description: "报名名额上限（≥1）")
    field(:registration_deadline, :string, description: "报名截止时间（ISO8601）")
    field(:starts_at, :string, description: "活动开始时间（ISO8601）")
    field(:ends_at, :string, description: "活动结束时间（ISO8601，须晚于 starts_at）")
    field(:venue, :map, description: "结构化场地（country/province/city/district 四键）")

    field(:course_revision_id, :string,
      description:
        "配套课程锚点（published course revision UUID；本工具不支持拆锚——nil 视为未提供，同 collect_changes 纪律）"
    )

    field(:sponsorship_enabled, :boolean, description: "是否开放赞助入口")
    field(:sponsorship_tiers, {:list, :map}, description: "赞助档位配置（SponsorshipTier 形状）")
    field(:sponsorship_deadline, :string, description: "赞助意向截止（ISO8601）")

    field(:pricing_enabled, :boolean, description: "是否收费；true→false 会批量免缴待支付报名（高风险，确认流）")

    field(:price_tiers, {:list, :map}, description: "价格档位配置（PriceTier 形状；改价不追溯已生成订单）")
    field(:curriculum_enabled, :boolean, description: "是否启用教研 workflow")
    field(:curriculum_requirements, :map, description: "教研材料需求")

    field(:initiative_id, :string,
      description:
        "草稿所属 Initiative UUID（须为 open 且四规则齐备）；传 UUID 会挂载或换挂载并按新规则强制写入押金/年龄/人数/报名截止，生效结果见返回 inherited。解除挂载请改用 detach_initiative: true（勿与本参数同传）；nil 视为未提供（同 course_revision_id 纪律）；已解除挂载的活动在响应/列表带 detached_rule_provenance 来源标记，编辑标记内字段即清除该字段标记"
    )

    field(:detach_initiative, :boolean,
      description:
        "解除挂载：true = 把 initiative_id 置 nil，走域内 detach 路径——locked 规则强制写入的值保留在场、打 detached_rule_provenance 来源标记、场主首改对应字段即清除该字段标记、重新挂载整列清空。仅 draft 且当前挂载中可用；与 initiative_id 互斥（同传报错）；未挂载/已解除时幂等无变化"
    )

    field(:deposit_enabled, :boolean, description: "是否收取活动押金")
    field(:deposit_amount_cents, :integer, description: "押金金额（分）")
    field(:min_age, :integer, description: "最低年龄")
    field(:min_participants, :integer, description: "最低成班人数")
  end

  @impl true
  def execute(params, frame) do
    result =
      Wrapper.run(frame, params, "update_event", fn actor, workspace_id, params ->
        event_id = params["event_id"]

        with :ok <- authorize(actor, workspace_id),
             {:ok, event} <- fetch_event(actor, workspace_id, event_id),
             :ok <- check_deposit_reopen_explicit_amount(event, params),
             :ok <- check_detach_draft(event, params),
             {:ok, changes} <- collect_changes(params) do
          event = load_initiative_name(event, changes)

          summary =
            "更新活动「#{event.title}」（#{event.id}）字段：" <>
              Enum.map_join(changes, "；", fn
                {"initiative_id", nil} -> detach_summary(event)
                {field, value} -> "#{field} → #{preview(value)}"
              end) <> waive_impact_summary(event, changes)

          Confirmation.request(
            frame.assigns[:current_user],
            "update_event",
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
    event_id = params["event_id"]

    with {:ok, event} <- fetch_event(actor, workspace_id, event_id),
         {:ok, changes} <- collect_changes(params) do
      attrs = Map.new(changes, fn {field, value} -> {String.to_existing_atom(field), value} end)

      case event
           |> Ash.Changeset.for_update(:update, attrs, tenant: workspace_id)
           |> Ash.update(actor: actor, tenant: workspace_id) do
        {:ok, updated} ->
          {:ok,
           %{
             event_id: updated.id,
             title: updated.title,
             status: to_string(updated.status),
             updated_fields: Enum.map(changes, fn {field, _value} -> field end),
             # #630：恒在（无标记 nil）；持久化属性，与 #596 metadata 分开取。
             detached_rule_provenance: updated.detached_rule_provenance
           }
           |> Map.merge(RuleInheritance.inheritance_of(updated))}

        {:error, %Ash.Error.Forbidden{}} ->
          {:error,
           "forbidden: owner or admin required to update event in workspace #{workspace_id}"}

        {:error, err} ->
          {:error, Cgc2046.Mcp.Errors.message(err, "failed to update event")}
      end
    end
  end

  # #616：重开押金必须显式携带金额——第一段快速失败，不建 pending（带旧金额
  # 复活风险的调用不值得一轮确认）。资源级 `PaymentModeValidation` 同名不变量
  # 是第二道闸（覆盖 GraphQL 缺键等一切 action 路径）；判据保持一致：写前关 +
  # 请求开 + 金额缺席。
  defp check_deposit_reopen_explicit_amount(event, params) do
    if event.deposit_enabled == false and params["deposit_enabled"] == true and
         is_nil(params["deposit_amount_cents"]) do
      {:error,
       "re-enabling deposit requires an explicit deposit_amount_cents " <>
         "(event_deposit_amount_must_be_explicit): the previous amount would be silently reused"}
    else
      :ok
    end
  end

  # Owner/Admin 专属（S3）：工具层管理角色判定，非管理角色成员快速拒绝
  defp authorize(actor, workspace_id) do
    if Rbac.manage?(actor, workspace_id) do
      :ok
    else
      {:error, "forbidden: owner or admin required to update events"}
    end
  end

  # tenant 收紧活动归属（update_course 同款纪律）：他租户 event_id 与不存在
  # 同一「not found」，不泄露存在性。
  defp fetch_event(actor, workspace_id, event_id) do
    case Event
         |> Ash.Query.for_read(:get_by_id, %{id: event_id})
         |> Ash.read_one(actor: actor, tenant: workspace_id) do
      {:ok, nil} ->
        {:error, "event not found: #{event_id}"}

      {:ok, event} ->
        {:ok, event}

      {:error, %Ash.Error.Forbidden{}} ->
        {:error, "forbidden: not allowed to read event #{event_id}"}

      {:error, _} ->
        {:error, "failed to load event"}
    end
  end

  # #632：detach 仅 draft（域层 ensure_mount_state 同款判据前移第一段）——非
  # draft 挂载中的解除注定被域层拒，不值得一轮确认。幂等 detach（已未挂载，
  # 同值删键无变更，域层视为普通编辑）不在此列。
  defp detach_requested?(params), do: params["detach_initiative"] == true

  defp check_detach_draft(event, params) do
    if detach_requested?(params) and not is_nil(event.initiative_id) and
         event.status not in [nil, :draft] do
      {:error,
       "detach_initiative is only allowed while the event is draft and currently mounted " <>
         "(initiative can only be mounted or changed while event is draft)"}
    else
      :ok
    end
  end

  # 白名单 ∩ 入参（nil 视为未提供；false 是合法值——pricing_enabled true→false 是
  # 本工具的高风险主路径，不能用 || 收集），保持 @updatable_fields 声明序。
  # #632：detach_initiative: true 在此转换为 {"initiative_id", nil} 条目（布尔
  # 开关是表达 nil 的唯一入口，nil 本身仍视为未提供）；execute 与
  # execute_confirmed 两段共用本函数，pending 落库的原始 params 含该布尔，
  # confirm 段重新收集结果一致。与 initiative_id 同传 = 请求自相矛盾，报错。
  defp collect_changes(params) do
    if detach_requested?(params) and not is_nil(params["initiative_id"]) do
      {:error,
       "detach_initiative and initiative_id are mutually exclusive: pass the new initiative " <>
         "to mount, or detach_initiative: true to unmount — not both"}
    else
      detach? = detach_requested?(params)

      changes =
        Enum.flat_map(@updatable_fields, fn field ->
          if field == "initiative_id" and detach? do
            [{"initiative_id", nil}]
          else
            case Map.get(params, field) do
              nil -> []
              value -> [{field, value}]
            end
          end
        end)

      if changes == [] do
        {:error, "no updatable fields provided (#{Enum.join(@updatable_fields, "|")})"}
      else
        {:ok, changes}
      end
    end
  end

  # #632：detach 摘要需要挂载对象名称。Initiative 全资源仅 platform_admin 可读
  # （policy），挂载方 workspace owner 走关联 load 会让整条 Event 读被 Forbidden；
  # name/slug 本就是公开投影信息（Initiatives.Public 同款语义），authorize?: false
  # 只取展示字段，不改变 fetch_event 的 policy 边界。
  defp load_initiative_name(event, changes) do
    if Enum.any?(changes, &match?({"initiative_id", nil}, &1)) and event.initiative_id do
      case Ash.load(event, :initiative, authorize?: false) do
        {:ok, loaded} -> loaded
        {:error, _} -> event
      end
    else
      event
    end
  end

  # #632：detach 的确认流摘要特化渲染——通用形态会渲染成 initiative_id → null，
  # 既不可读也丢了 #624 方案 C「值保留 + 来源标记」的关键语义；用户过目摘要
  # 即在这轮确认里看到 detach 的完整后果。
  defp detach_summary(event) do
    "解除挂载：initiative #{initiative_label(event)} → 不挂载（locked 规则值保留在场，" <>
      "detached_rule_provenance 来源标记，首改即清）"
  end

  # 名字优先级：挂载中（已 load）→ 已解除（provenance 里的原 initiative 身份）→
  # UUID → 未挂载。fetch_event 不做关联 load（Initiative 是 platform_admin-only
  # 资源，挂 owner 会被整条读 Forbidden），挂载中由 load_initiative_name 补载。
  defp initiative_label(%{initiative: %Ash.NotLoaded{}} = event), do: fallback_label(event)
  defp initiative_label(%{initiative: nil} = event), do: fallback_label(event)

  defp initiative_label(%{initiative: initiative}),
    do: "「#{initiative.name}」(#{initiative.slug})"

  defp fallback_label(event) do
    case event.detached_rule_provenance do
      %{"initiative" => %{"name" => name, "slug" => slug}} -> "「#{name}」(#{slug})"
      _ -> event.initiative_id || "未挂载"
    end
  end

  # 批量免缴影响摘要（R9/KTD4，R12 影响可见）：仅 pricing_enabled true→false 时
  # 追加，并计入当前待支付笔数（第一段快速失败前的如实摘要，confirm 段以域
  # 事务内实况为准）
  defp waive_impact_summary(event, changes) do
    disabling? =
      event.pricing_enabled == true and
        Enum.any?(changes, fn {field, value} -> field == "pricing_enabled" and value == false end)

    if disabling? do
      count = payment_pending_count(event)

      "。注意：pricing_enabled 改为 false 将批量免缴该活动全部待支付报名" <>
        "（当前 #{count} 笔 payment_pending → confirmed，关联 pending 订单同事务作废，R9）"
    else
      ""
    end
  end

  defp payment_pending_count(event) do
    Cgc2046.Admission.Enrollment
    |> Ash.Query.filter(event_id == ^event.id and status == :payment_pending)
    |> Ash.count!(authorize?: false, tenant: event.workspace_id)
  end

  defp preview(value) when is_binary(value), do: value
  defp preview(value), do: Jason.encode!(value)
end
