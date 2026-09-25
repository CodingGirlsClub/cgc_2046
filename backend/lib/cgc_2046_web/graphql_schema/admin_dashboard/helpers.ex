defmodule Cgc2046Web.GraphqlSchema.AdminDashboard.Helpers do
  @moduledoc """
  Admin Dashboard 域域内 resolver helper：initiative 搜索/投影/状态工厂、
  审计 metadata 白名单投影、reconciliation 过滤与用户面计数；仅本域
  notation 模块使用。四个白名单模块属性（#607 读面可见性真源）同居本文件。
  """

  require Ash.Query

  import Cgc2046Web.GraphqlSchema.Helpers

  # ── #607 治理操作 metadata 读面白名单（唯一真源；加键只改本表）──────────────
  #
  # `admin_action_logs.metadata` 是自由 map 且**含 PII**（admin_promote / owner_reassign /
  # owner_invitation_cancel 的 email；application_reject 的 rejection_reason 自由文本），
  # 故 `/admin/audit` 读面按 action 分组投影，**不整列透传**：
  #
  #   - 只收录显式点名的 action；未收录（含未来新 action）一律 nil——没有默认透传兜底；
  #   - 表内不得出现 PII 键（email 类 / rejection_reason / 任意自由文本）；
  #   - `value_before` / `value_after` 自身也是自由 map（`InitiativeRule.value` 无约束、
  #     `upsertInitiativeRule` 收任意 JSON 对象）→ 同一条标准下沉一层，见
  #     `@rule_value_whitelist`；被省略的键由 `value_*_omitted` 显式标出，不静默截断。
  #
  # 新增可展示 action：键名落在 `admin_action_metadata` 既有字段（rule_key / locked /
  # locked_before / value_before / value_after）内 → 只加表项即可，投影逻辑与前端键序
  # 都不用动；形状不同的 action 需另立 GraphQL object（本表是可见性清单，不是形状引擎）。
  @admin_action_metadata_whitelist %{
    initiative_rule_update: ~w(rule_key locked locked_before value_before value_after)
  }

  # U1 治理写变更投影（offering）：闭集标量 → 每列 value_before / value_after 分列。
  # **不收自由文本**（description / venue / price_tiers 等不进 metadata），不复用
  # rule 族的 JSON 槽——形状不同另立 object（`admin_offering_change_metadata`）。
  # 表是行级可见性清单：只有 admin_event_update / admin_course_update 落表的行才
  # 投影；其余 action（含 launch/close/cancel）投影 nil（默认拒不破）。
  # Course 无 deposit_enabled（Event-only 槽位）→ 该 action 少两列。
  @offering_change_scalars ~w(title visibility capacity pricing_enabled deposit_enabled)
  @admin_offering_change_metadata_whitelist %{
    admin_event_update: @offering_change_scalars,
    admin_course_update: @offering_change_scalars -- ["deposit_enabled"]
  }

  # 二级白名单：rule_key → 该规则 value map 可出面的键（次序 = 界面渲染次序）。
  # 四项规则值都是治理设置（押金开关与金额分 / 年龄门槛 / 成班阈值 / 截止小时数），
  # 本身非敏感；未收录的 rule_key 投影为空 + omitted=true。
  @rule_value_whitelist %{
    "deposit" => ~w(enabled amount_cents refundable_on_check_in),
    "age_gate" => ~w(min_age),
    "min_participants" => ~w(count),
    "deadline_rule" => ~w(hours_before_start)
  }

  # ── Platform Admin Dashboard Phase 5：resolver helpers ─────────────────

  def maybe_initiative_search(query, nil), do: query
  def maybe_initiative_search(query, ""), do: query

  def maybe_initiative_search(query, search) do
    Ash.Query.filter(query, contains(name, ^search) or contains(slug, ^search))
  end

  def load_initiative_admin(initiative, actor, context) do
    case Ash.load(initiative, :rules, actor: actor) do
      {:ok, loaded} ->
        {:ok, admin_initiative_row(loaded)}

      {:error, error} ->
        {:error,
         to_ash_graphql_errors(
           error,
           context,
           :read,
           Cgc2046.Initiatives.Initiative,
           Cgc2046.Initiatives
         )}
    end
  end

  def admin_initiative_row(initiative) do
    %{
      id: initiative.id,
      name: initiative.name,
      slug: initiative.slug,
      hashtag: initiative.hashtag,
      description: initiative.description,
      window_starts_at: initiative.window_starts_at,
      window_ends_at: initiative.window_ends_at,
      status: to_string(initiative.status),
      created_by: initiative.created_by,
      inserted_at: initiative.inserted_at,
      updated_at: initiative.updated_at,
      rules:
        if(is_list(initiative.rules), do: Enum.map(initiative.rules, &admin_rule_row/1), else: [])
    }
  end

  # KTD5：`entity_id` 必须与 `entity_type` 成对。Finding.entity_id 混装 uuid
  # （event/course/enrollment…）与 oban_job 数字串，单用 entity_id 不是自解释的
  # 维数，还会跨实体类型误命中同号行——缺配对直接拒绝（不静默全表扫）。
  # 空串按未提供处理（同各 maybe_* 组合子的 "" 分支）。
  def validate_finding_entity_pair(args) do
    if is_binary(args[:entity_id]) and args[:entity_id] != "" and
         args[:entity_type] in [nil, ""] do
      {:error, [message: "entity_id requires entity_type", code: "invalid_input"]}
    else
      :ok
    end
  end

  def maybe_finding_entity_id(query, nil), do: query
  def maybe_finding_entity_id(query, ""), do: query

  def maybe_finding_entity_id(query, entity_id) do
    Ash.Query.filter(query, entity_id == ^entity_id)
  end

  # #607：治理 metadata → 白名单投影（`admin_action_log.metadata` 字段的唯一出口）。
  # 白名单表在模块顶部（`@admin_action_metadata_whitelist` / `@rule_value_whitelist`）。
  #
  # 返回 nil = 该 action 未收录（**没有默认透传兜底**：未来新 action 不加表即不可见），
  # 或该行形状不完整（见 `projectable_metadata?/1`：行级降级，不打挂整条查询）。
  # 键名取 jsonb 读回的字符串形态（写侧是 atom 键，落库/读回后一律字符串，
  # 实证见 test/cgc_2046/initiatives/rule_propagation_test.exs 的「规则变更审计含值前后」）。
  def admin_action_metadata(%{action: action, metadata: metadata}) when is_map(metadata) do
    case Map.get(@admin_action_metadata_whitelist, action) do
      nil ->
        nil

      keys ->
        # 表即清单：顶层键一律经白名单 Map.take，未收录的键结构上进不来
        projected = Map.take(metadata, keys)

        if projectable_metadata?(projected) do
          rule_key = projected["rule_key"]

          {value_before, before_omitted?} =
            project_rule_value(rule_key, projected["value_before"])

          {value_after, after_omitted?} = project_rule_value(rule_key, projected["value_after"])

          %{
            rule_key: rule_key,
            locked: projected["locked"],
            locked_before: projected["locked_before"],
            # JsonString scalar 出参自行 JSON 编码（`serialize(&Jason.encode!/1)`），故这里
            # 交**原始投影**（OrderedObject | nil）；预先 encode 成字符串会被 scalar 二次
            # 编码，客户端 JSON.parse 一次只能拿到字符串而不是对象。
            value_before_json: value_before,
            value_after_json: value_after,
            value_before_omitted: before_omitted?,
            value_after_omitted: after_omitted?
          }
        else
          nil
        end
    end
  end

  def admin_action_metadata(_log), do: nil

  # U1：offering 治理写 → 闭集标量前后值投影（`adminActionLog.offeringChange` 的唯一出口）。
  # 白名单表在模块顶部 `@admin_offering_change_metadata_whitelist`；键名同样取 jsonb
  # 读回的字符串形态。
  #
  # 返回 nil = 该 action 未收录（launch/close/cancel 等：行本身仍可见，只是没有变更
  # 投影），或该行一条 `*_after` 键都没有（如只改了自由文本属性——写面只为真变更的属性
  # 落键，全空对象会假装「有一条变更」）。
  def admin_offering_change_metadata(%{action: action, metadata: metadata})
      when is_map(metadata) do
    case Map.get(@admin_offering_change_metadata_whitelist, action) do
      nil ->
        nil

      scalars ->
        projected =
          Map.take(metadata, Enum.flat_map(scalars, &["#{&1}_before", "#{&1}_after"]))

        if Enum.any?(scalars, &Map.has_key?(projected, "#{&1}_after")) do
          # 键名 → Absinthe 字段名（atom 在 object 声明处编译期存在；值侧标量门：
          # 非标量一律 nil——闭集字段类型固定，嵌套结构只可能是写面 bug，不透传）
          Map.new(projected, fn {key, value} ->
            {String.to_existing_atom(key), offering_change_scalar(value)}
          end)
        end
    end
  end

  def admin_offering_change_metadata(_log), do: nil

  def offering_change_scalar(value)
      when is_binary(value) or is_number(value) or is_boolean(value) or is_nil(value),
      do: value

  def offering_change_scalar(_value), do: nil

  # #607 形状门：只有带**完整** #607 元数据形状的行才投影，否则整行落 nil（界面显示「—」）。
  # 两条理由：
  #   1. `value_after_json` 是 non_null。历史行没有 value_after——#587 之前的写面只落
  #      `%{initiative_id, rule_key, locked}`（见 origin/main 的 initiative_rule_metadata/2），
  #      线上存量行仍是这个形状。照常投影会让 Absinthe 非空违例把**整条列表查询**打挂
  #      （/admin/audit 整页 loadFailed，一行坏数据毁一页）；审计面要的是行级降级。
  #   2. 「前值 null ⇔ 新建」只有在完整形状下才成立；否则会把「这条没记前值」误报成「新建」，
  #      而审计面**不许撒谎**。
  def projectable_metadata?(m) do
    is_map(m["value_after"]) and
      (is_nil(m["value_before"]) or is_map(m["value_before"])) and
      (is_nil(m["locked_before"]) or is_boolean(m["locked_before"])) and
      is_boolean(m["locked"]) and
      is_binary(m["rule_key"])
  end

  # 规则值 map → 二级白名单子集。返回 {投影, 是否发生省略}：
  #   - 键序 = `@rule_value_whitelist` 次序（Jason.OrderedObject 保序），前端直接按序渲染，
  #     故 web 层不需要再抄一份键名清单；
  #   - **标量门**：键名命中但值是嵌套结构（自由 map / list）也不出面——否则「按白名单投影」
  #     只到键名一层，嵌套内容会原样带出（键名白名单约束不了内容）；
  #   - 第二个返回值让「省略」可见（界面标 …），取证面不静默截断。
  def project_rule_value(rule_key, value) when is_map(value) do
    allowed = Map.get(@rule_value_whitelist, rule_key, [])

    {scalars, nested?} =
      for(key <- allowed, Map.has_key?(value, key), do: {key, Map.get(value, key)})
      |> Enum.split_with(fn {_key, v} ->
        is_boolean(v) or is_number(v) or is_binary(v) or is_nil(v)
      end)

    omitted? = nested? != [] or Enum.any?(value, fn {key, _} -> key not in allowed end)

    {Jason.OrderedObject.new(scalars), omitted?}
  end

  # nil = 该侧无值（:create 的新建侧）；无白名单 rule_key 时也走这里（投影为空）。
  def project_rule_value(_rule_key, _value), do: {nil, false}

  def initiative_mutation_result({:ok, initiative}, _context),
    do: {:ok, %{result: admin_initiative_row(initiative), errors: []}}

  def initiative_mutation_result({:error, error}, context) do
    {:ok,
     %{
       result: nil,
       errors:
         mutation_errors(
           error,
           context,
           :update,
           Cgc2046.Initiatives.Initiative,
           Cgc2046.Initiatives
         )
     }}
  end

  def initiative_status_mutation(action) do
    fn _, %{id: id}, %{context: context} ->
      with_admin(context, fn actor ->
        with {:ok, initiative} <- Ash.get(Cgc2046.Initiatives.Initiative, id, actor: actor) do
          initiative
          |> Ash.Changeset.for_update(action, %{})
          |> Ash.update(actor: actor)
          |> initiative_mutation_result(context)
        else
          {:error, error} ->
            {:ok,
             %{
               result: nil,
               errors:
                 mutation_errors(
                   error,
                   context,
                   action,
                   Cgc2046.Initiatives.Initiative,
                   Cgc2046.Initiatives
                 )
             }}
        end
      end)
    end
  end

  # admin 列表 read 结果 → map_error（统一 :read action；resource/domain 按 query 闭包）
  def admin_result(resource, domain) do
    fn result, context -> map_error(result, context, :read, resource, domain) end
  end

  # listUsers 的 membership 概要（R8）：count aggregate 子查询会被
  # WorkspaceMembership read policy 过滤（BypassReads 已知问题），
  # 故对结果集批量 load 关系后计数（admin 列表量小，可接受）。
  def load_membership_counts({:ok, users}, _context) do
    case Ash.load(users, :workspace_memberships, authorize?: false) do
      {:ok, loaded} ->
        result =
          Enum.map(loaded, fn user ->
            %{
              id: user.id,
              email: user.email,
              display_name: user.display_name,
              is_platform_admin: user.is_platform_admin,
              inserted_at: user.inserted_at,
              workspace_membership_count: length(user.workspace_memberships || [])
            }
          end)

        {:ok, result}

      {:error, error} ->
        {:error, to_ash_graphql_errors(error, nil, :read, Cgc2046.Accounts.User)}
    end
  end

  def load_membership_counts({:error, error}, context) do
    {:error, to_ash_graphql_errors(error, context, :read, Cgc2046.Accounts.User)}
  end

  # 更新 user 的 result → payload（result + errors）
  def map_update_result({:ok, user}, _context, _action) do
    {:ok,
     %{
       id: user.id,
       email: user.email,
       is_platform_admin: user.is_platform_admin,
       errors: []
     }}
  end

  def map_update_result({:error, error}, context, action) do
    {:ok,
     %{
       id: nil,
       email: nil,
       is_platform_admin: nil,
       errors: to_ash_graphql_errors(error, context, action, Cgc2046.Accounts.User)
     }}
  end
end
