defmodule Cgc2046.Events.SpeakerInvitation do
  @moduledoc """
  Event 级逐人定向演讲邀请（E-4 #49，邀请 workflow v1.1 定稿）。

  生命周期：Owner/Admin 创建 → invited（逐人 token，库中只存 SHA256 hash，
  明文仅创建响应出现一次）→ Speaker 在着陆页用 token accepted / declined
  （token 一次性：状态机保证只有 invited 可决策；accept 另需登录账号与
  speaker_email 匹配——token + 账号匹配双重校验，邀请设计 §2.2 S2 拍板 #1）
  → 接受后产出分享材料（save_materials，落 WorkflowRun.facts["materials"]）
  → complete_speaking 置 completed（分享完关系结束）；declined = 终态。

  ## ADR-0005 实体自序贯

  单 context 状态机 + DB 全量并发不变量（未终态唯一索引 / token_hash 唯一 /
  条件 UPDATE 抢占），不引擎化编排：SpeakerInvitation 行即 checkpoint；
  WorkflowRun 是镜像 + 材料产出落点（一个邀请 = 一个 run，邀请设计 §2.3，
  run 持 decision/materials 两个人工门控，见 SpeakerInvitationInstantiator）。

  ## 信号（SignalEmitter 事务内 outbox，SignalPublishWorker 异步投递）

  - speaker.accepted / speaker.declined：决策后发布
  - speaker.completed：完成发布，幂等键由 emitter 注入 "<type>:<id>"
    （与邀请设计 §4.2/§4.3 约定逐值一致）
  """

  use Ash.Resource,
    data_layer: AshPostgres.DataLayer,
    extensions: [AshGraphql.Resource, AshAdmin.Resource],
    authorizers: [Ash.Policy.Authorizer],
    domain: Cgc2046.Api

  alias Cgc2046.Repo
  alias Cgc2046.Workflows.{SpeakerInvitationInstantiator, WorkflowRun}

  require Ash.Query
  require Logger

  @status_values [:invited, :accepted, :declined, :completed]
  @non_terminal_statuses [:invited, :accepted]

  @accepted_signal "speaker.accepted"
  @declined_signal "speaker.declined"
  @completed_signal "speaker.completed"

  attributes do
    uuid_primary_key(:id)

    attribute(:workspace_id, :uuid,
      allow_nil?: false,
      public?: true,
      writable?: false,
      description: "所属工作台（租户）ID（= Event 的 workspace_id）"
    )

    attribute(:event_id, :uuid,
      allow_nil?: false,
      public?: true,
      writable?: true,
      description: "目标活动（Event）ID"
    )

    attribute(:speaker_user_id, :uuid,
      public?: true,
      writable?: false,
      description: "接受后绑定的全局账号（拍板 #1：Speaker 必须全局账号，不成为成员）"
    )

    attribute(:speaker_name, :string,
      allow_nil?: false,
      public?: true,
      writable?: true,
      description: "被邀请人姓名"
    )

    attribute(:speaker_email, :string,
      public?: true,
      writable?: true,
      description: "被邀请人邮箱（可空 = 手动转发链接）"
    )

    attribute(:topic, :string,
      public?: true,
      writable?: true,
      description: "分享主题（可选）"
    )

    attribute(:scheduled_at, :utc_datetime,
      public?: true,
      writable?: true,
      description: "分享时间（可选）"
    )

    attribute(:note, :string,
      public?: true,
      writable?: true,
      description: "备注（可选）"
    )

    attribute(:invited_by, :uuid,
      allow_nil?: false,
      public?: true,
      writable?: false,
      description: "发起人（Owner/Admin）"
    )

    attribute(:token_hash, :string,
      allow_nil?: false,
      public?: true,
      writable?: false,
      description: "邀请 token 的 SHA256 哈希（不存明文；GraphQL 不暴露）"
    )

    attribute(:status, :atom,
      allow_nil?: false,
      default: :invited,
      public?: true,
      writable?: false,
      constraints: [one_of: @status_values],
      description: "状态机：invited / accepted / declined / completed"
    )

    attribute(:accepted_by, :uuid, public?: true, writable?: false)
    attribute(:accepted_at, :utc_datetime, public?: true, writable?: false)
    attribute(:declined_at, :utc_datetime, public?: true, writable?: false)
    attribute(:completed_at, :utc_datetime, public?: true, writable?: false)

    attribute(:expires_at, :utc_datetime,
      public?: true,
      writable?: true,
      description: "token 有效期（可空 = 不设过期）"
    )

    attribute(:workflow_run_id, :uuid,
      public?: true,
      writable?: true,
      description:
        "来源邀请 workflow run（材料产出落点，邀请设计 §5.3；仅 create action 内部写入，同 Event.workflow_run_id 先例）"
    )

    create_timestamp(:inserted_at)
    update_timestamp(:updated_at)
  end

  multitenancy do
    strategy(:attribute)
    attribute(:workspace_id)
    global?(true)
  end

  relationships do
    belongs_to(:workspace, Cgc2046.Accounts.Workspace, define_attribute?: false)
    belongs_to(:event, Cgc2046.Events.Event, define_attribute?: false)

    belongs_to(:speaker, Cgc2046.Accounts.User,
      define_attribute?: false,
      source_attribute: :speaker_user_id
    )

    belongs_to(:inviter, Cgc2046.Accounts.User,
      define_attribute?: false,
      source_attribute: :invited_by
    )

    belongs_to(:workflow_run, Cgc2046.Workflows.WorkflowRun, define_attribute?: false)
  end

  identities do
    # 同一 Event 同一 speaker_email 未终态（invited/accepted）不重复邀请；
    # declined/completed 为终态，允许重邀（邀请设计 §4.1 唯一性）。
    identity :unique_event_speaker, [:event_id, :speaker_email] do
      where(expr(not is_nil(speaker_email) and status in ^@non_terminal_statuses))
    end

    identity(:unique_token_hash, [:token_hash])
  end

  actions do
    create :create_invitation do
      description("Owner/Admin 创建邀请：invited + 逐人 token + workflow run")

      accept([
        :event_id,
        :speaker_name,
        :speaker_email,
        :topic,
        :scheduled_at,
        :note,
        :expires_at
      ])

      # GraphQL 入口不注入 tenant（#104 同款）：workspace_id 由入参提供，
      # 内部调用方直接传 tenant 亦可；两者都缺则拒绝。
      argument(:workspace_id, :uuid,
        allow_nil?: true,
        description: "目标工作台 ID（GraphQL 入口必传；tenant 已注入时省略）"
      )

      # token 哈希作为 argument 接收（属性 writable?: false，杜绝经属性通道直写；
      # 明文由 issue/3 生成，库中只落哈希）
      argument(:token_hash, :string,
        allow_nil?: true,
        description: "邀请 token 的 SHA256 哈希（内部入口传；缺失则拒绝）"
      )

      # run 实例化在 before_action（同事务）：失败回滚整个创建，不落孤儿邀请
      # （邀请设计 §2.3 一个邀请 = 一个 run）
      change(fn changeset, _context ->
        Ash.Changeset.before_action(changeset, &prepare_create/1)
      end)
    end

    update :accept_invitation do
      description(
        "Speaker 用 token 接受：invited → accepted（token 一次性；定向邀请需登录账号与 speaker_email 匹配，邀请设计 §2.2 S2 拍板 #1）"
      )

      require_atomic?(false)
      accept([])
      argument(:token, :string, allow_nil?: false)

      change(fn changeset, _context ->
        Ash.Changeset.before_action(changeset, &prepare_accept/1)
      end)

      change(
        {Cgc2046.Changes.SignalEmitter,
         type: @accepted_signal, payload: &__MODULE__.signal_payload/2}
      )

      change(
        after_transaction(fn changeset, result, _context ->
          case result do
            {:ok, invitation} ->
              resume_run(changeset, invitation, "decision", %{"decision" => "accepted"})

            _ ->
              :ok
          end

          result
        end)
      )
    end

    update :decline_invitation do
      description("Speaker 用 token 婉拒：invited → declined（终态，token 一次性）")
      require_atomic?(false)
      accept([])
      argument(:token, :string, allow_nil?: false)

      change(fn changeset, _context ->
        Ash.Changeset.before_action(changeset, &prepare_decline/1)
      end)

      change(
        {Cgc2046.Changes.SignalEmitter,
         type: @declined_signal, payload: &__MODULE__.signal_payload/2}
      )

      change(
        after_transaction(fn changeset, result, _context ->
          case result do
            {:ok, invitation} ->
              fail_run(changeset, invitation)

            _ ->
              :ok
          end

          result
        end)
      )
    end

    update :save_materials do
      description("Speaker 保存分享材料：写 WorkflowRun.facts[materials]（M1 内嵌步骤，v1 不建独立子系统）")
      require_atomic?(false)
      accept([])
      argument(:materials, :map, allow_nil?: false)

      change(fn changeset, _context ->
        Ash.Changeset.before_action(changeset, &prepare_materials/1)
      end)
    end

    update :complete_speaking do
      description("材料产出后完成：accepted → completed（分享完关系结束）")
      require_atomic?(false)
      accept([])

      change(fn changeset, _context ->
        Ash.Changeset.before_action(changeset, &prepare_complete/1)
      end)

      change(
        {Cgc2046.Changes.SignalEmitter,
         type: @completed_signal, payload: &__MODULE__.signal_payload/2}
      )

      change(
        after_transaction(fn changeset, result, _context ->
          case result do
            {:ok, invitation} ->
              resume_run(changeset, invitation, "materials", %{"decision" => "completed"})

            _ ->
              :ok
          end

          result
        end)
      )
    end

    defaults([:read])

    read :get_by_id do
      get_by([:id])
    end
  end

  postgres do
    table("speaker_invitations")
    repo(Cgc2046.Repo)

    identity_wheres_to_sql(
      unique_event_speaker: "speaker_email IS NOT NULL AND status IN ('invited', 'accepted')"
    )
  end

  policies do
    # 创建：Owner/Admin（对齐 Event 管理写动作）或平台管理员
    policy action(:create_invitation) do
      authorize_if(Cgc2046.Policies.WorkspaceActorIsOwnerOrAdmin)
      authorize_if(Cgc2046.Policies.PlatformAdmin)
    end

    # 决策：token 即凭据（token 持有者自助操作，拍板 #1 必须登录），
    # token 有效/未过期/未使用在 action 内校验；accept 的「账号与 speaker_email
    # 匹配」双重校验也在 action 逻辑层（decide/2）——policy 层拿不到邀请行的
    # email 做比较，见 decide/2 注释的不对称决策说明
    policy action([:accept_invitation, :decline_invitation]) do
      authorize_if(actor_present())
    end

    # 材料产出/完成：被邀请人本人自助，Owner/Admin 与平台管理员兜底
    policy action([:save_materials, :complete_speaking]) do
      authorize_if(expr(speaker_user_id == ^actor(:id)))
      authorize_if(Cgc2046.Policies.WorkspaceActorIsOwnerOrAdmin)
      authorize_if(Cgc2046.Policies.PlatformAdmin)
    end

    # 读取：仅 Owner/Admin 或平台管理员（Speaker 走 token 公开卡片查询，不读列表）
    policy action_type(:read) do
      authorize_if(Cgc2046.Policies.WorkspaceActorIsOwnerOrAdmin)
      authorize_if(Cgc2046.Policies.PlatformAdmin)
    end
  end

  graphql do
    type(:speaker_invitation)

    # token 明文哈希不出 GraphQL 面（明文只在创建响应出现一次）
    hide_fields([:token_hash])
  end

  # --- 公开入口：创建并返回一次性明文 token -------------------------------

  @doc """
  Owner/Admin 创建邀请。返回 {:ok, invitation, plain_token}——明文 token 仅此
  一次返回（库中只存 SHA256 哈希，复刻 Mcp.Token 模式）。tenant 必传
  （GraphQL 入口传 input.workspaceId）。
  """
  @spec issue(map(), term(), String.t()) ::
          {:ok, __MODULE__.t(), String.t()} | {:error, term()}
  def issue(attrs, actor, tenant) when is_binary(tenant) do
    token = Base.url_encode64(:crypto.strong_rand_bytes(32), padding: false)
    token_hash = hash_token(token)

    attrs = Map.merge(%{workspace_id: tenant, token_hash: token_hash}, attrs)

    case __MODULE__
         |> Ash.Changeset.for_create(:create_invitation, attrs, tenant: tenant, actor: actor)
         |> Ash.create(tenant: tenant, actor: actor) do
      {:ok, invitation} -> {:ok, invitation, token}
      {:error, error} -> {:error, error}
    end
  end

  @doc "SHA256 哈希（hex，与 Invitation/Mcp.Token 同模式）"
  @spec hash_token(String.t()) :: String.t()
  def hash_token(token) when is_binary(token) and token != "" do
    :crypto.hash(:sha256, token) |> Base.encode16(case: :lower)
  end

  # --- 创建准备 ------------------------------------------------------------

  defp prepare_create(changeset) do
    changeset = normalize_speaker_email(changeset)
    actor = changeset.context[:private][:actor]
    event_id = Ash.Changeset.get_attribute(changeset, :event_id)
    workspace_id = Ash.Changeset.get_argument(changeset, :workspace_id) || changeset.tenant
    token_hash = Ash.Changeset.get_argument(changeset, :token_hash)

    cond do
      is_nil(actor) ->
        Ash.Changeset.add_error(changeset, "create_invitation requires an authenticated actor")

      is_nil(event_id) ->
        Ash.Changeset.add_error(changeset, "event_id is required")

      is_nil(workspace_id) ->
        Ash.Changeset.add_error(changeset, "create_invitation requires a tenant (workspace_id)")

      not (is_binary(token_hash) and token_hash != "") ->
        Ash.Changeset.add_error(changeset, "token_hash is required")

      true ->
        with {:ok, event} <- fetch_event(event_id),
             :ok <- ensure_event_eligible(event, workspace_id),
             :ok <- ensure_no_active_invitation(changeset, event_id),
             :ok <- ensure_speaker_name(changeset),
             {:ok, invitation_id} <- invitation_id(changeset),
             {:ok, run} <-
               SpeakerInvitationInstantiator.start_run(workspace_id, event_id, invitation_id) do
          changeset
          |> Ash.Changeset.set_tenant(workspace_id)
          |> Ash.Changeset.force_change_attribute(:workspace_id, workspace_id)
          |> Ash.Changeset.force_change_attribute(:token_hash, token_hash)
          |> Ash.Changeset.force_change_attribute(:status, :invited)
          |> Ash.Changeset.force_change_attribute(:invited_by, actor.id)
          |> Ash.Changeset.force_change_attribute(:workflow_run_id, run.id)
        else
          {:error, reason} -> add_domain_error(changeset, reason)
        end
    end
  end

  # uuid_primary_key 在 changeset 创建时即生成（attributes[:id]），before_action
  # 内可用作 run input 的实例键（与 INSERT 同事务，失败一并回滚）。
  defp invitation_id(changeset) do
    case Ash.Changeset.get_attribute(changeset, :id) do
      id when is_binary(id) and id != "" -> {:ok, id}
      _ -> {:error, :invitation_id_unavailable}
    end
  end

  defp fetch_event(event_id) do
    case Ash.get(Cgc2046.Events.Event, event_id, authorize?: false) do
      {:ok, %Cgc2046.Events.Event{} = event} -> {:ok, event}
      {:ok, nil} -> {:error, :event_not_found}
      {:error, _} -> {:error, :event_not_found}
    end
  end

  # 状态约束（邀请设计 §4.1）：Event 存在、状态 open/筹备中（draft），且归属本租户
  defp ensure_event_eligible(%{workspace_id: workspace_id, status: status}, workspace_id),
    do: ensure_event_eligible_status(status)

  defp ensure_event_eligible(_, _), do: {:error, :target_tenant_mismatch}

  defp ensure_event_eligible_status(status) when status in [:draft, :open], do: :ok
  defp ensure_event_eligible_status(_status), do: {:error, :event_not_open}

  # 唯一性友好错误（DB 部分唯一索引是硬保证；此处提前给出业务文案）
  defp ensure_no_active_invitation(changeset, event_id) do
    email = Ash.Changeset.get_attribute(changeset, :speaker_email)

    if is_binary(email) and email != "" do
      case __MODULE__
           |> Ash.Query.filter(
             event_id == ^event_id and
               speaker_email == ^email and status in ^@non_terminal_statuses
           )
           |> Ash.read_one(tenant: changeset.tenant, authorize?: false) do
        {:ok, nil} -> :ok
        {:ok, _existing} -> {:error, :duplicate_invitation}
        {:error, reason} -> {:error, {:database, reason}}
      end
    else
      :ok
    end
  end

  # speaker_email 写入前归一（trim + downcase，全空白 → nil）：部分唯一索引
  # 大小写敏感，归一后大小写变体（A@x.com / a@x.com）无法双邀；同时避免空串
  # 触发 `speaker_email IS NOT NULL` 部分索引的裸唯一冲突（空串语义 = 无邮箱）
  defp normalize_speaker_email(changeset) do
    case Ash.Changeset.get_attribute(changeset, :speaker_email) do
      email when is_binary(email) ->
        Ash.Changeset.change_attribute(changeset, :speaker_email, normalize_email(email))

      _ ->
        changeset
    end
  end

  defp ensure_speaker_name(changeset) do
    case Ash.Changeset.get_attribute(changeset, :speaker_name) do
      name when is_binary(name) ->
        if String.trim(name) == "", do: {:error, :speaker_name_required}, else: :ok

      _ ->
        {:error, :speaker_name_required}
    end
  end

  # --- 决策准备（accept/decline 共享 token 校验 + 状态抢占） -----------------

  defp prepare_accept(changeset) do
    decide(changeset, :accepted)
  end

  defp prepare_decline(changeset) do
    decide(changeset, :declined)
  end

  # token 一次性 + 有效/未过期/未使用：条件 UPDATE 抢占（invited → 目标状态，
  # token_hash 复验 + 过期校验），num_rows=0 → 统一拒绝（不区分无效/已用/过期，
  # 错误信息统一即可，任务验收明确不做防枚举）。
  #
  # accept / decline 校验不对称（刻意决策，邀请设计 §2.2 S2 拍板 #1「token +
  # 账号匹配双重校验」；评审 E-4 BLOCKING 修复）：
  # - accept 为双重校验：speaker_email 非空（定向邀请）时仅被邀请账号可接受
  #   （两边 trim + downcase 比较），防任意登录用户持有效链接把自己绑为
  #   speaker_user_id；speaker_email 为空（手动转发链接）时 token 即凭据。
  # - decline 保持 token-only：不绑定账号、无劫持收益，手动转发场景持链接即可
  #   婉拒——与 accept 的不对称是刻意决策，勿"对齐"。
  # 匹配校验必须先于条件 UPDATE 抢占——不匹配的 accept 不得消耗 token。
  defp decide(changeset, to_status) do
    actor = changeset.context[:private][:actor]
    token = Ash.Changeset.get_argument(changeset, :token)
    now = DateTime.utc_now()

    with {:ok, token_hash} <- valid_token(token),
         :ok <- ensure_decision_actor(changeset, to_status, actor),
         {:ok, 1} <- claim_decision(changeset, to_status, actor, now, token_hash) do
      changeset
      |> force_decision_fields(to_status, actor, now)
    else
      {:ok, 0} -> add_domain_error(changeset, :invalid_or_expired_token)
      {:error, reason} -> add_domain_error(changeset, reason)
    end
  end

  # accept 双重校验的账号匹配侧（token 侧由 claim_decision 条件 UPDATE 复验）。
  # speaker_email 自创建归一（trim + downcase），actor.email 为 ci_string，
  # 统一 to_string 后归一比较；账号无邮箱（如小程序手机号用户）恒不匹配。
  defp ensure_decision_actor(_changeset, :declined, _actor), do: :ok

  defp ensure_decision_actor(changeset, :accepted, actor) do
    case normalize_email(changeset.data.speaker_email) do
      nil ->
        :ok

      invited_email ->
        if normalize_email(actor_email(actor)) == invited_email,
          do: :ok,
          else: {:error, :forbidden}
    end
  end

  defp actor_email(%{email: email}) when not is_nil(email), do: to_string(email)
  defp actor_email(_), do: nil

  defp valid_token(token) when is_binary(token) and token != "", do: {:ok, hash_token(token)}
  defp valid_token(_), do: {:error, :invalid_or_expired_token}

  defp claim_decision(changeset, :accepted, actor, now, token_hash) do
    sql = """
    UPDATE speaker_invitations
    SET status = 'accepted', speaker_user_id = $1, accepted_by = $1,
        accepted_at = $2, updated_at = NOW()
    WHERE id = $3 AND status = 'invited' AND token_hash = $4
      AND (expires_at IS NULL OR expires_at > $2)
    """

    query_count(sql, [uuid!(actor.id), now, uuid!(changeset.data.id), token_hash])
  end

  defp claim_decision(changeset, :declined, _actor, now, token_hash) do
    sql = """
    UPDATE speaker_invitations
    SET status = 'declined', declined_at = $1, updated_at = NOW()
    WHERE id = $2 AND status = 'invited' AND token_hash = $3
      AND (expires_at IS NULL OR expires_at > $1)
    """

    query_count(sql, [now, uuid!(changeset.data.id), token_hash])
  end

  defp force_decision_fields(changeset, :accepted, actor, now) do
    changeset
    |> Ash.Changeset.force_change_attribute(:status, :accepted)
    |> Ash.Changeset.force_change_attribute(:speaker_user_id, actor.id)
    |> Ash.Changeset.force_change_attribute(:accepted_by, actor.id)
    |> Ash.Changeset.force_change_attribute(:accepted_at, now)
  end

  defp force_decision_fields(changeset, :declined, _actor, now) do
    changeset
    |> Ash.Changeset.force_change_attribute(:status, :declined)
    |> Ash.Changeset.force_change_attribute(:declined_at, now)
  end

  # --- 材料产出（M1 内嵌步骤） ------------------------------------------------

  defp prepare_materials(changeset) do
    materials = Ash.Changeset.get_argument(changeset, :materials)

    with {:ok, invitation} <- load_record(changeset.data.id),
         :ok <- ensure_accepted(invitation),
         :ok <- ensure_materials_shape(materials),
         {:ok, run} <- fetch_run(invitation),
         :ok <- merge_materials_facts(changeset, run, materials) do
      changeset
    else
      {:error, reason} -> add_domain_error(changeset, reason)
    end
  end

  defp ensure_materials_shape(materials) when is_map(materials) and map_size(materials) > 0,
    do: :ok

  defp ensure_materials_shape(_), do: {:error, :materials_required}

  # 浅合并进 WorkflowRun.facts["materials"]（与 save_step_output 同语义；
  # 内部 authorize?: false——Speaker 非成员，授权由本 action 的 policy 承担）
  defp merge_materials_facts(changeset, run, materials) do
    new_facts =
      Map.update(run.facts || %{}, "materials", materials, fn existing ->
        Map.merge(existing || %{}, materials)
      end)

    case run
         |> Ash.Changeset.for_update(:update_facts_for_mcp, %{facts: new_facts},
           actor: changeset.context[:private][:actor],
           tenant: run.workspace_id,
           authorize?: false
         )
         |> Ash.update(tenant: run.workspace_id, authorize?: false) do
      {:ok, _updated} -> :ok
      {:error, _} -> {:error, :materials_save_failed}
    end
  end

  # --- 完成（M2 内嵌步骤） ----------------------------------------------------

  defp prepare_complete(changeset) do
    now = DateTime.utc_now()

    with {:ok, invitation} <- load_record(changeset.data.id),
         :ok <- ensure_accepted(invitation),
         {:ok, run} <- fetch_run(invitation),
         :ok <- ensure_materials_produced(run),
         {:ok, 1} <- claim_complete(changeset, now) do
      changeset
      |> Ash.Changeset.force_change_attribute(:status, :completed)
      |> Ash.Changeset.force_change_attribute(:completed_at, now)
    else
      {:ok, 0} -> add_domain_error(changeset, :not_accepted)
      {:error, reason} -> add_domain_error(changeset, reason)
    end
  end

  # M1 校验 facts 完整性：完成前必须已有材料产出（邀请设计 §2.2 M1/M2）
  defp ensure_materials_produced(%{facts: facts}) when is_map(facts) do
    case Map.get(facts, "materials") do
      materials when is_map(materials) and map_size(materials) > 0 -> :ok
      _ -> {:error, :materials_required}
    end
  end

  defp ensure_materials_produced(_), do: {:error, :materials_required}

  defp claim_complete(changeset, now) do
    sql = """
    UPDATE speaker_invitations
    SET status = 'completed', completed_at = $1, updated_at = NOW()
    WHERE id = $2 AND status = 'accepted'
    """

    query_count(sql, [now, uuid!(changeset.data.id)])
  end

  # --- run 镜像同步（提交后 best-effort；失败记日志不阻塞业务状态——邀请行
  # 才是 checkpoint，ADR-0005） ----------------------------------------------

  defp resume_run(changeset, invitation, step_key, payload) do
    case Ash.get(WorkflowRun, invitation.workflow_run_id, authorize?: false) do
      {:ok, %WorkflowRun{} = run} when not is_nil(run) ->
        case run
             |> Ash.Changeset.for_update(
               :resume_signal,
               %{"signal_type" => "workflow.#{step_key}", "payload" => payload},
               actor: changeset.context[:private][:actor],
               tenant: run.workspace_id,
               authorize?: false
             )
             |> Ash.update(tenant: run.workspace_id, authorize?: false) do
          {:ok, _} ->
            :ok

          {:error, reason} ->
            Logger.error(
              "speaker_invitation #{invitation.id}: run resume (#{step_key}) failed: #{inspect(reason)}"
            )
        end

      _ ->
        Logger.error("speaker_invitation #{invitation.id}: workflow run missing or unreadable")
    end

    :ok
  rescue
    error ->
      Logger.error(
        "speaker_invitation #{invitation.id}: run resume (#{step_key}) raised: " <>
          Exception.format(:error, error, __STACKTRACE__)
      )
  end

  # declined = run failed（邀请设计 §5.2 状态对应表）
  defp fail_run(_changeset, invitation) do
    case Ash.get(WorkflowRun, invitation.workflow_run_id, authorize?: false) do
      {:ok, %WorkflowRun{} = run} when not is_nil(run) ->
        case run
             |> Ash.Changeset.for_update(:fail, %{}, tenant: run.workspace_id, authorize?: false)
             |> Ash.update(tenant: run.workspace_id, authorize?: false) do
          # PR-G D4：:fail 的 checkpoint 清理已由 Transition cleanup_checkpoint: true
          # 内建（after_transaction，宽松），外部补偿删除（幂等冗余，clean cutover）。
          {:ok, _} ->
            :ok

          {:error, reason} ->
            Logger.error(
              "speaker_invitation #{invitation.id}: run fail transition failed: #{inspect(reason)}"
            )
        end

      _ ->
        Logger.error("speaker_invitation #{invitation.id}: workflow run missing or unreadable")
    end

    :ok
  rescue
    error ->
      Logger.error(
        "speaker_invitation #{invitation.id}: run fail transition raised: " <>
          Exception.format(:error, error, __STACKTRACE__)
      )
  end

  defp fetch_run(%{workflow_run_id: run_id}) when is_binary(run_id) do
    case Ash.get(WorkflowRun, run_id, authorize?: false) do
      {:ok, %WorkflowRun{} = run} -> {:ok, run}
      {:ok, nil} -> {:error, :workflow_run_not_found}
      {:error, _} -> {:error, :workflow_run_not_found}
    end
  end

  defp fetch_run(_), do: {:error, :workflow_run_not_found}

  defp load_record(id) do
    case Ash.get(__MODULE__, id, authorize?: false) do
      {:ok, %__MODULE__{} = invitation} -> {:ok, invitation}
      {:ok, nil} -> {:error, :invitation_not_found}
      {:error, _} -> {:error, :invitation_not_found}
    end
  end

  defp ensure_accepted(%{status: :accepted}), do: :ok
  defp ensure_accepted(_), do: {:error, :not_accepted}

  # --- 信号 payload（SignalEmitter 契约：fn changeset, record -> map，只组装业务键；
  # idempotency_key / workspace_id 由 emitter 统一注入，plan 2026-08-14-003 Q12）——

  def signal_payload(_changeset, record) do
    %{
      "speaker_invitation_id" => record.id,
      "event_id" => record.event_id,
      "speaker_user_id" => record.speaker_user_id,
      "status" => to_string(record.status)
    }
  end

  # --- 通用辅助 ---------------------------------------------------------------

  # 邮箱归一：trim + downcase；全空白/非字符串 → nil（语义 = 无邮箱）
  defp normalize_email(email) when is_binary(email) do
    case email |> String.trim() |> String.downcase() do
      "" -> nil
      normalized -> normalized
    end
  end

  defp normalize_email(_), do: nil

  defp query_count(sql, params) do
    case Repo.query(sql, params) do
      {:ok, %{num_rows: count}} -> {:ok, count}
      {:error, reason} -> {:error, {:database, reason}}
    end
  end

  defp add_domain_error(changeset, reason) do
    Ash.Changeset.add_error(changeset,
      field: :status,
      message: domain_error_message(reason)
    )
  end

  defp domain_error_message(:duplicate_invitation),
    do: "an active invitation for this speaker already exists for this event"

  defp domain_error_message(:invalid_or_expired_token),
    do: "invitation token is invalid, expired or already used"

  defp domain_error_message(:forbidden),
    do: "only the invited speaker account may accept this invitation"

  defp domain_error_message(:event_not_found), do: "event not found"
  defp domain_error_message(:event_not_open), do: "event is closed or cancelled"
  defp domain_error_message(:target_tenant_mismatch), do: "event does not belong to tenant"
  defp domain_error_message(:speaker_name_required), do: "speaker name is required"
  defp domain_error_message(:invitation_id_unavailable), do: "invitation id unavailable"
  defp domain_error_message(:materials_required), do: "sharing materials must be produced first"
  defp domain_error_message(:not_accepted), do: "invitation has not been accepted"
  defp domain_error_message(:workflow_run_not_found), do: "workflow run not found"
  defp domain_error_message(:materials_save_failed), do: "failed to save sharing materials"
  defp domain_error_message(:invitation_not_found), do: "invitation not found"
  defp domain_error_message({:workflow_run_failed, _reason}), do: "failed to start workflow run"
  defp domain_error_message({:database, _reason}), do: "database operation failed"
  defp domain_error_message(reason), do: inspect(reason)

  defp uuid!(value), do: Ecto.UUID.dump!(value)

  admin do
    # #113 ops 面优化：导航分组 + 列表列裁剪（敏感/超大字段不列出）
    resource_group(:events)
    table_columns([:id, :workspace_id, :event_id, :speaker_name, :status, :inserted_at])
  end
end
