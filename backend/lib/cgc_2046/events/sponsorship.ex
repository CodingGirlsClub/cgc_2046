defmodule Cgc2046.Events.Sponsorship do
  @moduledoc """
  赞助资源（E-3 #48）：两级赞助（Event 级单场 / Workspace 级长期）。

  审批两段式与报名 Enrollment 同构（ADR-0005 实体自序贯，POC §3.3/§3.4 PASS）：
  意向提交 → 同步落 DB pending 停住（不生效权益）→ 审批信号
  （sponsorship.approved/rejected）→ A3 激活（pending→active，同事务物化履约账本）
  或 rejected（reason 落审计字段）。F7：审批超时 expired 终态 + 可重提
  （重提走新行，部分唯一索引只锁 pending/active 窗口）。

  并发不变量全部由 DB 承担（报名同款纪律）：
  - 「同一 sponsor 同一目标未终态不重复」：两个部分唯一索引；
  - 「同一目标同一独占档位至多一个 active」：激活条件 UPDATE 的 NOT EXISTS
    守卫（同 enrollment 名额扣减的原子 UPDATE ... WHERE 模式）；
  - 审批幂等：claim 条件 UPDATE 状态守卫，重复 approved → already_processed。

  所有写都位于 Ash action 事务内（before_action 内的条件 UPDATE 与交付行
  insert_all 与实体更新同事务，后续失败回滚已执行写）。
  """

  use Ash.Resource,
    data_layer: AshPostgres.DataLayer,
    extensions: [AshGraphql.Resource, AshAdmin.Resource],
    authorizers: [Ash.Policy.Authorizer],
    domain: Cgc2046.Events

  alias Cgc2046.ApprovalClaim
  alias Cgc2046.Repo

  alias Cgc2046.Events.SponsorshipTier
  alias Cgc2046.Accounts.Workspace
  require Ash.Query

  @submitted_signal "sponsorship.submitted"
  @approved_signal "sponsorship.approved"
  @rejected_signal "sponsorship.rejected"
  @active_signal "sponsorship.active"

  attributes do
    uuid_primary_key(:id)

    attribute(:level, :atom,
      allow_nil?: false,
      public?: true,
      writable?: true,
      constraints: [one_of: [:event, :workspace]],
      description: "赞助级别：event 单场 / workspace 长期"
    )

    attribute(:workspace_id, :uuid,
      allow_nil?: false,
      public?: true,
      writable?: false,
      description: "所属工作台（租户）：Event 级 = 活动所属工作台；Workspace 级 = 目标工作台"
    )

    attribute(:event_id, :uuid, public?: true, writable?: true)

    attribute(:sponsor_user_id, :uuid,
      allow_nil?: false,
      public?: true,
      writable?: true,
      description: "赞助方（全局账号，非成员）"
    )

    attribute(:workflow_run_id, :uuid, public?: true, writable?: true)

    attribute(:tier_id, :uuid,
      public?: true,
      writable?: true,
      description: "意向档位（指向目标 sponsorship_tiers 配置内的档位 id，可选）"
    )

    attribute(:tier_name, :string,
      public?: true,
      writable?: true,
      description: "档位展示名冗余（审批/展示用）"
    )

    attribute(:status, :atom,
      allow_nil?: false,
      default: :pending,
      public?: true,
      writable?: false,
      constraints: [one_of: [:pending, :active, :rejected, :expired, :ended]]
    )

    attribute(:amount, :integer,
      public?: true,
      writable?: true,
      description: "意向金额（元，v1 仅登记不收款；可空）"
    )

    attribute(:company_name, :string,
      allow_nil?: false,
      public?: true,
      writable?: true,
      description: "赞助方公司/展示名"
    )

    attribute(:contact_email, :string,
      allow_nil?: false,
      public?: true,
      writable?: true,
      description: "联系邮箱（必填）"
    )

    attribute(:contact_phone, :string, public?: true, writable?: true)
    attribute(:message, :string, public?: true, writable?: true, description: "备注/合作意向")

    attribute(:approved_by, :uuid, public?: true, writable?: false)
    attribute(:approved_at, :utc_datetime, public?: true, writable?: false)
    attribute(:rejection_reason, :string, public?: true, writable?: false)
    attribute(:approval_deadline, :utc_datetime, public?: true, writable?: true)
    attribute(:expired_at, :utc_datetime, public?: true, writable?: false)
    attribute(:started_at, :utc_datetime, public?: true, writable?: false)
    attribute(:ended_at, :utc_datetime, public?: true, writable?: false)

    create_timestamp(:inserted_at)
    update_timestamp(:updated_at)
  end

  multitenancy do
    strategy(:attribute)
    attribute(:workspace_id)
    global?(true)
  end

  calculations do
    calculate(:target_title, :string,
      public?: true,
      load: [:workspace_id, :event_id, :level],
      calculation: fn sponsorships, _opts ->
        titles =
          sponsorships
          |> Enum.group_by(& &1.workspace_id)
          |> Enum.reduce(%{}, fn {workspace_id, rows}, acc ->
            ids =
              rows
              |> Enum.map(& &1.event_id)
              |> Enum.reject(&is_nil/1)
              |> Enum.uniq()

            ids_by_kind = if ids == [], do: %{}, else: %{event: ids}

            Map.merge(
              acc,
              Cgc2046.Offering.fetch_titles_by_ids(ids_by_kind, workspace_id)
            )
          end)

        workspace_names =
          sponsorships
          |> Enum.map(& &1.workspace_id)
          |> Enum.uniq()
          |> case do
            [] ->
              %{}

            workspace_ids ->
              Workspace
              |> Ash.Query.filter(id in ^workspace_ids)
              |> Ash.read!(authorize?: false)
              |> Map.new(&{&1.id, &1.name})
          end

        Enum.map(sponsorships, fn sponsorship ->
          case {sponsorship.level, sponsorship.event_id} do
            {level, _event_id} when level in [:workspace, "workspace"] ->
              Map.get(workspace_names, sponsorship.workspace_id, "工作台")

            {_level, event_id} when is_binary(event_id) ->
              Map.get(titles, event_id, "赞助目标")

            _ ->
              "赞助目标"
          end
        end)
      end
    )
  end

  relationships do
    belongs_to(:workspace, Cgc2046.Accounts.Workspace, define_attribute?: false)
    belongs_to(:event, Cgc2046.Events.Event, define_attribute?: false)

    belongs_to(:sponsor, Cgc2046.Accounts.User,
      define_attribute?: false,
      source_attribute: :sponsor_user_id
    )

    belongs_to(:workflow_run, Cgc2046.Workflows.WorkflowRun, define_attribute?: false)

    belongs_to(:approver, Cgc2046.Accounts.User,
      define_attribute?: false,
      source_attribute: :approved_by
    )

    has_many(:deliveries, Cgc2046.Events.SponsorshipDelivery,
      destination_attribute: :sponsorship_id,
      public?: true
    )
  end

  identities do
    identity :unique_event_sponsor, [:level, :event_id, :sponsor_user_id] do
      where(expr(level == :event and status in [:pending, :active]))
    end

    identity :unique_workspace_sponsor, [:level, :workspace_id, :sponsor_user_id] do
      where(expr(level == :workspace and status in [:pending, :active]))
    end
  end

  actions do
    defaults([:read])

    read :my_sponsorships do
      description("当前用户跨工作台的赞助意向")
      filter(expr(sponsor_user_id == ^actor(:id)))
      pagination(keyset?: true)
    end

    create :create_sponsorship do
      description("提交赞助意向：校验后创建 pending（不生效权益，等审批）")

      # workflow_run_id 保留列与关系供二期引擎化（v1 实体自序贯不创建 run），
      # 不接受客户端写入（评审 A1）
      accept([
        :level,
        :event_id,
        :sponsor_user_id,
        :tier_id,
        :amount,
        :company_name,
        :contact_email,
        :contact_phone,
        :message
      ])

      # GraphQL 入口不注入 tenant：Workspace 级赞助的目标工作台由本参数提供
      # （Event 级从 event 派生 tenant，报名同款）。
      argument(:target_workspace_id, :uuid, allow_nil?: true)

      change(fn changeset, _context ->
        Ash.Changeset.before_action(changeset, &prepare_create/1)
      end)

      # 信号经 SignalEmitter 事务内 outbox 入队（plan 2026-08-14-003 Q6）。
      change(
        {Cgc2046.Changes.SignalEmitter,
         type: @submitted_signal, payload: &__MODULE__.signal_payload/2}
      )
    end

    update :approve_sponsorship do
      description("审批通过：pending → active，同事务物化履约账本（SponsorshipDelivery）")
      require_atomic?(false)
      accept([])

      change(fn changeset, _context ->
        Ash.Changeset.before_action(changeset, &prepare_approve/1)
      end)

      # 审批通过：先发 approved，再发 active（按声明顺序入队；active 幂等键由
      # emitter 注入，赞助 doc §2.2/§4.2 约定逐值一致）。
      change(
        {Cgc2046.Changes.SignalEmitter,
         type: @approved_signal, payload: &__MODULE__.signal_payload/2}
      )

      change(
        {Cgc2046.Changes.SignalEmitter,
         type: @active_signal, payload: &__MODULE__.signal_payload/2}
      )
    end

    update :reject_sponsorship do
      description("审批拒绝：pending → rejected，rejection_reason 落审计字段")
      require_atomic?(false)
      accept([])
      argument(:rejection_reason, :string, allow_nil?: true)

      change(fn changeset, _context ->
        Ash.Changeset.before_action(changeset, &prepare_reject/1)
      end)

      change(
        {Cgc2046.Changes.SignalEmitter,
         type: @rejected_signal, payload: &__MODULE__.signal_payload/2}
      )
    end

    update :expire do
      description("内部扫描把过期 pending 赞助转 expired（F7，可重提）")
      require_atomic?(false)
      accept([])

      change(fn changeset, _context ->
        Ash.Changeset.before_action(changeset, &prepare_expire/1)
      end)
    end

    update :end do
      description("内部：event.ended 订阅把 active Event 级赞助转 ended（Workspace 级不受影响）")
      require_atomic?(false)
      accept([])

      change(fn changeset, _context ->
        Ash.Changeset.before_action(changeset, &prepare_end/1)
      end)
    end

    read :get_by_id do
      get_by([:id])
    end
  end

  postgres do
    table("sponsorships")
    repo(Cgc2046.Repo)

    identity_wheres_to_sql(
      unique_event_sponsor: "level = 'event' AND status IN ('pending', 'active')",
      unique_workspace_sponsor: "level = 'workspace' AND status IN ('pending', 'active')"
    )
  end

  policies do
    policy action(:create_sponsorship) do
      authorize_if(expr(sponsor_user_id == ^actor(:id)))
    end

    policy action(:my_sponsorships) do
      authorize_if(expr(sponsor_user_id == ^actor(:id)))
    end

    # 拍板 #4：Event 级 = 目标工作台 Owner/Admin；Workspace 级 = 仅 Owner

    # （长期承诺加严；平台 Admin 备案二期，不参与审批）。
    policy action([:approve_sponsorship, :reject_sponsorship]) do
      authorize_if(Cgc2046.Policies.SponsorshipApprover)
    end

    policy action_type(:read) do
      authorize_if(expr(sponsor_user_id == ^actor(:id)))
      authorize_if(Cgc2046.Policies.WorkspaceActorIsOwnerOrAdmin)
      authorize_if(Cgc2046.Policies.PlatformAdmin)
    end
  end

  graphql do
    type(:sponsorship)

    queries do
      list(:sponsorships, :read)
      list(:my_sponsorships, :my_sponsorships)
      read_one(:get_sponsorship, :get_by_id)
    end

    mutations do
      create(:create_sponsorship, :create_sponsorship)
      update(:approve_sponsorship, :approve_sponsorship)
      update(:reject_sponsorship, :reject_sponsorship)
    end
  end

  # ── 意向提交（P1：同步创建 pending 停住）──────────────────────────────────

  defp prepare_create(changeset) do
    level = Ash.Changeset.get_attribute(changeset, :level)
    event_id = Ash.Changeset.get_attribute(changeset, :event_id)
    sponsor_id = Ash.Changeset.get_attribute(changeset, :sponsor_user_id)
    tier_id = Ash.Changeset.get_attribute(changeset, :tier_id)
    target_workspace_id = Ash.Changeset.get_argument(changeset, :target_workspace_id)

    with {:ok, target_kind, target_id} <- target_by_level(level, event_id, target_workspace_id),
         {:ok, target} <- eligible_target(target_kind, target_id),
         {:ok, tenant} <- resolve_tenant(changeset.tenant, target.workspace_id),
         {:ok, tier} <- resolve_tier(tier_id, target),
         :ok <- uniqueness_precheck(level, target_kind, target_id, sponsor_id) do
      # F7 审批超时由服务端固定生成（评审 NEEDS_CHANGES 修复：不开放客户端
      # 自设 deadline，防止绕过过期 SLA / 48h 提醒）；默认期限单点 =
      # ApprovalDeadline.default_timeout_days()。
      deadline =
        DateTime.add(DateTime.utc_now(), Cgc2046.ApprovalDeadline.default_timeout_days(), :day)

      changeset =
        changeset
        |> Ash.Changeset.force_change_attribute(:workspace_id, tenant)
        |> Ash.Changeset.force_change_attribute(:status, :pending)
        |> Ash.Changeset.force_change_attribute(:approval_deadline, deadline)
        |> Ash.Changeset.force_change_attribute(:tier_name, tier && tier["name"])

      # Event 级落 event_id；Workspace 级目标即 tenant，event_id 恒空——
      # 无论客户端传什么，workspace 级强制清空（写入面收紧，防脏行：
      # level=:workspace + event_id≠nil 会让锚定/展示面读到误导数据，
      # 且会触发 sponsorships_level_target_consistency CHECK 以 500 形态炸出）。
      changeset =
        if target_kind == :event do
          Ash.Changeset.force_change_attribute(changeset, :event_id, target_id)
        else
          Ash.Changeset.force_change_attribute(changeset, :event_id, nil)
        end

      changeset
    else
      {:error, reason} -> add_domain_error(changeset, reason)
    end
  end

  defp target_by_level(:event, event_id, _target_workspace_id) when is_binary(event_id),
    do: {:ok, :event, event_id}

  defp target_by_level(:event, _event_id, _target_workspace_id),
    do: {:error, :event_id_required}

  defp target_by_level(:workspace, _event_id, target_workspace_id)
       when is_binary(target_workspace_id),
       do: {:ok, :workspace, target_workspace_id}

  defp target_by_level(:workspace, _event_id, _target_workspace_id),
    do: {:error, :target_workspace_required}

  defp target_by_level(level, _event_id, _target_workspace_id) when is_atom(level),
    do: {:error, :unknown_level}

  defp target_by_level(_level, _event_id, _target_workspace_id),
    do: {:error, :level_required}

  # 目标存在 + 赞助开放 + 未过赞助截止（FOR SHARE 锁，同报名 eligible_target）
  defp eligible_target(:event, id) do
    # v1 赞助入口挂公开宿主页：仅 public 活动可收赞助意向（评审 A5；
    # 私发邀请赞助二期再解耦）
    case Repo.query(
           "SELECT workspace_id FROM events WHERE id = $1 AND sponsorship_enabled = TRUE " <>
             "AND visibility = 'public' AND status = 'open' " <>
             "AND (sponsorship_deadline IS NULL OR sponsorship_deadline > NOW()) FOR SHARE",
           [Repo.uuid!(id)]
         ) do
      {:ok, %{rows: [[workspace_id]]}} ->
        {:ok, %{workspace_id: Ecto.UUID.load!(workspace_id), tiers: load_tiers(:event, id)}}

      {:ok, %{rows: []}} ->
        {:error, :sponsorship_not_open}

      {:error, reason} ->
        {:error, {:database, reason}}
    end
  end

  defp eligible_target(:workspace, id) do
    case Repo.query(
           "SELECT id FROM workspaces WHERE id = $1 AND sponsorship_enabled = TRUE " <>
             "AND (sponsorship_deadline IS NULL OR sponsorship_deadline > NOW()) FOR SHARE",
           [Repo.uuid!(id)]
         ) do
      {:ok, %{rows: [[workspace_id]]}} ->
        {:ok, %{workspace_id: Ecto.UUID.load!(workspace_id), tiers: load_tiers(:workspace, id)}}

      {:ok, %{rows: []}} ->
        {:error, :sponsorship_not_open}

      {:error, reason} ->
        {:error, {:database, reason}}
    end
  end

  defp load_tiers(:event, id) do
    {:ok, %{rows: [[tiers]]}} =
      Repo.query("SELECT sponsorship_tiers FROM events WHERE id = $1", [Repo.uuid!(id)])

    tiers
  end

  defp load_tiers(:workspace, id) do
    {:ok, %{rows: [[tiers]]}} =
      Repo.query("SELECT sponsorship_tiers FROM workspaces WHERE id = $1", [Repo.uuid!(id)])

    tiers
  end

  defp resolve_tier(nil, _target), do: {:ok, nil}
  defp resolve_tier(tier_id, %{tiers: tiers}), do: SponsorshipTier.find(tiers, tier_id)

  # 唯一性预检（友好报错）；并发兜底由部分唯一索引承担（identity conflict）
  defp uniqueness_precheck(level, target_kind, target_id, sponsor_id) do
    sql = """
    SELECT 1 FROM sponsorships
    WHERE level = $1 AND #{target_column(target_kind)} = $2
      AND sponsor_user_id = $3 AND status IN ('pending', 'active')
    LIMIT 1
    """

    case Repo.query(sql, [to_string(level), Repo.uuid!(target_id), Repo.uuid!(sponsor_id)]) do
      {:ok, %{rows: []}} -> :ok
      {:ok, %{rows: [[1]]}} -> {:error, :already_sponsoring}
      {:error, reason} -> {:error, {:database, reason}}
    end
  end

  defp target_column(:event), do: "event_id"
  defp target_column(:workspace), do: "workspace_id"

  # ── 审批通过（A3：pending → active + 物化履约账本）────────────────────────

  defp prepare_approve(changeset) do
    now = DateTime.utc_now()
    actor = changeset.context[:private][:actor]

    with {:ok, target_kind, target_id} <- target_from_record(changeset.data),
         {:ok, tier} <- target_tier(changeset.data) do
      tier_id = changeset.data.tier_id

      exclusive? = SponsorshipTier.exclusive?(tier)

      # 独占位并发串行化：两个并发激活更新的是不同 sponsorship 行（无行锁竞争），
      # READ COMMITTED 下 NOT EXISTS 子查询看不到未提交的赢家 → 双重预定逃逸。
      # 事务级 advisory lock 按 (target, tier) 键串行化独占档位激活：后到者在
      # 赢家提交后以新快照重跑守卫 → num_rows=0 → exclusive_slot_taken。
      # 锁在 claim 前由调用方取得（锁序 lock→claim，plan 2026-08-17-001 D6）。
      if exclusive? do
        slot_key = "sponsorship_slot:#{target_kind}:#{target_id}:#{tier_id}"
        # PR-I D5：内联锁收进 Repo.acquire_lock!（默认 hashtext 键域不变）；新增
        # lock_timeout 5s + 死锁/超时友好错误映射（此前死锁裸抛 Postgres 错误）。
        Repo.acquire_lock!(slot_key)
      end

      # 原子抢占收编 Cgc2046.ApprovalClaim（plan 2026-08-17-001 D4/D6）：状态守卫 +
      # approval_deadline 守卫（= not_expired?/2 SQL 端口）+ 目标仍开放 EXISTS + 独占位
      # NOT EXISTS（经 extra_where 传入，占位符由 claim 统一重编号，42P18 纪律单点化）。
      # num_rows=0 的冲突判定（读回消歧 approval_conflict）留本资源（D3）。
      case ApprovalClaim.claim(changeset.data,
             table: :sponsorships,
             from: [:pending],
             set: [
               status: "active",
               approved_by: {:arg, :actor_id},
               approved_at: {:arg, :now},
               started_at: {:arg, :now},
               updated_at: {:sql, "NOW()"}
             ],
             deadline: {:approval_deadline, :future},
             extra_where:
               approval_extra_where(
                 target_kind,
                 target_id,
                 changeset.data.id,
                 tier_id,
                 exclusive?,
                 now
               ),
             actor_id: Repo.uuid!(actor.id),
             now: now
           ) do
        {:ok, _returned} ->
          _delivery_count =
            materialize_deliveries(changeset.data.id, changeset.data.workspace_id, tier)

          changeset
          |> Ash.Changeset.force_change_attribute(:status, :active)
          |> Ash.Changeset.force_change_attribute(:approved_by, actor.id)
          |> Ash.Changeset.force_change_attribute(:approved_at, now)
          |> Ash.Changeset.force_change_attribute(:started_at, now)

        {:error, :not_claimed} ->
          add_domain_error(changeset, approval_conflict(changeset.data, now))

        {:error, {:database, _} = reason} ->
          add_domain_error(changeset, reason)
      end
    else
      {:error, reason} -> add_domain_error(changeset, reason)
    end
  end

  # 条件 UPDATE 的附加守卫（extra_where 片段）：目标仍开放 + 独占位 NOT EXISTS。
  # 复用报名名额扣减的原子 UPDATE ... WHERE 模式——独占位双重预定在 DB 层拒绝。
  # 片段占位符从 $1 起内部编号（$1 target_id / $2 now / $3 id / $4 level / $5 tier_id），
  # ApprovalClaim 统一重编号到全语句连续编号（消灭现手工连续编号，42P18 纪律单点化）。
  defp approval_extra_where(target_kind, target_id, record_id, tier_id, exclusive?, now) do
    exclusive_guard =
      if exclusive? do
        """
        AND NOT EXISTS (
          SELECT 1 FROM sponsorships s2
          WHERE s2.status = 'active' AND s2.id <> $3
            AND s2.level = $4 AND s2.tier_id = $5
            AND #{target_column(target_kind)} = $1
        )
        """
      else
        ""
      end

    params =
      [Repo.uuid!(target_id), now] ++
        if(exclusive?,
          do: [Repo.uuid!(record_id), to_string(target_kind), Repo.uuid!(tier_id)],
          else: []
        )

    {"""
     EXISTS (
       SELECT 1 FROM #{target_table(target_kind)} t
       WHERE t.id = $1 AND t.sponsorship_enabled = TRUE
         AND (t.sponsorship_deadline IS NULL OR t.sponsorship_deadline > $2)
     )
     #{exclusive_guard}
     """, params}
  end

  # num_rows=0 时的冲突判定：读回状态区分「已处理」「已过期」「独占位被占」「目标关闭」。
  defp approval_conflict(record, now) do
    case Repo.query("SELECT status FROM sponsorships WHERE id = $1", [Repo.uuid!(record.id)]) do
      {:ok, %{rows: [[status]]}} ->
        cond do
          status != "pending" -> :already_processed
          deadline_passed?(record, now) -> :approval_deadline_passed
          exclusive_conflict?(record) -> :exclusive_slot_taken
          true -> :target_sponsorship_closed
        end

      {:error, reason} ->
        {:database, reason}
    end
  end

  defp deadline_passed?(record, now) do
    record.approval_deadline != nil and DateTime.compare(record.approval_deadline, now) == :lt
  end

  defp exclusive_conflict?(record) do
    case target_tier(record) do
      {:ok, tier} ->
        SponsorshipTier.exclusive?(tier) and
          active_conflict_exists?(record)

      {:error, _reason} ->
        false
    end
  end

  defp active_conflict_exists?(record) do
    {target_kind, target_id} =
      case {record.level, record.event_id} do
        {:event, event_id} when is_binary(event_id) -> {:event, event_id}
        {:workspace, _} -> {:workspace, record.workspace_id}
      end

    case Repo.query(
           """
           SELECT 1 FROM sponsorships
           WHERE level = $1 AND #{target_column(target_kind)} = $2
             AND tier_id = $3 AND status = 'active' AND id <> $4
           LIMIT 1
           """,
           [
             to_string(record.level),
             Repo.uuid!(target_id),
             Repo.uuid!(record.tier_id),
             Repo.uuid!(record.id)
           ]
         ) do
      {:ok, %{rows: [[1]]}} -> true
      {:ok, %{rows: []}} -> false
      {:error, _reason} -> false
    end
  end

  # 物化履约账本（D5）：激活同事务从 tier.benefits 建交付行（行数 = 权益项数），
  # 独占位标记随档位复制到交付行。欠交付 = fulfilled_at 为空的自然可见。
  defp materialize_deliveries(_sponsorship_id, _workspace_id, nil), do: :ok

  defp materialize_deliveries(sponsorship_id, workspace_id, tier) do
    now = DateTime.utc_now()
    exclusive = SponsorshipTier.exclusive?(tier)

    rows =
      tier
      |> SponsorshipTier.benefits()
      |> Enum.map(fn benefit ->
        %{
          id: Repo.uuid!(Ecto.UUID.generate()),
          workspace_id: Repo.uuid!(workspace_id),
          sponsorship_id: Repo.uuid!(sponsorship_id),
          benefit: benefit,
          due_date: nil,
          fulfilled_at: nil,
          proof_note: nil,
          exclusive: exclusive,
          inserted_at: now,
          updated_at: now
        }
      end)

    {count, _} = Repo.insert_all("sponsorship_deliveries", rows)
    count
  end

  # 审批目标档位：读目标 sponsorship_tiers 配置（审批时点快照）。
  # tier_id 可选（拍板 #3）：无档位 → {:ok, nil}（无独占守卫、无交付行物化）。
  defp target_tier(%{tier_id: nil}), do: {:ok, nil}

  defp target_tier(record) do
    {target_kind, target_id} =
      case {record.level, record.event_id} do
        {:event, event_id} when is_binary(event_id) -> {:event, event_id}
        {:workspace, _} -> {:workspace, record.workspace_id}
      end

    SponsorshipTier.find(load_tiers(target_kind, target_id), record.tier_id)
  end

  # ── 审批拒绝（pending → rejected，reason 落审计）──────────────────────────

  defp prepare_reject(changeset) do
    now = DateTime.utc_now()
    actor = changeset.context[:private][:actor]
    reason = Ash.Changeset.get_argument(changeset, :rejection_reason)

    # 原子抢占收编 Cgc2046.ApprovalClaim（plan 2026-08-17-001 D4）：pending → rejected，
    # approval_deadline 守卫 = not_expired?/2 SQL 端口。num_rows=0 冲突判定（读回消歧
    # reject_conflict）留本资源（D3）。
    case ApprovalClaim.claim(changeset.data,
           table: :sponsorships,
           from: [:pending],
           set: [
             status: "rejected",
             approved_by: {:arg, :actor_id},
             approved_at: {:arg, :now},
             rejection_reason: {:arg, :rejection_reason},
             updated_at: {:sql, "NOW()"}
           ],
           deadline: {:approval_deadline, :future},
           actor_id: Repo.uuid!(actor.id),
           now: now,
           rejection_reason: reason
         ) do
      {:ok, _returned} ->
        changeset
        |> Ash.Changeset.force_change_attribute(:status, :rejected)
        |> Ash.Changeset.force_change_attribute(:approved_by, actor.id)
        |> Ash.Changeset.force_change_attribute(:approved_at, now)
        |> Ash.Changeset.force_change_attribute(:rejection_reason, reason)

      {:error, :not_claimed} ->
        # 区分「已处理」与「审批超时」（expiry worker 未拍时误报修复，评审 A4）
        add_domain_error(changeset, reject_conflict(changeset.data, now))

      {:error, {:database, _} = reason} ->
        add_domain_error(changeset, reason)
    end
  end

  defp reject_conflict(record, now) do
    case Repo.query("SELECT status FROM sponsorships WHERE id = $1", [Repo.uuid!(record.id)]) do
      {:ok, %{rows: [[status]]}} ->
        cond do
          status != "pending" -> :already_processed
          deadline_passed?(record, now) -> :approval_deadline_passed
          true -> :already_processed
        end

      {:error, reason} ->
        {:database, reason}
    end
  end

  # ── F7 过期（pending + deadline 过点 → expired，可重提）───────────────────

  defp prepare_expire(changeset) do
    now = DateTime.utc_now()

    # 原子抢占收编 Cgc2046.ApprovalClaim（plan 2026-08-17-001 D4）：:passed 方向守卫
    # （approval_deadline IS NOT NULL AND < now）= ApprovalDeadline.overdue?/2 SQL 端口。
    case ApprovalClaim.claim(changeset.data,
           table: :sponsorships,
           from: [:pending],
           set: [
             status: "expired",
             expired_at: {:arg, :now},
             updated_at: {:sql, "NOW()"}
           ],
           deadline: {:approval_deadline, :passed},
           now: now
         ) do
      {:ok, _returned} ->
        changeset
        |> Ash.Changeset.force_change_attribute(:status, :expired)
        |> Ash.Changeset.force_change_attribute(:expired_at, now)

      {:error, :not_claimed} ->
        add_domain_error(changeset, :not_expired_pending)

      {:error, {:database, _} = reason} ->
        add_domain_error(changeset, reason)
    end
  end

  # ── event.ended（active Event 级 → ended；Workspace 级不受影响）────────────

  defp prepare_end(changeset) do
    now = DateTime.utc_now()

    # 原子抢占收编 Cgc2046.ApprovalClaim（plan 2026-08-17-001 D4）：level 守卫经
    # extra_where（event.ended 只结束 Event 级，Workspace 级不受影响）。
    case ApprovalClaim.claim(changeset.data,
           table: :sponsorships,
           from: [:active],
           set: [
             status: "ended",
             ended_at: {:arg, :now},
             updated_at: {:sql, "NOW()"}
           ],
           extra_where: {"level = $1", ["event"]},
           now: now
         ) do
      {:ok, _returned} ->
        changeset
        |> Ash.Changeset.force_change_attribute(:status, :ended)
        |> Ash.Changeset.force_change_attribute(:ended_at, now)

      {:error, :not_claimed} ->
        add_domain_error(changeset, :not_active_event_sponsorship)

      {:error, {:database, _} = reason} ->
        add_domain_error(changeset, reason)
    end
  end

  # ── 目标解析 / 租户 ────────────────────────────────────────────────────────

  defp target_from_record(%{level: :event, event_id: event_id}) when is_binary(event_id),
    do: {:ok, :event, event_id}

  defp target_from_record(%{level: :workspace, workspace_id: workspace_id})
       when is_binary(workspace_id),
       do: {:ok, :workspace, workspace_id}

  defp target_from_record(_record), do: {:error, :exactly_one_target_required}

  defp resolve_tenant(nil, workspace_id), do: {:ok, workspace_id}
  defp resolve_tenant(tenant, tenant), do: {:ok, tenant}
  defp resolve_tenant(_, _), do: {:error, :target_tenant_mismatch}

  defp target_table(:event), do: "events"
  defp target_table(:workspace), do: "workspaces"

  # ── 信号 payload（SignalEmitter 契约：fn changeset, record -> map，只组装业务键；
  # idempotency_key / workspace_id 由 emitter 统一注入，plan 2026-08-14-003 Q12）──
  #
  # A5（赞助 doc §2.2/§4.2）：生产订阅方（权益展示/通知，SignalIdempotency 去重）
  # 由 E-2 #47 订阅方收尾接入——v1 本资源只负责按约定生产信号（评审 A1 注释澄清）。
  def signal_payload(_changeset, sponsorship) do
    %{
      "sponsorship_id" => sponsorship.id,
      "event_id" => sponsorship.event_id,
      "sponsor_user_id" => sponsorship.sponsor_user_id,
      "status" => to_string(sponsorship.status),
      "level" => to_string(sponsorship.level),
      "company_name" => sponsorship.company_name,
      "amount" => sponsorship.amount,
      "tier_id" => sponsorship.tier_id,
      "tier_name" => sponsorship.tier_name
    }
  end

  # ── 错误文案 ───────────────────────────────────────────────────────────────

  defp add_domain_error(changeset, reason) do
    Ash.Changeset.add_error(
      changeset,
      Cgc2046.Errors.BusinessError.exception(
        message: domain_error_message(reason),
        code: domain_error_code(reason),
        fields: [:status]
      )
    )
  end

  defp domain_error_message(:event_id_required),
    do: "event_id is required for event-level sponsorship"

  defp domain_error_message(:target_workspace_required),
    do: "target_workspace_id is required for workspace-level sponsorship"

  defp domain_error_message(:level_required), do: "level is required (event or workspace)"
  defp domain_error_message(:unknown_level), do: "level must be event or workspace"

  defp domain_error_message(:sponsorship_not_open),
    do: "target does not accept sponsorships or sponsorship deadline passed"

  defp domain_error_message(:target_tenant_mismatch), do: "target does not belong to tenant"
  defp domain_error_message(:tier_not_found), do: "sponsorship tier does not exist on target"

  defp domain_error_message(:already_sponsoring),
    do: "sponsor already has a non-terminal sponsorship for this target"

  defp domain_error_message(:already_processed), do: "sponsorship has already been processed"

  defp domain_error_message(:approval_deadline_passed),
    do: "sponsorship approval deadline has passed (expired)"

  defp domain_error_message(:exclusive_slot_taken),
    do: "exclusive sponsorship slot is already taken by another active sponsorship"

  defp domain_error_message(:target_sponsorship_closed),
    do: "target no longer accepts sponsorships"

  defp domain_error_message(:not_expired_pending),
    do: "sponsorship is not an expired pending record"

  defp domain_error_message(:not_active_event_sponsorship),
    do: "sponsorship is not an active event-level record"

  defp domain_error_message(:exactly_one_target_required), do: "sponsorship has no valid target"

  defp domain_error_message({:database, _reason}), do: "database operation failed"
  defp domain_error_message(reason), do: inspect(reason)

  defp domain_error_code({:database, _reason}), do: "database_error"
  defp domain_error_code(:event_id_required), do: "sponsorship_event_id_required"
  defp domain_error_code(:target_workspace_required), do: "sponsorship_target_workspace_required"
  defp domain_error_code(:level_required), do: "sponsorship_level_required"
  defp domain_error_code(:unknown_level), do: "sponsorship_unknown_level"
  defp domain_error_code(:sponsorship_not_open), do: "sponsorship_sponsorship_not_open"
  defp domain_error_code(:target_tenant_mismatch), do: "sponsorship_target_tenant_mismatch"
  defp domain_error_code(:tier_not_found), do: "sponsorship_tier_not_found"
  defp domain_error_code(:already_sponsoring), do: "sponsorship_already_sponsoring"
  defp domain_error_code(:already_processed), do: "sponsorship_already_processed"

  defp domain_error_code(:approval_deadline_passed),
    do: "sponsorship_approval_deadline_passed"

  defp domain_error_code(:exclusive_slot_taken), do: "sponsorship_exclusive_slot_taken"
  defp domain_error_code(:target_sponsorship_closed), do: "sponsorship_target_sponsorship_closed"
  defp domain_error_code(:not_expired_pending), do: "sponsorship_not_expired_pending"

  defp domain_error_code(:not_active_event_sponsorship),
    do: "sponsorship_not_active_event_sponsorship"

  defp domain_error_code(:exactly_one_target_required),
    do: "sponsorship_exactly_one_target_required"

  defp domain_error_code(reason) when is_atom(reason),
    do: "sponsorship_" <> Atom.to_string(reason)

  defp domain_error_code({kind, _}) when is_atom(kind),
    do: "sponsorship_" <> Atom.to_string(kind)

  defp domain_error_code(_), do: "sponsorship_unknown"

  admin do
    resource_group(:events)

    table_columns([
      :id,
      :workspace_id,
      :event_id,
      :sponsor_user_id,
      :level,
      :status,
      :tier_name,
      :company_name,
      :inserted_at
    ])
  end
end
