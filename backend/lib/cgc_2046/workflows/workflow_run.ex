defmodule Cgc2046.Workflows.WorkflowRun do
  @moduledoc """
  Workflow 执行实例资源（Slice C #35）。

  领域模型（docs/01-定稿设计/领域模型定稿.md §5.2 ER）：WorkflowRun 是 WorkflowDefinition 的
  执行实例，绑定 definition_id + definition_version（D-A2 版本快照：已开始 run 持当时
  published 版本，不随后续版本变动）。

  ## 状态机（#35 acceptance）

      pending ──start──► running ──wait──► waiting ──resume──► running
         │                 │  │              │
         │                 │  └──complete──► succeeded
         │                 │  └──fail──────► failed
         │                 └──cancel──────► cancelled
         └──expire────────────────────────► expired

  - `pending`：run 已创建（快照 input + 绑定 definition_version），未开始执行
  - `running`：引擎执行中
  - `waiting`：执行到人工步骤，挂起等外部信号（阶段 4 接 hibernate/thaw）
  - `succeeded` / `failed` / `cancelled` / `expired`：终态

  ## ADR-0003 纪律

  - **无状态引擎 + 有状态壳**：执行状态全部落本资源（status/facts/started_at/finished_at），
    引擎（`Cgc2046.Workflows.Engine`）是无状态纯函数，不持有任何状态。
  - **审计走事件订阅**：引擎只发 telemetry 事件（`[:cgc, :workflow, :run, ...]`），
    产品层按需订阅记录，不嵌入引擎核心。
  - **checkpoint 生命周期在产品层**：waiting→hibernate、终态→delete 经
    `Cgc2046.Workflows.CheckpointLifecycle` 接线（架构评审候选 #2），引擎只执行。

  ## 多租户

  multitenancy attribute :workspace_id；`partition_id` 与 workspace_id 同值
  （ADR-0002 决策 6：每 workspace = 一个 Jido partition），供 JidoAdapter 做运行时隔离。

  ## 并发

  `version` 乐观锁（R4：per-WorkflowRun 串行化，不复用 advisory lock）：
  状态流转 action 带 `optimistic_lock(:version)`，并发更新冲突返回 StaleRecord。
  """

  use Ash.Resource,
    data_layer: AshPostgres.DataLayer,
    extensions: [AshGraphql.Resource, AshAdmin.Resource],
    authorizers: [Ash.Policy.Authorizer],
    domain: Cgc2046.Workflows

  require Ash.Query

  alias Cgc2046.Workflows.{
    CheckpointLifecycle,
    Engine,
    SignalLog,
    StepAuthorization,
    WorkflowDefinition
  }

  @status_values [:pending, :running, :waiting, :succeeded, :failed, :cancelled, :expired]

  attributes do
    uuid_primary_key(:id)

    attribute(:workspace_id, :uuid,
      allow_nil?: false,
      public?: true,
      writable?: false,
      description: "所属工作台（租户）ID"
    )

    attribute(:definition_id, :uuid,
      allow_nil?: false,
      public?: true,
      writable?: true,
      description: "绑定的 WorkflowDefinition ID"
    )

    attribute(:definition_version, :integer,
      allow_nil?: false,
      public?: true,
      writable?: true,
      description: "绑定的定义版本号（D-A2 版本快照，已开始 run 不随后续版本变动）"
    )

    attribute(:status, :atom,
      allow_nil?: false,
      default: :pending,
      public?: true,
      writable?: false,
      constraints: [one_of: @status_values],
      description: "执行状态机：pending/running/waiting/succeeded/failed/cancelled/expired"
    )

    attribute(:input_snapshot, :map,
      public?: true,
      writable?: true,
      description: "run 输入快照（创建时固化，执行引擎按此驱动）"
    )

    attribute(:facts, :map,
      public?: true,
      writable?: true,
      default: %{},
      description: "执行产物 facts（按 step_key 聚合，引擎执行后写入）"
    )

    attribute(:partition_id, :uuid,
      public?: true,
      writable?: true,
      description: "Jido partition（= workspace_id，ADR-0002 决策 6 运行时隔离）"
    )

    # 乐观锁版本（R4：per-WorkflowRun 串行化）
    attribute(:version, :integer,
      allow_nil?: false,
      default: 1,
      public?: true,
      writable?: false,
      description: "乐观锁版本号，每次状态流转 +1"
    )

    attribute(:started_at, :utc_datetime_usec,
      public?: true,
      writable?: false,
      description: "开始执行时间（start action 写入）"
    )

    attribute(:finished_at, :utc_datetime_usec,
      public?: true,
      writable?: false,
      description: "结束时间（终态 action 写入）"
    )

    create_timestamp(:inserted_at)
    update_timestamp(:updated_at)
  end

  calculations do
    # plan 020 U3/U4（#150 最小版 + #93）：run 步骤读取面（合并 Step 行 + node_def
    # output_schema，按 run 绑定的 definition 版本读，不读最新定义；授权复用
    # WorkflowRun 读 policy）。形状：%{step_key, title, type, output_schema} 列表。
    calculate(
      :steps,
      {:array, :map},
      {Cgc2046.Workflows.RunSteps, []},
      public?: true,
      description: "run 绑定版本的步骤定义（step_key/title/type/output_schema，plan 020）"
    )
  end

  multitenancy do
    strategy(:attribute)
    attribute(:workspace_id)
    global?(true)
  end

  relationships do
    # public?: true（plan 020 U3）：run 绑定的定义版本行（D-A2 版本快照——definition_id
    # 即版本行 id，new_version 出新行不改旧行），GraphQL 经 definition { type } 读取。
    # 授权复用 WorkflowRun 读 policy（ActorIsWorkspaceMemberVia path [:definition, :workspace]）。
    belongs_to(:definition, Cgc2046.Workflows.WorkflowDefinition,
      source_attribute: :definition_id,
      destination_attribute: :id,
      allow_nil?: false,
      public?: true
    )
  end

  actions do
    default_accept([:definition_id, :definition_version, :input_snapshot])

    # 创建 run：快照 input + 绑定 definition_version，默认 status=pending, version=1
    create :create do
      description("创建 workflow 执行实例（默认 status=pending, version=1）")
      accept([:definition_id, :definition_version, :input_snapshot])

      change(set_attribute(:status, :pending))
      change(set_attribute(:version, 1))
      change(set_attribute(:facts, %{}))

      # partition_id = workspace_id（ADR-0002 决策 6：每 workspace = 一个 Jido partition），
      # 由 tenant 强制，不接受调用方传入
      change(fn changeset, _context ->
        case changeset.tenant do
          nil -> Ash.Changeset.add_error(changeset, "create requires a tenant (workspace_id)")
          tenant -> Ash.Changeset.force_change_attribute(changeset, :partition_id, tenant)
        end
      end)

      # definition 归属与版本一致性校验（/check SC2-004）：definition_id 必须属于当前
      # tenant，其对应版本行状态必须为 published（draft/archived 不可建 run），且传入的
      # definition_version 必须与该 id 行的 version 一致（防 id/version 矛盾或伪造）。
      # 注意：版本行即 id（new_version 生成新行，见 WorkflowDefinition），故对「旧
      # published 版本」建 run 是允许的——D-A2 快照由版本行不可变 + 按 id 回查保证
      change(fn changeset, _context ->
        tenant = changeset.tenant
        definition_id = Ash.Changeset.get_attribute(changeset, :definition_id)
        definition_version = Ash.Changeset.get_attribute(changeset, :definition_version)

        cond do
          is_nil(tenant) ->
            Ash.Changeset.add_error(changeset, "create requires a tenant (workspace_id)")

          is_nil(definition_id) or is_nil(definition_version) ->
            Ash.Changeset.add_error(
              changeset,
              "definition_id and definition_version are required"
            )

          true ->
            case Ash.get(Cgc2046.Workflows.WorkflowDefinition, definition_id,
                   tenant: tenant,
                   authorize?: false
                 ) do
              {:ok, defn} when defn.workspace_id == tenant and defn.status == :published ->
                if defn.version == definition_version do
                  changeset
                else
                  Ash.Changeset.add_error(
                    changeset,
                    "definition #{definition_id} is version #{defn.version}, got definition_version #{definition_version}"
                  )
                end

              {:ok, defn} when defn.workspace_id != tenant ->
                Ash.Changeset.add_error(
                  changeset,
                  "definition #{definition_id} belongs to a different workspace"
                )

              {:ok, defn} ->
                Ash.Changeset.add_error(
                  changeset,
                  "definition #{definition_id} status=#{defn.status}, must be published"
                )

              {:error, _} ->
                Ash.Changeset.add_error(changeset, "definition #{definition_id} not found")
            end
        end
      end)
    end

    # pending → running：开始执行，记录 started_at
    update :start do
      description("开始执行：pending → running")
      require_atomic?(false)

      # 不接受任何属性（/check SC2-005：继承 default_accept 可改 input_snapshot/definition_version）
      accept([])
      change(optimistic_lock(:version))
      change({Cgc2046.Workflows.Changes.Transition, from: [:pending], to: :running})
      change(set_attribute(:started_at, &DateTime.utc_now/0))
    end

    # pending → running/succeeded/waiting/failed：一步启动 + 执行闭环（阶段 4 #37）。
    # 与纯状态机 :start 不同：本 action 调 Engine.run 执行 node_def，
    # 按结果流转——succeeded 直接终态，waiting 自动 hibernate 后挂起。
    update :start_run do
      description("启动并执行：pending → running → succeeded | waiting | failed")
      require_atomic?(false)
      accept([])
      change(optimistic_lock(:version))
      change({Cgc2046.Workflows.Changes.Transition, from: [:pending], to: :running})

      # 执行闭环只在 Transition 守卫通过（源状态匹配）时运行——非 pending 时
      # Transition 已 add_error，此处 no-op 不调引擎（原内联守卫的语义）。
      change(fn changeset, _context ->
        case Ash.Changeset.get_data(changeset, :status) do
          :pending ->
            run_started =
              changeset
              |> Ash.Changeset.force_change_attribute(:started_at, DateTime.utc_now())

            case start_run_execute(run_started) do
              {:ok, run_started, facts} ->
                run_started
                |> Ash.Changeset.force_change_attribute(:status, :succeeded)
                |> Ash.Changeset.force_change_attribute(:facts, facts)
                |> Ash.Changeset.force_change_attribute(:finished_at, DateTime.utc_now())

              {:waiting, run_started, facts} ->
                run_started
                |> Ash.Changeset.force_change_attribute(:status, :waiting)
                |> Ash.Changeset.force_change_attribute(:facts, facts)

              {:error, run_started, _reason} ->
                run_started
                |> Ash.Changeset.force_change_attribute(:status, :failed)
                |> Ash.Changeset.force_change_attribute(:finished_at, DateTime.utc_now())
            end

          _ ->
            changeset
        end
      end)
    end

    # running → waiting：执行到人工步骤挂起
    update :wait do
      description("挂起等待外部信号：running → waiting")
      require_atomic?(false)
      accept([])
      change(optimistic_lock(:version))

      change({Cgc2046.Workflows.Changes.Transition, from: [:running], to: :waiting})
    end

    # waiting → running：信号放行后恢复执行
    update :resume do
      description("信号放行恢复执行：waiting → running")
      require_atomic?(false)
      accept([])
      change(optimistic_lock(:version))

      change({Cgc2046.Workflows.Changes.Transition, from: [:waiting], to: :running})
    end

    # waiting → running/succeeded/failed：信号放行 + 恢复执行闭环（阶段 4 #37）。
    # 写 SignalLog 审计 → Engine.resume（thaw → feed_signal）→ 按结果流转。
    update :resume_signal do
      description("信号放行恢复执行：waiting → running → succeeded | waiting | failed")
      require_atomic?(false)
      argument(:signal_type, :string, allow_nil?: false)
      argument(:payload, :map, default: %{})
      change(optimistic_lock(:version))

      change({Cgc2046.Workflows.Changes.Transition, from: [:waiting], to: :running})

      # 执行闭环只在 Transition 守卫通过（源状态匹配）时运行——非 waiting 时
      # Transition 已 add_error，此处 no-op 不走授权/Engine（原内联守卫的语义）。
      change(fn changeset, _context ->
        case Ash.Changeset.get_data(changeset, :status) do
          :waiting -> resume_signal_execute(changeset)
          _ -> changeset
        end
      end)
    end

    # running/waiting → succeeded：执行完成，写入 facts + finished_at
    update :complete do
      description("执行完成：running/waiting → succeeded")
      require_atomic?(false)
      change(optimistic_lock(:version))
      accept([:facts])

      # PR-G：checkpoint 清理从隐藏 invariant 变结构保证（D3）——complete 可自
      # waiting 达终态，终态后 checkpoint 无消费方（ADR-0002），须清理（此前缺失，
      # 由 speaker 外部补偿兜着，PR-G D4 收编后补偿删除）。
      change(
        {Cgc2046.Workflows.Changes.Transition,
         from: [:running, :waiting], to: :succeeded, cleanup_checkpoint: true}
      )

      change(set_attribute(:finished_at, &DateTime.utc_now/0))
    end

    # running/waiting → failed：执行失败
    update :fail do
      description("执行失败：running/waiting → failed")
      require_atomic?(false)
      accept([])
      change(optimistic_lock(:version))

      # PR-G D4：fail 补 cleanup_checkpoint（此前由 speaker_invitation.ex 外部补偿
      # 清理；Transition 内建后补偿删除，fail 路径 checkpoint 清理由本 action 承担）。
      change(
        {Cgc2046.Workflows.Changes.Transition,
         from: [:running, :waiting], to: :failed, cleanup_checkpoint: true}
      )

      change(set_attribute(:finished_at, &DateTime.utc_now/0))
    end

    # pending/running/waiting → cancelled：人工取消
    update :cancel do
      description("取消执行：pending/running/waiting → cancelled")
      require_atomic?(false)
      accept([])
      change(optimistic_lock(:version))

      # #16：waiting → cancelled 时删除 jido_checkpoints（不删则 checkpoint 行永久残留）。
      # cleanup_checkpoint: true 内建 after_transaction 清理（Transition D3 收编原
      # 逐字拷贝；失败记日志不阻塞，策略单源在 CheckpointLifecycle，候选 #2）。
      change(
        {Cgc2046.Workflows.Changes.Transition,
         from: [:pending, :running, :waiting], to: :cancelled, cleanup_checkpoint: true}
      )

      change(set_attribute(:finished_at, &DateTime.utc_now/0))
    end

    # pending/waiting → expired：超时（阶段 4 deadline 唤醒路径）
    update :expire do
      description("超时过期：pending/waiting → expired")
      require_atomic?(false)
      accept([])
      change(optimistic_lock(:version))

      # #16：waiting → expired 时删除 jido_checkpoints（同 cancel 的 checkpoint 清理）。
      change(
        {Cgc2046.Workflows.Changes.Transition,
         from: [:pending, :waiting], to: :expired, cleanup_checkpoint: true}
      )

      change(set_attribute(:finished_at, &DateTime.utc_now/0))
    end

    defaults([:read])

    # #40 展示页：按 id 取 run 详情（GraphQL read_one）
    read :get_by_id do
      get_by([:id])
    end

    # 切片 D MCP save_step_output 工具：浅合并 facts（StepRole 授权在工具层判定）。
    # 不走状态机 action（complete/fail 等）——MCP 写产出不改变 run 状态；
    # 终态 run 拒绝写入（避免伪造执行产物）。
    update :update_facts_for_mcp do
      description("MCP 工具写入 step 产出（facts 浅合并；终态拒绝）")
      require_atomic?(false)
      accept([:facts])

      change(fn changeset, _context ->
        case Ash.Changeset.get_data(changeset, :status) do
          status when status in [:pending, :running, :waiting] ->
            changeset

          status ->
            Ash.Changeset.add_error(
              changeset,
              "cannot save step output to run in status=#{status}"
            )
        end
      end)
    end
  end

  postgres do
    table("workflow_runs")
    repo(Cgc2046.Repo)
  end

  policies do
    # 读取（H3）：经 definition → workspace → memberships 路径，仅成员或平台管理员
    policy action_type(:read) do
      authorize_if(
        {Cgc2046.Accounts.Policies.ActorIsWorkspaceMemberVia, path: [:definition, :workspace]}
      )

      authorize_if(Cgc2046.Accounts.Policies.PlatformAdmin)
    end

    # #38 StepRole 授权：start_run（auto 步骤引擎执行不授权，§4.3）与 resume_signal
    # （manual 信号发起人，StepRole 判定在 action 内）对成员放开；expire 仍限 Owner/Admin。
    # 非成员平台管理员为只读审计者，不得启动或恢复 workflow。
    bypass action([:start_run, :resume_signal]) do
      authorize_if(
        {Cgc2046.Accounts.Policies.ActorIsWorkspaceMemberVia, path: [:definition, :workspace]}
      )
    end

    # 切片 D：MCP save_step_output 的 facts 写入对成员放开（StepRole 细粒度授权
    # 已在工具层经 StepAuthorization.authorize_signal/4 判定，本层只做成员门槛）。
    # E-7 #122：学习 run 加「报名学员本人」分支（学员是非成员——授权来自 Enrollment
    # 记录本身，设计 §4.1；SimpleCheck 从 changeset.data 判定，见模块 moduledoc）。
    # 注意：bypass 必须位于通用 create/update policy **之前**——Ash 按序评估，
    # 通用 policy 先失败则后续 bypass 不再被求值。
    bypass action(:update_facts_for_mcp) do
      authorize_if(
        {Cgc2046.Accounts.Policies.ActorIsWorkspaceMemberVia, path: [:definition, :workspace]}
      )

      authorize_if(Cgc2046.Admission.Policies.ActorIsEnrolledLearner)
    end

    # 写操作：Owner/Admin（多角色并集）
    policy action_type([:create, :update]) do
      authorize_if(Cgc2046.Accounts.Policies.WorkspaceActorIsOwnerOrAdmin)
    end
  end

  graphql do
    type(:workflow_run)
    relationships([:definition])

    queries do
      list(:list_workflow_runs, :read, description: "工作台的 workflow run 列表（#40 展示页）")
      read_one(:get_workflow_run, :get_by_id, description: "按 id 获取 workflow run 详情（#40）")
    end
  end

  # --- 产品层执行闭环辅助（阶段 4 #37） ---------------------------------------

  # start_run：从 definition 读 node_def，调 Engine.run；waiting 时经
  # CheckpointLifecycle hibernate（架构评审候选 #2，checkpoint 生命周期收拢）。
  # 返回 {status, changeset[, facts]}——status ∈ :ok | :waiting | :error
  defp start_run_execute(changeset) do
    tenant = changeset.tenant
    run_id = Ash.Changeset.get_data(changeset, :id)
    definition_id = Ash.Changeset.get_data(changeset, :definition_id)
    partition = Ash.Changeset.get_data(changeset, :partition_id)
    input = Ash.Changeset.get_data(changeset, :input_snapshot)

    case Ash.get(WorkflowDefinition, definition_id, tenant: tenant, authorize?: false) do
      {:ok, defn} ->
        case Engine.run(defn.node_def, input, tenant: tenant) do
          {:ok, facts, _workflow} ->
            {:ok, changeset, facts}

          {:waiting, facts, workflow} ->
            apply_waiting_result(changeset, run_id, partition, workflow, facts)

          {:error, reason} ->
            {:error, changeset, reason}
        end

      {:error, _} ->
        {:error, changeset, :definition_not_found}
    end
  end

  # waiting → hibernate checkpoint。hibernate 失败 = waiting 但无 checkpoint =
  # 下次信号 thaw 死路（#2 bug class）→ 上抛 error（start_run action 转 :failed，
  # 与 Engine.run 旧路径 #2 语义一致）。
  defp apply_waiting_result(changeset, run_id, partition, workflow, facts) do
    case CheckpointLifecycle.on_status(:waiting, run_id, partition, workflow) do
      :ok ->
        {:waiting, changeset, facts}

      {:error, reason} ->
        {:error, changeset, {:hibernate_failed, reason}}
    end
  end

  # resume_signal：授权（#38）→ 写 SignalLog → Engine.resume（thaw → feed_signal）→ 按结果流转。
  defp resume_signal_execute(changeset) do
    tenant = changeset.tenant
    run_id = Ash.Changeset.get_data(changeset, :id)
    partition = Ash.Changeset.get_data(changeset, :partition_id)
    definition_id = Ash.Changeset.get_data(changeset, :definition_id)
    signal_type = Ash.Changeset.get_argument(changeset, :signal_type)
    payload = Ash.Changeset.get_argument(changeset, :payload) || %{}

    # 授权与审计一律用认证 actor（changeset.context[:private][:actor]），
    # 不信任客户端传入的 actor_id——否则任何成员可伪造 owner id 放行 manual 门控（#4）。
    actor = changeset.context[:private][:actor]

    cond do
      is_nil(signal_type) ->
        Ash.Changeset.add_error(changeset, "signal_type is required")

      is_nil(actor) ->
        Ash.Changeset.add_error(changeset, "resume_signal requires an authenticated actor")

      true ->
        # #38 StepRole 授权：manual 步骤信号发起人（领域模型 §4.3）。
        # actor 为 nil → 无角色 → 有 StepRole 配置则拒绝（安全方向）。
        # 判定在 StepAuthorization（Engine 不收授权）；错误文案由 error_message/2 产出。
        step_key = String.replace_prefix(signal_type, "workflow.", "")

        case StepAuthorization.authorize_signal(actor, tenant, definition_id, step_key) do
          :ok ->
            resume_signal_authorized(
              changeset,
              tenant,
              run_id,
              partition,
              signal_type,
              payload,
              actor.id
            )

          {:error, reason} ->
            Ash.Changeset.add_error(changeset, StepAuthorization.error_message(reason, step_key))
        end
    end
  end

  defp resume_signal_authorized(
         changeset,
         tenant,
         run_id,
         partition,
         signal_type,
         payload,
         actor_id
       ) do
    case write_signal_log(tenant, run_id, signal_type, payload, actor_id) do
      :ok ->
        # 信号 payload 并入 workflow 上下文（下游步骤可读 approved_by 等）
        signal = Map.put(payload, "signal_type", signal_type)

        case Engine.resume(run_id, partition, signal) do
          {:ok, engine_facts, workflow} ->
            facts = merge_persisted_facts(changeset, engine_facts)

            # 终态删除 checkpoint（宽松：失败记日志不阻塞；策略单源在 CheckpointLifecycle）
            :ok = CheckpointLifecycle.on_status(:succeeded, run_id, partition, workflow)

            changeset
            |> Ash.Changeset.force_change_attribute(:status, :succeeded)
            |> Ash.Changeset.force_change_attribute(:facts, facts)
            |> Ash.Changeset.force_change_attribute(:finished_at, DateTime.utc_now())

          {:waiting, engine_facts, workflow} ->
            facts = merge_persisted_facts(changeset, engine_facts)

            # 续传 hibernate（严格：失败 → failed。行为变化点：原 `:ok =` raise
            # 崩溃 → 受控失败，与 start_run 路径 #2 语义一致）。
            case CheckpointLifecycle.on_status(:waiting, run_id, partition, workflow) do
              :ok ->
                changeset
                |> Ash.Changeset.force_change_attribute(:status, :waiting)
                |> Ash.Changeset.force_change_attribute(:facts, facts)

              {:error, _reason} ->
                # hibernate 失败 → failed；清掉旧 checkpoint（thaw 时读出的那份仍在
                # 存储中，不删即孤儿残留；delete 幂等宽松，策略单源在
                # CheckpointLifecycle，与 {:error, _reason} 分支一致）
                :ok = CheckpointLifecycle.on_status(:failed, run_id, partition, nil)

                changeset
                |> Ash.Changeset.force_change_attribute(:status, :failed)
                |> Ash.Changeset.force_change_attribute(:finished_at, DateTime.utc_now())
            end

          {:error, _reason} ->
            # 执行失败（:step_failed / thaw / feed_signal 失败）→ failed；
            # 清 checkpoint（delete 幂等，thaw 失败时无害）
            :ok = CheckpointLifecycle.on_status(:failed, run_id, partition, nil)

            changeset
            |> Ash.Changeset.force_change_attribute(:status, :failed)
            |> Ash.Changeset.force_change_attribute(:finished_at, DateTime.utc_now())
        end

      {:error, _} ->
        Ash.Changeset.add_error(changeset, "failed to record signal log")
    end
  end

  # Engine.resume thaws an older checkpoint; persisted facts win over stale engine facts.
  defp merge_persisted_facts(changeset, engine_facts) do
    persisted_facts = Ash.Changeset.get_data(changeset, :facts) || %{}
    Map.merge(engine_facts, persisted_facts)
  end

  defp write_signal_log(tenant, run_id, signal_type, payload, actor_id) do
    attrs = %{
      run_id: run_id,
      signal_type: signal_type,
      payload: payload,
      actor_id: actor_id
    }

    case SignalLog
         |> Ash.Changeset.for_create(:create, attrs, tenant: tenant, authorize?: false)
         |> Ash.create(tenant: tenant, authorize?: false) do
      {:ok, _log} -> :ok
      {:error, _} -> {:error, :signal_log_failed}
    end
  end

  admin do
    # #113 ops 面优化：导航分组 + 列表列裁剪（默认全列横向爆炸；敏感/超大字段不列出）
    resource_group(:workflows)

    table_columns([
      :id,
      :workspace_id,
      :definition_id,
      :status,
      :started_at,
      :finished_at,
      :inserted_at
    ])
  end

  # --- 建 run 唯一入口（PR-F：find_or_create_and_start 内化 ordering invariant） ------

  @doc """
  建 run 唯一入口：非终态去重 + create→start 顺序内化（漏 start = 永久 pending run
  的 ordering leak 从 interface 根除）。三个 instantiator（curriculum/learning/speaker）
  不再各自手写两步五参舞蹈。

  - `key`：去重键（写入 `input_snapshot["key"]`）。非 nil → 按 definition + key 查
    非终态 run（`pending/running/waiting`，终态列表与 curriculum/learning 既有
    existing_run 逐字一致），命中返回 `{:ok, run, :existing}`；未命中 → 创建并启动。
    nil → 不去重，直接创建并启动（speaker 供：邀请唯一性由调用侧
    `ensure_no_active_invitation` 保证，key 字段仍随 input 写入）。
  - `start_action`：`:start_run`（默认；curriculum/speaker，pending → 执行闭环）｜
    `:start`（learning：协议而非 DAG，纯状态流转 pending → running，不经 Engine）。
  - `actor`：透传（默认 nil = `authorize?: false` 无 actor，与既有 instantiator 一致）。

  纯顺序函数：create（`authorize?: false` + `tenant: workspace_id`，走既有 `:create`
  action 的 definition 归属/tenant/版本校验）→ 紧接 start（同一函数体内）。
  **不引入任何事务语义**——speaker 在 SpeakerInvitation before_action 事务内调用
  （D4 红线），事务边界由调用方控制；失败原样上抛。
  """
  @spec find_or_create_and_start(String.t(), WorkflowDefinition.t(), map(), keyword()) ::
          {:ok, __MODULE__.t(), :existing | :created} | {:error, term()}
  def find_or_create_and_start(workspace_id, definition, input, opts \\ []) do
    key = opts[:key]
    start_action = opts[:start_action] || :start_run

    case key do
      nil ->
        create_and_start(workspace_id, definition, input, start_action, opts)

      key ->
        case existing_run(workspace_id, definition.id, key) do
          {:ok, nil} ->
            create_and_start(workspace_id, definition, input, start_action, opts, key)

          {:ok, run} ->
            {:ok, run, :existing}

          {:error, error} ->
            {:error, error}
        end
    end
  end

  # 非终态去重（终态列表与 curriculum/learning 既有 existing_run 逐字一致）：同一
  # definition + instance key 已有 pending/running/waiting run → 命中；终态后可重新
  # 实例化（succeeded/failed/cancelled/expired 不在判定内）。
  defp existing_run(workspace_id, definition_id, key) do
    __MODULE__
    |> Ash.Query.filter(
      definition_id == ^definition_id and
        status in [:pending, :running, :waiting] and
        input_snapshot["key"] == ^key
    )
    |> Ash.read_one(tenant: workspace_id, authorize?: false)
  end

  # create → 紧接 start（同一函数体内，漏 start 不再可能；失败原样上抛）。
  # key 非 nil 时把去重键写入 input_snapshot（与 curriculum/learning 既有
  # Map.put(input, "key", key) 语义一致）；key nil 时 input 原样落库（speaker 的
  # key 字段随 input 自带）。
  defp create_and_start(workspace_id, definition, input, start_action, opts, key \\ nil) do
    actor = opts[:actor]
    input_snapshot = if is_nil(key), do: input, else: Map.put(input, "key", key)

    attrs = %{
      definition_id: definition.id,
      definition_version: definition.version,
      input_snapshot: input_snapshot
    }

    with {:ok, run} <-
           __MODULE__
           |> Ash.Changeset.for_create(:create, attrs, tenant: workspace_id, authorize?: false)
           |> Ash.create(tenant: workspace_id, authorize?: false, actor: actor),
         {:ok, started} <-
           run
           |> Ash.Changeset.for_update(start_action, %{}, tenant: workspace_id, authorize?: false)
           |> Ash.update(tenant: workspace_id, authorize?: false, actor: actor) do
      {:ok, started, :created}
    end
  end
end
