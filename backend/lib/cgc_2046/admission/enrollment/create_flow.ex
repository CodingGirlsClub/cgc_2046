defmodule Cgc2046.Admission.Enrollment.CreateFlow do
  @moduledoc """
  create_enrollment 流（#851 架构深化 C8：自 Enrollment resource 抽离）。

  收编 create 链全部分支：msgSecCheck 内容安全外呼（锁前、不持锁）、
  exactly_one_target / lock_qualification_target（FOR UPDATE）/ eligible_target
  （FOR SHARE）目标校验、resolve_tenant、prepare_policy（request / open =
  reserve_capacity / invite_only 再 consume_invite_quota）、put_tier_selection、
  put_age_confirmation、核销码重试分配（put_check_in_code）。

  与 Cgc2046.Admission.Enrollment resource 的分工：resource 保留 DSL 壳、
  policy、对外端口（anchor / active_enrollment / lock_for_order 等）、错误表
  （#241 契约单源）、多流共享 helper（lock_qualification_target /
  reserve_capacity / target_table / deposit_columns / @enrollment_policy_atoms
  经访问器导出）与 error_handler（handle_create_error/2）——本模块只持有
  create 专用逻辑，可脱离 2,000 行 DSL 文件直接测。

  用法（resource DSL 直引，行为与抽离前逐字节一致）：

      Ash.Changeset.before_action(changeset, &Cgc2046.Admission.Enrollment.CreateFlow.prepare_create/1)
  """

  alias Cgc2046.Admission.Enrollment
  alias Cgc2046.Integrations.Wechat.Client

  # reason 内容安全平台判定白名单（替代 String.to_atom，杜绝未知字符串造原子）
  @content_check_platforms %{"wechat" => :wechat, "tt" => :tt, "xhs" => :xhs}

  # #510 年龄门槛条款版本（单源）：min_age 非空的目标活动报名须显式确认，
  # 确认事实（age_confirmed_at）与当时条款版本（terms_version）同事务留痕。
  # 版本随代码部署演进——改条款语义时更新本值，存量留痕不回写。
  @terms_version "2026-09-participation"

  @doc false
  def prepare_create(changeset) do
    event_id = Ash.Changeset.get_attribute(changeset, :event_id)
    course_id = Ash.Changeset.get_attribute(changeset, :course_id)
    actor = changeset.context[:private][:actor]

    # 内容检查在 with 链首位（advisor09 F2）：msgSecCheck 外呼在
    # eligible_target 的 FOR SHARE 行锁获取之前执行，外呼不持锁。
    with :ok <- check_content(changeset, actor),
         {:ok, target_kind, target_id} <- exactly_one_target(event_id, course_id),
         :ok <- Enrollment.lock_qualification_target(event_id),
         {:ok, target} <- eligible_target(target_kind, target_id, actor),
         {:ok, tenant} <- resolve_tenant(changeset.tenant, target.workspace_id),
         {:ok, attrs} <- prepare_policy(changeset, target_kind, target_id, target, tenant),
         {:ok, attrs} <- put_tier_selection(changeset, target, attrs),
         {:ok, attrs} <- put_age_confirmation(changeset, target, attrs),
         {:ok, attrs} <- put_check_in_code(attrs, target_kind, target_id) do
      changeset =
        Enum.reduce(attrs, changeset, fn {key, value}, cs ->
          Ash.Changeset.force_change_attribute(cs, key, value)
        end)

      # 目标 enrollment_policy 已由 eligible_target 加载（FOR SHARE），存入 context
      # 供 SignalEmitter payload fn 组装信号使用，避免提交后再查一次（#5）
      Ash.Changeset.put_context(changeset, :enrollment_policy, target.enrollment_policy)
    else
      {:error, reason} -> Enrollment.add_domain_error(changeset, reason)
    end
  end

  # ── 内容安全（plan 2026-08-18-009 P2 + advisor09 F1-F3）────────────

  # submission_payload.reason 自由文本过内容安全检查。外呼在 with 链首位执行
  # （目标校验 / FOR SHARE 行锁获取之前，F2：外呼不持锁）。
  # - reason 缺失 → 放行（无可查内容）
  # - reason 存在但非 binary / 超 2500 字节 / 无效 UTF-8 → 拒绝（F3：检查产物 =
  #   落库产物，服务端前置校验，禁止静默截断）
  # - 违规（v2 result.suggest risky/review）→ {:error, :content_rejected}
  #   （fail-closed，内容不落库）
  # - infra 故障 → fail-open 放行（Client.content_check 内部已记 telemetry）
  # - 无 wechat identity（tt/xhs 单平台 / web 无 identity）→ pass-through 零外呼
  defp check_content(changeset, actor) do
    payload = Ash.Changeset.get_attribute(changeset, :submission_payload) || %{}
    reason = Map.get(payload, "reason") || Map.get(payload, :reason)

    cond do
      is_nil(reason) ->
        :ok

      not valid_reason?(reason) ->
        {:error, :content_rejected}

      true ->
        check_content_with_identity(actor, reason)
    end
  end

  defp valid_reason?(reason) when is_binary(reason),
    do: byte_size(reason) <= 2500 and String.valid?(reason)

  defp valid_reason?(_), do: false

  # msgSecCheck v2 需要 openid——从 user_identities 取 wechat uid
  # （order.ex:794 同款 SQL 先例；platform 判定查询复用，一次取 provider+uid）。
  # 有 wechat openid → wechat 检查；无 wechat identity（tt/xhs 单平台 / web 无
  # identity）/ 查询失败 → 放行（pass-through 语义，RISKS 记录——v2 无法在无
  # openid 下执行检查，与 tt/xhs 零外呼语义等价）。
  defp check_content_with_identity(actor, reason) do
    case actor_identities(actor) do
      {:ok, identities} ->
        case Map.get(identities, :wechat) do
          nil -> :ok
          openid -> run_wechat_check(reason, openid)
        end

      :error ->
        :ok
    end
  end

  defp run_wechat_check(reason, openid) do
    case Client.content_check(:wechat, reason, openid) do
      {:ok, _} -> :ok
      {:error, :content_rejected} -> {:error, :content_rejected}
    end
  end

  defp actor_identities(nil), do: {:ok, %{}}

  defp actor_identities(actor) do
    case Cgc2046.Repo.query(
           "SELECT DISTINCT provider, uid FROM user_identities WHERE user_id = $1",
           [Cgc2046.Repo.uuid!(actor.id)]
         ) do
      {:ok, %{rows: rows}} ->
        identities =
          rows
          |> Enum.map(fn [provider, uid] -> {@content_check_platforms[provider], uid} end)
          |> Enum.reject(fn {provider, _uid} -> is_nil(provider) end)
          |> Map.new()

        {:ok, identities}

      {:error, _} ->
        :error
    end
  end

  defp prepare_policy(changeset, _kind, _target_id, %{enrollment_policy: :request}, tenant) do
    deadline =
      Ash.Changeset.get_attribute(changeset, :approval_deadline) ||
        DateTime.add(DateTime.utc_now(), Cgc2046.ApprovalDeadline.default_timeout_days(), :day)

    {:ok, %{workspace_id: tenant, status: :pending, approval_deadline: deadline}}
  end

  # 收费目标：open/invite_only 占位后进 payment_pending（支付完成才 confirmed，
  # ADR-0007 占位→限时支付）；免费目标直接 confirmed（R4 现状不变）。
  # request 无论收费与否都先 pending（审批通过后 prepare_confirm 分叉）。
  defp prepare_policy(_changeset, kind, target_id, %{enrollment_policy: :open} = target, tenant) do
    with {:ok, sequence} <- Enrollment.reserve_capacity(kind, target_id) do
      {:ok,
       %{
         workspace_id: tenant,
         status: Enrollment.auto_confirm_status(target),
         capacity_seq: sequence
       }}
    end
  end

  defp prepare_policy(
         changeset,
         kind,
         target_id,
         %{enrollment_policy: :invite_only} = target,
         tenant
       ) do
    invite_code = Ash.Changeset.get_argument(changeset, :invite_code)

    with true <- (is_binary(invite_code) and invite_code != "") || {:error, :invite_code_required},
         {:ok, sequence} <- Enrollment.reserve_capacity(kind, target_id),
         {:ok, batch_id} <- consume_invite_quota(tenant, kind, target_id, invite_code) do
      {:ok,
       %{
         workspace_id: tenant,
         status: Enrollment.auto_confirm_status(target),
         capacity_seq: sequence,
         invite_batch_id: batch_id
       }}
    end
  end

  # 收费报名的档位选择（KTD9/R2）：tier_id 必填且当前可售，存 submission_payload
  # 供下单链快照（U5 resolve_tier）；免费目标忽略 tier_id（R4）。
  defp put_tier_selection(changeset, %{pricing_enabled: true, price_tiers: tiers}, attrs) do
    tier_id = Ash.Changeset.get_argument(changeset, :tier_id)

    with true <- (is_binary(tier_id) and tier_id != "") || {:error, :tier_id_required},
         {:ok, tier} <- Cgc2046.Offering.PriceTier.find(tiers, tier_id),
         true <-
           Cgc2046.Offering.PriceTier.available?(tier, DateTime.utc_now()) ||
             {:error, :tier_not_available} do
      {:ok,
       Map.put(
         attrs,
         :submission_payload,
         merge_payload_key(changeset, Map.get(attrs, :submission_payload), "tier_id", tier_id)
       )}
    end
  end

  defp put_tier_selection(_changeset, _target, attrs), do: {:ok, attrs}

  # ── 年龄门槛（#510）──────────────────────────────────────────────────────
  # min_age 非空的目标活动（仅 events 有该列；course 恒 nil 走兜底）必须显式
  # 确认：argument :age_confirmed 非 true 即拒（fail-closed，MCP 不传同拒）。
  # 确认事实与条款版本同事务落列——审计可回答「何时同意的哪一版条款」。
  # 判据是 is_integer（min_age 有 CHECK min:1，无 0/负值分支）。
  defp put_age_confirmation(changeset, %{min_age: min_age}, attrs) when is_integer(min_age) do
    if Ash.Changeset.get_argument(changeset, :age_confirmed) == true do
      {:ok,
       attrs
       |> Map.put(:age_confirmed_at, DateTime.utc_now())
       |> Map.put(:terms_version, @terms_version)}
    else
      {:error, :age_confirmation_required}
    end
  end

  defp put_age_confirmation(_changeset, _target, attrs), do: {:ok, attrs}

  # submission_payload 累加写点（tier_id，KTD9）：优先取链上已累积值、回落客户端
  # 提交原值，只覆盖本键——后写者不吞前写者，也不丢报名表单自带字段
  # （reason / targetTitle）。
  defp merge_payload_key(changeset, payload, key, value) do
    (payload || Ash.Changeset.get_attribute(changeset, :submission_payload) || %{})
    |> Map.put(key, value)
  end

  # ── 核销码（U4/KTD5）────────────────────────────────────────────────────
  # Event 报名在 create 单写点生成同场唯一 6 位码（迁入 confirmed 的 5 个写点
  # 逐路径挂生成必漏——见计划 KTD5）；course 报名不生成。生成器共享自 Cgc2046.RandomCode（无偏
  # rejection sampling，保留前导零）；同场存在性查询避碰至多
  # @check_in_code_max_attempts 次，(event_id, check_in_code) 唯一索引兜底，
  # 兜底冲突由 Enrollment.handle_create_error/2 映射为可重试业务错误
  # （unique_conflict?/1 判据复用，错误文案不匹配；约束名判据留在 resource 的
  # check_in_code_conflict?/1）。
  @check_in_code_max_attempts 5

  defp put_check_in_code(attrs, :event, event_id) do
    case allocate_check_in_code(event_id, @check_in_code_max_attempts) do
      {:ok, code} -> {:ok, Map.put(attrs, :check_in_code, code)}
      :error -> {:error, :check_in_code_exhausted}
    end
  end

  defp put_check_in_code(attrs, :course, _course_id), do: {:ok, attrs}

  # 测试注入的 deterministic 码必须同样参与避碰（否则耗尽用例退化为撞索引）。
  defp allocate_check_in_code(_event_id, 0), do: :error

  defp allocate_check_in_code(event_id, attempts_left) do
    code = Cgc2046.RandomCode.generate()

    if check_in_code_taken?(event_id, code) do
      allocate_check_in_code(event_id, attempts_left - 1)
    else
      {:ok, code}
    end
  end

  defp check_in_code_taken?(event_id, code) do
    %{rows: rows} =
      Cgc2046.Repo.query!(
        "SELECT 1 FROM enrollments WHERE event_id = $1 AND check_in_code = $2 LIMIT 1",
        [Cgc2046.Repo.uuid!(event_id), code]
      )

    rows != []
  end

  # ── 目标解析 / 资格（自 resource 共享 helper 段迁入，仅 create 流使用）────

  defp exactly_one_target(event_id, nil) when is_binary(event_id), do: {:ok, :event, event_id}
  defp exactly_one_target(nil, course_id) when is_binary(course_id), do: {:ok, :course, course_id}
  defp exactly_one_target(_, _), do: {:error, :exactly_one_target_required}

  defp eligible_target(kind, id, actor) do
    table = Enrollment.target_table(kind)
    actor_id = if actor, do: Cgc2046.Repo.uuid!(actor.id), else: nil

    # G1（E-5 #50 安全洞修复）：公开报名只对 `open + visibility=public` 活动；
    # workspace-only 活动仅目标 workspace 成员可报（成员路径 D2，工作台详情页
    # 入口走同一 createEnrollment）。非成员/匿名对 workspace-only 报名 → 本函数
    # 返回 :target_not_open_or_registration_closed（not_found 语义，与匿名读一致，
    # 不泄露存在性）。行为变化：此前非成员可经 API 报名 workspace-only，属漏洞。
    # 押金开关（KTD2）：仅 events 表有，courses 分支补 false（Order.load_target_row/2
    # 的 deposit_column 同款写法）。
    # min_age 列（#510）：仅 events 表有，courses 补 NULL 保持列数一致（同
    # deposit_columns 形状）。
    sql = """
    SELECT workspace_id, enrollment_policy, pricing_enabled, price_tiers#{Enrollment.deposit_columns(table)}#{min_age_columns(table)}
    FROM #{table}
    WHERE id = $1 AND status = 'open'
      AND (registration_deadline IS NULL OR registration_deadline > clock_timestamp())
      AND (
        visibility = 'public'
        OR EXISTS (
          SELECT 1 FROM workspace_memberships wm
          WHERE wm.workspace_id = #{table}.workspace_id
            AND wm.user_id = $2
        )
      )
    FOR SHARE
    """

    case Cgc2046.Repo.query(sql, [Cgc2046.Repo.uuid!(id), actor_id]) do
      {:ok,
       %{
         rows: [
           [
             workspace_id,
             policy,
             pricing_enabled,
             price_tiers,
             deposit_enabled,
             min_age
           ]
         ]
       }} ->
        case Map.get(Enrollment.enrollment_policy_atoms(), policy) do
          nil ->
            {:error, {:unknown_enrollment_policy, policy}}

          enrollment_policy ->
            {:ok,
             %{
               workspace_id: Ecto.UUID.load!(workspace_id),
               enrollment_policy: enrollment_policy,
               pricing_enabled: pricing_enabled,
               price_tiers: price_tiers || [],
               deposit_enabled: deposit_enabled,
               min_age: min_age
             }}
        end

      {:ok, %{rows: []}} ->
        {:error, :target_not_open_or_registration_closed}

      {:error, reason} ->
        {:error, {:database, reason}}
    end
  end

  defp consume_invite_quota(workspace_id, kind, target_id, invite_code) do
    target_column = if kind == :event, do: "event_id", else: "course_id"

    sql = """
    UPDATE invite_batches
    SET remaining_quota = remaining_quota - 1, updated_at = NOW()
    WHERE workspace_id = $1 AND #{target_column} = $2 AND invite_code = $3
      AND status = 'active' AND remaining_quota > 0
      AND (expires_at IS NULL OR expires_at > NOW())
    RETURNING id
    """

    case Cgc2046.Repo.query(sql, [
           Cgc2046.Repo.uuid!(workspace_id),
           Cgc2046.Repo.uuid!(target_id),
           invite_code
         ]) do
      {:ok, %{rows: [[id]]}} -> {:ok, Ecto.UUID.load!(id)}
      {:ok, %{rows: []}} -> {:error, :invite_quota_unavailable}
      {:error, reason} -> {:error, {:database, reason}}
    end
  end

  # GraphQL 入口不注入 tenant（nil 时从目标派生）；显式传错 tenant 仍拒绝（防跨 workspace 越权）
  defp resolve_tenant(nil, workspace_id), do: {:ok, workspace_id}
  defp resolve_tenant(tenant, tenant), do: {:ok, tenant}
  defp resolve_tenant(_, _), do: {:error, :target_tenant_mismatch}

  # 年龄一列（#510）：仅 events 表有；courses 补 NULL。
  defp min_age_columns("events"), do: ", min_age"
  defp min_age_columns(_table), do: ", NULL"
end
