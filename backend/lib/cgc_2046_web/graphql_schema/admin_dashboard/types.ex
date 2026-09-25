defmodule Cgc2046Web.GraphqlSchema.AdminDashboard.Types do
  @moduledoc """
  Admin Dashboard 域 GraphQL 类型：admin 面 16 个投影/payload 类型
  （admin_workspace_application 归用户侧留 schema）；仅本域 notation
  模块 import_types 使用。
  """

  use Absinthe.Schema.Notation

  # admin_action_log 的 metadata / offering_change 字段 resolve 调用域内
  # 白名单投影 helper（AdminDashboard.Helpers）
  import Cgc2046Web.GraphqlSchema.AdminDashboard.Helpers

  require Logger

  # ── Platform Admin Dashboard Phase 5：类型（前缀 admin_ 避免与自动类型冲突）──

  object :admin_user do
    field(:id, non_null(:id))
    field(:email, :string)
    field(:display_name, :string)
    field(:is_platform_admin, non_null(:boolean))
    field(:inserted_at, non_null(:datetime))
    # membership 概要（R8）：用户参与的工作台数
    field(:workspace_membership_count, :integer)
  end

  object :admin_workspace do
    field(:id, non_null(:id))
    field(:slug, non_null(:string))
    field(:name, non_null(:string))
    field(:join_policy, non_null(:string))
    field(:sponsorship_enabled, non_null(:boolean))
    field(:inserted_at, non_null(:datetime))
    field(:member_count, non_null(:integer))
  end

  object :admin_tool_call_log do
    field(:id, non_null(:id))
    field(:user_id, non_null(:id))
    field(:tool, non_null(:string))
    field(:result_status, non_null(:string))
    field(:error_message, :string)
    field(:latency_ms, :integer)
    field(:inserted_at, non_null(:datetime))
  end

  object :admin_pending_operation do
    field(:id, non_null(:id))
    field(:user_id, non_null(:id))
    field(:tool, non_null(:string))
    field(:summary, non_null(:string))
    field(:status, non_null(:string))
    field(:inserted_at, non_null(:datetime))
  end

  object :admin_signal_log do
    field(:id, non_null(:id))
    field(:workspace_id, non_null(:id))
    field(:signal_type, non_null(:string))
    field(:inserted_at, non_null(:datetime))
  end

  # #116 R10a：治理操作留痕（actor_id 可空 = 系统/CLI）
  object :admin_action_log do
    field(:id, non_null(:id))
    field(:actor_id, :id)
    field(:action, non_null(:string))
    field(:target_type, non_null(:string))
    field(:target_id, non_null(:id))
    field(:result, non_null(:string))
    field(:inserted_at, non_null(:datetime))

    field(:metadata, :admin_action_metadata,
      description:
        "治理 metadata 白名单投影（#607）；未收录的 action 或形状不完整的历史行（#587 之前）" <>
          "为 null（不整列透传，且行级降级不打挂列表）。raw metadata 仅 /ops/admin（AshAdmin）可见"
    ) do
      # 显式 resolver：默认 resolver 会直接读 `log.metadata` 原始列（透传），必须挡掉
      resolve(fn log, _, _ -> {:ok, admin_action_metadata(log)} end)
    end

    field(:offering_change, :admin_offering_change_metadata,
      description:
        "offering 治理写的变更投影（U1）：admin_event_update / admin_course_update 落表的行才有值，" <>
          "其余 action（含 launch/close/cancel）为 null。闭集标量的前后值分列，不收自由文本"
    ) do
      resolve(fn log, _, _ -> {:ok, admin_offering_change_metadata(log)} end)
    end
  end

  # #607：metadata 白名单投影（非原始 metadata 列）。白名单表见模块顶部
  # `@admin_action_metadata_whitelist` / `@rule_value_whitelist`。
  # `value_*_json` 是 JSON 对象字符串，键序 = 二级白名单次序（前端直接按序渲染）。
  object :admin_action_metadata do
    field(:rule_key, non_null(:string),
      description: "规则键：deposit | age_gate | min_participants | deadline_rule"
    )

    field(:locked, non_null(:boolean), description: "变更后锁定态")

    field(:locked_before, :boolean, description: "变更前锁定态；:create（新建规则）无前值 → null")

    field(:value_before_json, :json_string,
      description: "变更前规则值 JSON 对象字符串；:create 无前值 → null（null ⇔ 新建）"
    )

    field(:value_after_json, non_null(:json_string),
      description: "变更后规则值 JSON 对象字符串（有投影 ⇒ 该侧必在；形状不全的行整行不投影）"
    )

    field(:value_before_omitted, non_null(:boolean),
      description: "true = 变更前 value 含白名单外键，已被省略（界面以 … 标出）"
    )

    field(:value_after_omitted, non_null(:boolean),
      description: "true = 变更后 value 含白名单外键，已被省略（界面以 … 标出）"
    )
  end

  # U1：offering 治理写的变更投影（闭集标量前后值分列，非 rule 族 JSON 槽）。
  # 白名单表见模块顶部 `@admin_offering_change_metadata_whitelist`；Course 行无
  # deposit 两列（该资源无此属性）。全列可空——读者从「哪些列有值」看变更面。
  object :admin_offering_change_metadata do
    description("offering 治理写（admin_event_update / admin_course_update）的变更前后值投影")

    field(:title_before, :string, description: "变更前标题；该属性未变更 → null")
    field(:title_after, :string, description: "变更后标题；该属性未变更 → null")
    field(:visibility_before, :string, description: "变更前可见性（public | workspace）")
    field(:visibility_after, :string, description: "变更后可见性（public | workspace）")
    field(:capacity_before, :integer, description: "变更前报名名额上限；nil 表示不限")
    field(:capacity_after, :integer, description: "变更后报名名额上限；nil 表示不限")
    field(:pricing_enabled_before, :boolean, description: "变更前定价槽位")
    field(:pricing_enabled_after, :boolean, description: "变更后定价槽位")
    field(:deposit_enabled_before, :boolean, description: "变更前押金槽位（Event-only；Course 恒 null）")
    field(:deposit_enabled_after, :boolean, description: "变更后押金槽位（Event-only；Course 恒 null）")
  end

  # E-10 #125：对账扫描发现（rule/entity_type 为 atom 枚举的字符串形态；detail
  # v1 不暴露——对账页列只到 规则/实体/ID/workspace/首次/最近发现）
  object :admin_reconciliation_finding do
    field(:id, non_null(:id))
    field(:rule, non_null(:string))
    field(:entity_type, non_null(:string))
    field(:entity_id, non_null(:string))
    field(:workspace_id, :id)
    field(:first_seen_at, non_null(:datetime))
    field(:last_seen_at, non_null(:datetime))
    field(:inserted_at, non_null(:datetime))
  end

  object :admin_initiative do
    field(:id, non_null(:id))
    field(:name, non_null(:string))
    field(:slug, non_null(:string))
    field(:hashtag, :string)
    field(:description, :string)
    field(:window_starts_at, :datetime)
    field(:window_ends_at, :datetime)
    field(:status, non_null(:string))
    field(:created_by, non_null(:id))
    field(:inserted_at, non_null(:datetime))
    field(:updated_at, non_null(:datetime))

    field :public_stats, :public_initiative do
      resolve(fn initiative, _, _ ->
        case Cgc2046.Initiatives.Public.get_by_slug(initiative.slug) do
          {:ok, stats} -> {:ok, stats}
          _ -> {:ok, nil}
        end
      end)
    end

    field(:rules, non_null(list_of(non_null(:admin_initiative_rule))))

    @desc """
    平台管理员：该 Initiative 的挂载场全量清单（#595 影响预览 / 事后核对）。

    门控继承父 query（listInitiatives / getInitiative 均经 with_admin），
    不加独立 gate；不分页、不过滤 visibility，理由见
    Cgc2046.Initiatives.Mounts 的 moduledoc。

    附挂读面：可空。加载失败返回 nil（并落日志），不阻断规则的详情主读——
    同 public_stats 先例（附挂信息不阻断主读）；前端据此区分「空清单」与
    「清单加载失败」两种状态，不把失败伪装成 0 场。
    """
    field :mounted_events, list_of(non_null(:admin_initiative_mounted_event)) do
      resolve(fn initiative, _, _ ->
        case Cgc2046.Initiatives.Mounts.list(initiative.id) do
          {:ok, rows} ->
            {:ok, rows}

          {:error, reason} ->
            Logger.error("[admin_initiative.mountedEvents] load failed: #{inspect(reason)}")
            {:ok, nil}
        end
      end)
    end
  end

  object :admin_initiative_mounted_event do
    @desc "Event / Workspace id 与 Initiative 真值一致；status ∈ draft | open | closed | cancelled"
    field(:id, non_null(:id))
    field(:initiative_id, non_null(:id))
    field(:slug, non_null(:string))
    field(:title, non_null(:string))
    field(:status, non_null(:string))
    field(:starts_at, :datetime)
    field(:registration_deadline, :datetime)
    @desc "结构化场地 JSON 串（country/province/city/district；nil = 线上或未定）"
    field(:venue, :json_string)
    field(:workspace_id, non_null(:id))
    field(:workspace_name, non_null(:string))
    @desc "展示投影 events.confirmed_count（权威计数在名额账本，可能滞后一拍）"
    field(:confirmed_count, non_null(:integer))
    field(:pricing_enabled, non_null(:boolean))
    field(:deposit_enabled, non_null(:boolean))
    field(:deposit_amount_cents, :integer)
    field(:min_age, :integer)
    field(:min_participants, :integer)
  end

  object :admin_initiative_rule do
    field(:id, non_null(:id))
    field(:initiative_id, non_null(:id))
    field(:key, non_null(:string))
    field(:value_json, non_null(:string))
    field(:locked, non_null(:boolean))
    field(:inserted_at, non_null(:datetime))
    field(:updated_at, non_null(:datetime))
  end

  input_object :admin_initiative_input do
    field(:name, :string)
    field(:slug, :string)
    field(:hashtag, :string)
    field(:description, :string)
    field(:window_starts_at, :datetime)
    field(:window_ends_at, :datetime)
  end

  object :admin_initiative_payload do
    field(:result, :admin_initiative)
    field(:errors, list_of(:mutation_error))
  end

  # id / is_platform_admin 可空：update 失败时承载错误 payload（errors 非空、业务字段为 nil），
  # 与 admin 面其它 mutation 的 payload 式错误通道一致。
  object :admin_user_payload do
    field(:id, :id)
    field(:email, :string)
    field(:is_platform_admin, :boolean)
    field(:errors, list_of(:mutation_error))
  end
end
