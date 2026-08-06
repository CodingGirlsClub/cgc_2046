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
  - **checkpoint 经回调不进核心**：阶段 4 的 checkpoint 服务经引擎回调接入，本资源不内建。

  ## 多租户

  multitenancy attribute :workspace_id；`partition_id` 与 workspace_id 同值
  （ADR-0002 决策 6：每 workspace = 一个 Jido partition），供 JidoAdapter 做运行时隔离。

  ## 并发

  `version` 乐观锁（R4：per-WorkflowRun 串行化，不复用 advisory lock）：
  状态流转 action 带 `optimistic_lock(:version)`，并发更新冲突返回 StaleRecord。
  """

  use Ash.Resource,
    data_layer: AshPostgres.DataLayer,
    extensions: [AshGraphql.Resource],
    authorizers: [Ash.Policy.Authorizer],
    domain: Cgc2046.Api

  alias Cgc2046.Workflows.{Engine, SignalLog, WorkflowDefinition}

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

  multitenancy do
    strategy(:attribute)
    attribute(:workspace_id)
    global?(true)
  end

  relationships do
    belongs_to(:definition, Cgc2046.Workflows.WorkflowDefinition,
      source_attribute: :definition_id,
      destination_attribute: :id,
      allow_nil?: false
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

      # definition 归属校验（/check SC2-004）：definition_id 必须属于当前 tenant 且为
      # published 版本，definition_version 必须匹配——对照 WorkflowDefinition.new_version
      # 的 source.workspace_id != tenant 守卫，杜绝跨租户绑定执行
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
                    "definition version #{definition_version} does not match published version #{defn.version}"
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

      change(fn changeset, _context ->
        case Ash.Changeset.get_data(changeset, :status) do
          :pending ->
            changeset
            |> Ash.Changeset.force_change_attribute(:status, :running)
            |> Ash.Changeset.force_change_attribute(:started_at, DateTime.utc_now())

          status ->
            Ash.Changeset.add_error(changeset, "cannot start from status=#{status}")
        end
      end)
    end

    # pending → running/succeeded/waiting/failed：一步启动 + 执行闭环（阶段 4 #37）。
    # 与纯状态机 :start 不同：本 action 调 Engine.run 执行 node_def，
    # 按结果流转——succeeded 直接终态，waiting 自动 hibernate 后挂起。
    update :start_run do
      description("启动并执行：pending → running → succeeded | waiting | failed")
      require_atomic?(false)
      accept([])
      change(optimistic_lock(:version))

      change(fn changeset, _context ->
        case Ash.Changeset.get_data(changeset, :status) do
          :pending ->
            run_started =
              changeset
              |> Ash.Changeset.force_change_attribute(:status, :running)
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

          status ->
            Ash.Changeset.add_error(changeset, "cannot start_run from status=#{status}")
        end
      end)
    end

    # running → waiting：执行到人工步骤挂起
    update :wait do
      description("挂起等待外部信号：running → waiting")
      require_atomic?(false)
      accept([])
      change(optimistic_lock(:version))

      change(fn changeset, _context ->
        case Ash.Changeset.get_data(changeset, :status) do
          :running ->
            Ash.Changeset.force_change_attribute(changeset, :status, :waiting)

          status ->
            Ash.Changeset.add_error(changeset, "cannot wait from status=#{status}")
        end
      end)
    end

    # waiting → running：信号放行后恢复执行
    update :resume do
      description("信号放行恢复执行：waiting → running")
      require_atomic?(false)
      accept([])
      change(optimistic_lock(:version))

      change(fn changeset, _context ->
        case Ash.Changeset.get_data(changeset, :status) do
          :waiting ->
            Ash.Changeset.force_change_attribute(changeset, :status, :running)

          status ->
            Ash.Changeset.add_error(changeset, "cannot resume from status=#{status}")
        end
      end)
    end

    # waiting → running/succeeded/failed：信号放行 + 恢复执行闭环（阶段 4 #37）。
    # 写 SignalLog 审计 → Engine.resume（thaw → feed_signal）→ 按结果流转。
    update :resume_signal do
      description("信号放行恢复执行：waiting → running → succeeded | waiting | failed")
      require_atomic?(false)
      argument(:signal_type, :string, allow_nil?: false)
      argument(:payload, :map, default: %{})
      argument(:actor_id, :uuid)
      change(optimistic_lock(:version))

      change(fn changeset, _context ->
        case Ash.Changeset.get_data(changeset, :status) do
          :waiting ->
            resume_signal_execute(changeset)

          status ->
            Ash.Changeset.add_error(changeset, "cannot resume_signal from status=#{status}")
        end
      end)
    end

    # running/waiting → succeeded：执行完成，写入 facts + finished_at
    update :complete do
      description("执行完成：running/waiting → succeeded")
      require_atomic?(false)
      change(optimistic_lock(:version))
      accept([:facts])

      change(fn changeset, _context ->
        case Ash.Changeset.get_data(changeset, :status) do
          status when status in [:running, :waiting] ->
            changeset
            |> Ash.Changeset.force_change_attribute(:status, :succeeded)
            |> Ash.Changeset.force_change_attribute(:finished_at, DateTime.utc_now())

          status ->
            Ash.Changeset.add_error(changeset, "cannot complete from status=#{status}")
        end
      end)
    end

    # running/waiting → failed：执行失败
    update :fail do
      description("执行失败：running/waiting → failed")
      require_atomic?(false)
      accept([])
      change(optimistic_lock(:version))

      change(fn changeset, _context ->
        case Ash.Changeset.get_data(changeset, :status) do
          status when status in [:running, :waiting] ->
            changeset
            |> Ash.Changeset.force_change_attribute(:status, :failed)
            |> Ash.Changeset.force_change_attribute(:finished_at, DateTime.utc_now())

          status ->
            Ash.Changeset.add_error(changeset, "cannot fail from status=#{status}")
        end
      end)
    end

    # pending/running/waiting → cancelled：人工取消
    update :cancel do
      description("取消执行：pending/running/waiting → cancelled")
      require_atomic?(false)
      accept([])
      change(optimistic_lock(:version))

      change(fn changeset, _context ->
        case Ash.Changeset.get_data(changeset, :status) do
          status when status in [:pending, :running, :waiting] ->
            changeset
            |> Ash.Changeset.force_change_attribute(:status, :cancelled)
            |> Ash.Changeset.force_change_attribute(:finished_at, DateTime.utc_now())

          status ->
            Ash.Changeset.add_error(changeset, "cannot cancel from status=#{status}")
        end
      end)
    end

    # pending/waiting → expired：超时（阶段 4 deadline 唤醒路径）
    update :expire do
      description("超时过期：pending/waiting → expired")
      require_atomic?(false)
      accept([])
      change(optimistic_lock(:version))

      change(fn changeset, _context ->
        case Ash.Changeset.get_data(changeset, :status) do
          status when status in [:pending, :waiting] ->
            changeset
            |> Ash.Changeset.force_change_attribute(:status, :expired)
            |> Ash.Changeset.force_change_attribute(:finished_at, DateTime.utc_now())

          status ->
            Ash.Changeset.add_error(changeset, "cannot expire from status=#{status}")
        end
      end)
    end

    defaults([:read])

    # #40 展示页：按 id 取 run 详情（GraphQL read_one）
    read :get_by_id do
      get_by([:id])
    end
  end

  postgres do
    table("workflow_runs")
    repo(Cgc2046.Repo)
  end

  policies do
    # 读取（H3）：经 definition → workspace → memberships 路径，仅成员或平台管理员
    policy action_type(:read) do
      authorize_if(relates_to_actor_via([:definition, :workspace, :memberships, :user]))
      authorize_if(actor_attribute_equals(:is_platform_admin, true))
    end

    # #38 StepRole 授权：start_run（auto 步骤引擎执行不授权，§4.3）与 resume_signal
    # （manual 信号发起人，StepRole 判定在 action 内）对成员放开；expire 仍限 Owner/Admin。
    # bypass：命中则跳过后续 update policy（成员放行），失败则继续（非成员 → 后续拒绝）。
    bypass action([:start_run, :resume_signal]) do
      authorize_if(relates_to_actor_via([:definition, :workspace, :memberships, :user]))
      authorize_if(actor_attribute_equals(:is_platform_admin, true))
    end

    # 写操作：Owner/Admin（多角色并集）或平台管理员
    policy action_type([:create, :update]) do
      authorize_if(Cgc2046.Policies.WorkspaceActorIsOwnerOrAdmin)
      authorize_if(actor_attribute_equals(:is_platform_admin, true))
    end
  end

  graphql do
    type(:workflow_run)

    queries do
      list(:list_workflow_runs, :read, description: "工作台的 workflow run 列表（#40 展示页）")
      read_one(:get_workflow_run, :get_by_id, description: "按 id 获取 workflow run 详情（#40）")
    end
  end

  # --- 产品层执行闭环辅助（阶段 4 #37） ---------------------------------------

  # start_run：从 definition 读 node_def，调 Engine.run（waiting 自动 hibernate）。
  # 返回 {status, changeset[, facts]}——status ∈ :ok | :waiting | :error
  defp start_run_execute(changeset) do
    tenant = changeset.tenant
    run_id = Ash.Changeset.get_data(changeset, :id)
    definition_id = Ash.Changeset.get_data(changeset, :definition_id)
    partition = Ash.Changeset.get_data(changeset, :partition_id)
    input = Ash.Changeset.get_data(changeset, :input_snapshot)

    case Ash.get(WorkflowDefinition, definition_id, tenant: tenant, authorize?: false) do
      {:ok, defn} ->
        case Engine.run(defn.node_def, input,
               run_id: run_id,
               partition: partition,
               tenant: tenant
             ) do
          {:ok, facts, _workflow} -> {:ok, changeset, facts}
          {:waiting, facts, _workflow} -> {:waiting, changeset, facts}
          {:error, reason} -> {:error, changeset, reason}
        end

      {:error, _} ->
        {:error, changeset, :definition_not_found}
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
    actor_id = Ash.Changeset.get_argument(changeset, :actor_id)

    cond do
      is_nil(signal_type) ->
        Ash.Changeset.add_error(changeset, "signal_type is required")

      true ->
        # #38 StepRole 授权：manual 步骤信号发起人（领域模型 §4.3）。
        # actor_id 为 nil → 无角色 → 有 StepRole 配置则拒绝（安全方向）。
        step_key = String.replace_prefix(signal_type, "workflow.", "")

        case Engine.authorize_signal(%{id: actor_id}, tenant, definition_id, step_key) do
          :ok ->
            resume_signal_authorized(
              changeset,
              tenant,
              run_id,
              partition,
              signal_type,
              payload,
              actor_id
            )

          {:error, :unauthorized} ->
            Ash.Changeset.add_error(changeset, "unauthorized to signal step #{step_key}")
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
          {:ok, facts, _workflow} ->
            changeset
            |> Ash.Changeset.force_change_attribute(:status, :succeeded)
            |> Ash.Changeset.force_change_attribute(:facts, facts)
            |> Ash.Changeset.force_change_attribute(:finished_at, DateTime.utc_now())

          {:waiting, facts, _workflow} ->
            changeset
            |> Ash.Changeset.force_change_attribute(:status, :waiting)
            |> Ash.Changeset.force_change_attribute(:facts, facts)

          {:error, _reason} ->
            changeset
            |> Ash.Changeset.force_change_attribute(:status, :failed)
            |> Ash.Changeset.force_change_attribute(:finished_at, DateTime.utc_now())
        end

      {:error, _} ->
        Ash.Changeset.add_error(changeset, "failed to record signal log")
    end
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
end
