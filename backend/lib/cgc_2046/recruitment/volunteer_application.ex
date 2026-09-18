defmodule Cgc2046.Recruitment.VolunteerApplication do
  @moduledoc """
  志愿者申请（R8；KTD2 policy 边界）。

  约束「同一批次同一申请人限一份申请」（AE2）：identity `[:user_id, :cohort_id]`，
  同批换职位也拒（职位不是唯一键的一部分）；rejected/canceled 后本批结束、
  下一批可换职位再申——换批次即换行，不重置语义。`user_id` 由 actor 强制
  写入（accept 通道不接受、不可伪造）。

  职位为**代码枚举**（`event_moderator | tutor | coach`，KTD4），不建职位表；
  职责/要求文案走 i18n（U7/U10）。

  段位状态机 `submitted → interview → training → assigned`（任一审核段可
  `rejected`〔必带原因〕/ `canceled`）在本文件的段位流转 update actions 落地，
  并骑既有 Workflow 引擎（U3；KTD1：申请行是状态权威，WorkflowRun 是执行镜像）：

  - create → before_action 同事务 start run（首门控 waiting）+ 提交确认信号；
    任一步失败回滚整个创建，不落孤儿 run；
  - 初审/群面/训练营完成·分配 → 段位流转 action：初始状态守卫（原子 CAS）+
    `SignalEmitter` 事务内 outbox + `after_transaction` 对 run `resume_signal`；
  - rejected → run `fail`；canceled → run `cancel`。run 镜像同步 best-effort：
    失败记日志不阻塞业务状态（申请行才是 checkpoint）；
  - 初审豁免（R8/AE11）：已 `assigned` 者再申新批次，create 同事务直入
    interview 段（首段门控已放行、豁免事实落 run facts，不发初审结果通知）。
    申请行无豁免备注列，豁免原因与来源经 run `facts["initial_review"]` 回溯。

  约束执行（R8）：同批一份由 identity 承载；批次 `closed` 不放行新申请
  （在途申请照常走完）；段位流转限 Owner/Admin ∪ platform_admin（KTD2）。

  ## 段位流转信号（U4 通知的数据面）

  `volunteer_application.submitted | interview | training | assigned |
  rejected | canceled`——信号在进入该段位/终态的事务内入队，payload 带
  申请 id / 申请人 / 批次 / 职位 / 状态 / 拒绝原因。
  """

  use Ash.Resource,
    data_layer: AshPostgres.DataLayer,
    extensions: [AshGraphql.Resource],
    authorizers: [Ash.Policy.Authorizer],
    domain: Cgc2046.Recruitment

  alias Cgc2046.Errors.BusinessError
  alias Cgc2046.Recruitment.{ApplicationWorkflowInstantiator, RecruitmentCohort}
  alias Cgc2046.Workflows.SignalEmitter

  require Ash.Query
  require Logger

  import Ash.Expr, only: [expr: 1]

  # 段位（R12 状态图）与职位（R8，KTD4；与 RBAC 角色同名不同义）
  @statuses [:submitted, :interview, :training, :assigned, :rejected, :canceled]
  @positions [:event_moderator, :tutor, :coach]

  # 可被拒绝/取消的审核段（R12 状态图：assigned 是终态，离场撤权走 RBAC，
  # 不由本资源承载）
  @review_stages [:submitted, :interview, :training]

  # 段位信号（R14 阶段通知表的数据面；提交确认在 create，其余在对应流转 action）
  @submitted_signal "volunteer_application.submitted"
  @interview_signal "volunteer_application.interview"
  @training_signal "volunteer_application.training"
  @assigned_signal "volunteer_application.assigned"
  @rejected_signal "volunteer_application.rejected"
  @canceled_signal "volunteer_application.canceled"

  attributes do
    uuid_primary_key(:id)

    attribute(:workspace_id, :uuid,
      allow_nil?: false,
      public?: true,
      writable?: false,
      description: "所属工作台（租户）ID（KTD2：所有倡导活动都在 2046 台）"
    )

    attribute(:user_id, :uuid,
      allow_nil?: false,
      public?: true,
      writable?: false,
      description: "申请人 ID（创建时由 actor 强制填充，不可代他人提交）"
    )

    attribute(:cohort_id, :uuid,
      allow_nil?: false,
      public?: true,
      writable?: true,
      description: "申请批次 ID"
    )

    attribute(:position, :atom,
      allow_nil?: false,
      public?: true,
      writable?: true,
      constraints: [one_of: @positions],
      description: "职位：event_moderator | tutor | coach（枚举，不建表）"
    )

    attribute(:city, :string,
      public?: true,
      writable?: true,
      description: "申请城市（Tutor 可远程）"
    )

    attribute(:heard_about_us, :string,
      public?: true,
      writable?: true,
      description: "如何得知我们"
    )

    attribute(:has_internal_referrer, :boolean,
      allow_nil?: false,
      default: false,
      public?: true,
      writable?: true,
      description: "是否有内部推荐人"
    )

    attribute(:message, :string,
      public?: true,
      writable?: true,
      description: "留言（选填）"
    )

    attribute(:status, :atom,
      allow_nil?: false,
      default: :submitted,
      public?: true,
      writable?: false,
      constraints: [one_of: @statuses],
      description: "段位（R12 状态图；流转 action 在 U3）"
    )

    attribute(:rejection_reason, :string,
      public?: true,
      writable?: true,
      description: "拒绝原因（状态转 rejected 时必填；写入在 U3 的流转 action）"
    )

    attribute(:assigned_event_id, :uuid,
      public?: true,
      writable?: true,
      description: "分配的场次 ID（可空；项目分配时写入）"
    )

    attribute(:assignment_note, :string,
      public?: true,
      writable?: true,
      description: "分配备注（如 Tutor 的课程任务；不建任务实体）"
    )

    attribute(:assigned_at, :utc_datetime,
      public?: true,
      writable?: true,
      description: "分配时间"
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
    belongs_to(:user, Cgc2046.Accounts.User, define_attribute?: false)

    belongs_to(:cohort, Cgc2046.Recruitment.RecruitmentCohort,
      source_attribute: :cohort_id,
      destination_attribute: :id,
      define_attribute?: false
    )

    belongs_to(:assigned_event, Cgc2046.Events.Event,
      source_attribute: :assigned_event_id,
      destination_attribute: :id,
      define_attribute?: false
    )
  end

  identities do
    # 同批一份（AE2）：换职位不重置；换批次即换行
    identity(:unique_per_cohort, [:user_id, :cohort_id])
  end

  actions do
    defaults([:read])

    create :create do
      accept([
        :cohort_id,
        :position,
        :city,
        :heard_about_us,
        :has_internal_referrer,
        :message
      ])

      # 撞同批唯一索引 → 稳定业务 code（AE2）
      error_handler({__MODULE__, :handle_write_error, []})

      # 同事务：批次约束校验 + 豁免判定 + workflow run 实例化（失败整体回滚）
      change(before_action(&prepare_create/2))

      # 提交确认（R14 第 1 行）：create 同事务入 outbox。豁免路径同发提交确认，
      # 但绝不发初审结果通知（初审结果信号只在 advance_to_interview 发）
      change({SignalEmitter, type: @submitted_signal, payload: &__MODULE__.signal_payload/2})
    end

    # 初审通过：submitted → interview（Owner/Admin 或系统调用）
    update :advance_to_interview do
      description("初审通过：submitted → interview（放行 run 的 submitted 门控）")
      require_atomic?(false)
      accept([])

      change(before_action(&prepare_advance_to_interview/2))

      change({SignalEmitter, type: @interview_signal, payload: &__MODULE__.signal_payload/2})

      change(
        after_transaction(fn changeset, result, _context ->
          case result do
            {:ok, application} -> resume_run(changeset, application, ["submitted"])
            _ -> :ok
          end

          result
        end)
      )
    end

    # 群面通过：interview → training（放行 run 的 interview 门控）
    update :advance_to_training do
      description("群面通过：interview → training（放行 run 的 interview 门控）")
      require_atomic?(false)
      accept([])

      change(before_action(&prepare_advance_to_training/2))

      change({SignalEmitter, type: @training_signal, payload: &__MODULE__.signal_payload/2})

      change(
        after_transaction(fn changeset, result, _context ->
          case result do
            {:ok, application} -> resume_run(changeset, application, ["interview"])
            _ -> :ok
          end

          result
        end)
      )
    end

    # 训练营完成·项目分配：training → assigned（R12 终态；Owner/Admin 或系统调用）
    update :assign do
      description("训练营完成·项目分配：training → assigned（run 直达 succeeded）")
      require_atomic?(false)
      accept([])

      argument(:assigned_event_id, :uuid,
        allow_nil?: true,
        description: "主理人分配目标场次 ID（Tutor 可空）"
      )

      argument(:assignment_note, :string,
        allow_nil?: true,
        description: "分配备注（如 Tutor 的课程任务）"
      )

      change(before_action(&prepare_assign/2))

      change({SignalEmitter, type: @assigned_signal, payload: &__MODULE__.signal_payload/2})

      # R12 的 training → assigned 边承载「训练营完成」与「项目分配」两个事实：
      # 依次放行 training / assigned 两个门控，run 与申请一致地到达终态。
      change(
        after_transaction(fn changeset, result, _context ->
          case result do
            {:ok, application} -> resume_run(changeset, application, ["training", "assigned"])
            _ -> :ok
          end

          result
        end)
      )
    end

    # 拒绝：任一审核段 → rejected（必带原因文本，R12/AE3）
    update :reject do
      description("拒绝：submitted | interview | training → rejected（必带原因）")
      require_atomic?(false)
      accept([])

      argument(:reason, :string,
        allow_nil?: true,
        description: "拒绝原因（必填；进入 applicant 通知）"
      )

      change(before_action(&prepare_reject/2))

      change({SignalEmitter, type: @rejected_signal, payload: &__MODULE__.signal_payload/2})

      change(
        after_transaction(fn changeset, result, _context ->
          case result do
            {:ok, application} -> fail_run(application)
            _ -> :ok
          end

          result
        end)
      )
    end

    # 取消：任一审核段 → canceled（管理员操作，备注选填；R12/AE8）
    update :cancel do
      description("取消：submitted | interview | training → canceled（备注选填）")
      require_atomic?(false)
      accept([])

      argument(:reason, :string,
        allow_nil?: true,
        description: "取消备注（选填，与拒绝原因同列承载）"
      )

      change(before_action(&prepare_cancel/2))

      change({SignalEmitter, type: @canceled_signal, payload: &__MODULE__.signal_payload/2})

      change(
        after_transaction(fn changeset, result, _context ->
          case result do
            {:ok, application} -> cancel_run(application)
            _ -> :ok
          end

          result
        end)
      )
    end
  end

  graphql do
    type(:volunteer_application)
  end

  postgres do
    table("volunteer_applications")
    repo(Cgc2046.Repo)
  end

  policies do
    # 读面：本人 ∪ Owner/Admin ∪ platform_admin（R13 管理面读全量）
    policy action_type(:read) do
      authorize_if(expr(user_id == ^actor(:id)))
      authorize_if(Cgc2046.Accounts.Policies.WorkspaceActorIsOwnerOrAdmin)
      authorize_if(Cgc2046.Accounts.Policies.PlatformAdmin)
    end

    # create 限本人：user_id 由 before_action 强制 = actor（申请人无需是台成员——
    # 项目分配时才邀请入台，R15）
    policy action_type(:create) do
      authorize_if(actor_present())
    end

    # 段位流转（含分配）限 Owner/Admin ∪ platform_admin；流转 action 在 U3
    policy action_type(:update) do
      authorize_if(Cgc2046.Accounts.Policies.WorkspaceActorIsOwnerOrAdmin)
      authorize_if(Cgc2046.Accounts.Policies.PlatformAdmin)
    end
  end

  # 同批重复申请（撞 volunteer_applications_unique_per_cohort_index）→ 稳定
  # 业务错误。按约束名分派、非 unique 冲突原样上抛（fail-closed），范式同
  # EventModerator.handle_write_error/2（#611）。
  @doc false
  def handle_write_error(_changeset, error) do
    if Cgc2046.Errors.ConstraintConflict.unique_conflict?(error) and
         Cgc2046.Errors.ConstraintConflict.constraint_named?(
           error,
           "volunteer_applications_unique_per_cohort_index"
         ) do
      Cgc2046.Errors.BusinessError.exception(
        message: "an application for this cohort already exists",
        code: "volunteer_application_already_submitted",
        fields: [:cohort_id]
      )
    else
      error
    end
  end

  # --- 创建准备（同事务：批次约束 + 豁免判定 + run 实例化） ---------------------

  # user_id 只能来自 actor（普通 change 在 for_create 阶段跑，actor 尚未注入
  # context，故用 before_action——范式同 PortfolioItem）；run 实例化同事务
  # （KTD1 镜像 SpeakerInvitation.prepare_create）：失败回滚申请，不落孤儿 run。
  defp prepare_create(changeset, _context) do
    actor = changeset.context[:private][:actor]
    workspace_id = changeset.tenant
    cohort_id = Ash.Changeset.get_attribute(changeset, :cohort_id)

    cond do
      is_nil(actor) ->
        Ash.Changeset.add_error(changeset, "create requires an authenticated actor")

      is_nil(workspace_id) ->
        Ash.Changeset.add_error(changeset, "create requires a tenant (workspace_id)")

      true ->
        with {:ok, cohort} <- fetch_cohort(cohort_id, workspace_id),
             :ok <- ensure_cohort_accepting(cohort),
             {:ok, previous_assignment} <- fetch_previous_assignment(actor, workspace_id),
             {:ok, application_id} <- application_id(changeset),
             {:ok, _run} <-
               start_run(changeset, workspace_id, application_id, previous_assignment) do
          changeset
          |> Ash.Changeset.force_change_attribute(:user_id, actor.id)
          |> Ash.Changeset.force_change_attribute(:status, initial_status(previous_assignment))
        else
          {:error, reason} -> add_domain_error(changeset, reason)
        end
    end
  end

  defp fetch_cohort(nil, _workspace_id), do: {:error, :cohort_not_found}

  defp fetch_cohort(cohort_id, workspace_id) do
    case Ash.get(RecruitmentCohort, cohort_id, tenant: workspace_id, authorize?: false) do
      {:ok, %RecruitmentCohort{} = cohort} -> {:ok, cohort}
      _ -> {:error, :cohort_not_found}
    end
  end

  # 批次关闭不放行新申请（R8）；在途申请不受影响（段位流转不读批次状态）
  defp ensure_cohort_accepting(%{status: :closed}), do: {:error, :cohort_closed}
  defp ensure_cohort_accepting(_cohort), do: :ok

  # 初审豁免判定（R8/AE11）：该申请人是否已有 assigned 记录（跨批次、跨职位——
  # 已完成项目分配即视为已上岗）。命中则本次申请直入 interview 段。
  defp fetch_previous_assignment(actor, workspace_id) do
    __MODULE__
    |> Ash.Query.filter(user_id == ^actor.id and status == :assigned)
    |> Ash.Query.limit(1)
    |> Ash.read_one(tenant: workspace_id, authorize?: false)
    |> case do
      {:ok, nil} -> {:ok, nil}
      {:ok, %__MODULE__{} = previous} -> {:ok, previous}
      {:error, reason} -> {:error, {:database, reason}}
    end
  end

  # uuid_primary_key 在 changeset 创建时即生成（attributes[:id]），before_action
  # 内可用作 run 的实例键（与 INSERT 同事务，失败一并回滚）。
  defp application_id(changeset) do
    case Ash.Changeset.get_attribute(changeset, :id) do
      id when is_binary(id) and id != "" -> {:ok, id}
      _ -> {:error, :application_id_unavailable}
    end
  end

  defp start_run(changeset, workspace_id, application_id, previous_assignment) do
    ApplicationWorkflowInstantiator.start_run(workspace_id, application_id,
      exempt_initial_review?: not is_nil(previous_assignment),
      source_application_id: previous_assignment && previous_assignment.id,
      cohort_id: Ash.Changeset.get_attribute(changeset, :cohort_id),
      user_id: actor(changeset).id,
      actor: actor(changeset)
    )
    |> case do
      {:ok, run} -> {:ok, run}
      {:error, reason} -> {:error, {:workflow_run_failed, reason}}
    end
  end

  defp initial_status(nil), do: :submitted
  defp initial_status(_previous_assignment), do: :interview

  # --- 段位流转准备（初始状态守卫 + 原子 CAS） ---------------------------------

  defp prepare_advance_to_interview(changeset, _context),
    do: guard_stage(changeset, [:submitted], :interview)

  defp prepare_advance_to_training(changeset, _context),
    do: guard_stage(changeset, [:interview], :training)

  defp prepare_assign(changeset, _context) do
    changeset
    |> put_assignment_fields()
    |> guard_stage([:training], :assigned)
  end

  defp put_assignment_fields(changeset) do
    changeset
    |> Ash.Changeset.force_change_attribute(:assigned_at, DateTime.utc_now())
    |> put_argument_if_present(:assigned_event_id)
    |> put_argument_if_present(:assignment_note)
  end

  defp put_argument_if_present(changeset, field) do
    case Ash.Changeset.get_argument(changeset, field) do
      nil -> changeset
      value -> Ash.Changeset.force_change_attribute(changeset, field, value)
    end
  end

  # 拒绝必带原因文本（R12/AE3）：空白原因与缺失同判（R14 拒绝通知要带原因）
  defp prepare_reject(changeset, _context) do
    reason = normalize_reason(Ash.Changeset.get_argument(changeset, :reason))

    case current_status(changeset) do
      {:ok, current} when current in @review_stages ->
        if is_nil(reason) do
          add_domain_error(changeset, :rejection_reason_required)
        else
          changeset
          |> Ash.Changeset.force_change_attribute(:rejection_reason, reason)
          |> claim_stage(@review_stages, :rejected)
        end

      {:ok, current} ->
        add_domain_error(changeset, {:invalid_transition, current})

      :error ->
        add_domain_error(changeset, {:invalid_transition, changeset.data.status})
    end
  end

  # 取消备注选填（AE8；ER：rejected 必填原因 / canceled 备注选填，同列承载）
  defp prepare_cancel(changeset, _context) do
    case current_status(changeset) do
      {:ok, current} when current in @review_stages ->
        changeset
        |> apply_note(normalize_reason(Ash.Changeset.get_argument(changeset, :reason)))
        |> claim_stage(@review_stages, :canceled)

      {:ok, current} ->
        add_domain_error(changeset, {:invalid_transition, current})

      :error ->
        add_domain_error(changeset, {:invalid_transition, changeset.data.status})
    end
  end

  defp apply_note(changeset, nil), do: changeset

  defp apply_note(changeset, note),
    do: Ash.Changeset.force_change_attribute(changeset, :rejection_reason, note)

  # 初始状态守卫：合法段位 → 原子 CAS；否则稳定业务错误。
  #
  # 源状态以**库内当前值**为准（陈旧 struct 不误判——段位流转是管理面低频动作，
  # 读一次换确定性；范式同 speaker_invitation.prepare_complete 的 load_record）。
  # 命中则把 from 段位编进 CAS：filter 进 UPDATE 的 WHERE 子句，并发流转败者
  # 影响 0 行 → StaleRecord，不静默覆盖（mcp/pending_operation.ex 同款）。
  defp guard_stage(changeset, from_statuses, to_status) do
    case current_status(changeset) do
      {:ok, current} ->
        if current in from_statuses do
          claim_stage(changeset, from_statuses, to_status)
        else
          add_domain_error(changeset, {:invalid_transition, current})
        end

      :error ->
        add_domain_error(changeset, {:invalid_transition, changeset.data.status})
    end
  end

  defp current_status(changeset) do
    case Ash.get(__MODULE__, changeset.data.id, tenant: changeset.tenant, authorize?: false) do
      {:ok, %__MODULE__{status: status}} -> {:ok, status}
      _ -> :error
    end
  end

  defp claim_stage(changeset, from_statuses, to_status) do
    changeset
    |> Ash.Changeset.filter(expr(status in ^from_statuses))
    |> Ash.Changeset.force_change_attribute(:status, to_status)
  end

  defp normalize_reason(reason) when is_binary(reason) do
    case String.trim(reason) do
      "" -> nil
      trimmed -> trimmed
    end
  end

  defp normalize_reason(_reason), do: nil

  # --- run 镜像同步（提交后 best-effort；失败记日志不阻塞业务状态——申请行
  # 才是 checkpoint，KTD1；语义镜像 speaker_invitation.resume_run/fail_run） ----

  defp resume_run(changeset, application, gate_keys) do
    Enum.each(gate_keys, fn gate_key ->
      case ApplicationWorkflowInstantiator.fetch_run(application.workspace_id, application.id) do
        {:ok, run} ->
          payload = %{
            "gate" => gate_key,
            "volunteer_application_id" => application.id,
            "status" => to_string(application.status)
          }

          case run
               |> Ash.Changeset.for_update(
                 :resume_signal,
                 %{"signal_type" => "workflow.#{gate_key}", "payload" => payload},
                 actor: actor(changeset),
                 tenant: run.workspace_id,
                 authorize?: false
               )
               |> Ash.update(tenant: run.workspace_id, authorize?: false) do
            {:ok, _run} ->
              :ok

            {:error, reason} ->
              Logger.error(
                "volunteer_application #{application.id}: run resume (#{gate_key}) failed: " <>
                  inspect(reason)
              )
          end

        {:error, :run_not_found} ->
          Logger.error(
            "volunteer_application #{application.id}: workflow run missing or unreadable"
          )
      end
    end)

    :ok
  rescue
    error ->
      Logger.error(
        "volunteer_application #{application.id}: run resume raised: " <>
          Exception.format(:error, error, __STACKTRACE__)
      )
  end

  defp fail_run(application), do: transition_run(application, :fail)
  defp cancel_run(application), do: transition_run(application, :cancel)

  defp transition_run(application, action) do
    case ApplicationWorkflowInstantiator.fetch_run(application.workspace_id, application.id) do
      {:ok, run} ->
        case run
             |> Ash.Changeset.for_update(action, %{},
               tenant: run.workspace_id,
               authorize?: false
             )
             |> Ash.update(tenant: run.workspace_id, authorize?: false) do
          {:ok, _run} ->
            :ok

          {:error, reason} ->
            Logger.error(
              "volunteer_application #{application.id}: run #{action} failed: #{inspect(reason)}"
            )
        end

      {:error, :run_not_found} ->
        Logger.error(
          "volunteer_application #{application.id}: workflow run missing or unreadable"
        )
    end

    :ok
  rescue
    error ->
      Logger.error(
        "volunteer_application #{application.id}: run #{action} raised: " <>
          Exception.format(:error, error, __STACKTRACE__)
      )
  end

  defp actor(changeset), do: changeset.context[:private][:actor]

  # --- 信号 payload（SignalEmitter 契约：fn changeset, record -> map，只组装业务键；
  # idempotency_key / workspace_id 由 emitter 统一注入） -------------------------

  @doc false
  def signal_payload(_changeset, record) do
    %{
      "volunteer_application_id" => record.id,
      "user_id" => record.user_id,
      "cohort_id" => record.cohort_id,
      "position" => to_string(record.position),
      "status" => to_string(record.status),
      "rejection_reason" => record.rejection_reason
    }
  end

  # --- 稳定业务错误（Errors.BusinessError，i18n 按 code 查文案） ----------------

  defp add_domain_error(changeset, reason) do
    Ash.Changeset.add_error(
      changeset,
      BusinessError.exception(
        message: domain_error_message(reason),
        code: domain_error_code(reason),
        fields: [:status]
      )
    )
  end

  defp domain_error_message({:invalid_transition, status}),
    do: "application cannot move from status=#{status}"

  defp domain_error_message(:rejection_reason_required), do: "a rejection reason is required"
  defp domain_error_message(:cohort_not_found), do: "cohort not found"
  defp domain_error_message(:cohort_closed), do: "cohort is closed"

  defp domain_error_message({:workflow_run_failed, _reason}),
    do: "failed to start workflow run"

  defp domain_error_message({:exemption_fact_failed, _reason}),
    do: "failed to record initial review exemption"

  defp domain_error_message({:database, _reason}), do: "database operation failed"
  defp domain_error_message(:application_id_unavailable), do: "application id is unavailable"
  defp domain_error_message(reason), do: inspect(reason)

  defp domain_error_code({:invalid_transition, _status}),
    do: "volunteer_application_invalid_transition"

  defp domain_error_code(:rejection_reason_required),
    do: "volunteer_application_rejection_reason_required"

  defp domain_error_code(:cohort_not_found), do: "volunteer_application_cohort_not_found"
  defp domain_error_code(:cohort_closed), do: "volunteer_application_cohort_closed"

  defp domain_error_code({:workflow_run_failed, _reason}),
    do: "volunteer_application_workflow_run_failed"

  defp domain_error_code({:exemption_fact_failed, _reason}),
    do: "volunteer_application_exemption_fact_failed"

  defp domain_error_code({:database, _reason}), do: "database_error"

  defp domain_error_code(:application_id_unavailable),
    do: "volunteer_application_application_id_unavailable"

  defp domain_error_code(reason) when is_atom(reason),
    do: "volunteer_application_" <> Atom.to_string(reason)

  defp domain_error_code(_reason), do: "volunteer_application_error"
end
