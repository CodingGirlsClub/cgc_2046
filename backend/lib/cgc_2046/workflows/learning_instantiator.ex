defmodule Cgc2046.Workflows.LearningInstantiator do
  @moduledoc """
  学习 workflow 实例化（E-7 #122；设计 docs/01-定稿设计/学习workflow详细设计.md v1.0）。

  学习是**协议而非 DAG**：执行在 Learner 侧 OpenClacky（BYO），平台不编排。
  本模块只做触发——`enrollment.completed` → 幂等种 learning run（实例化后即
  `running`，纯 `:start` 状态机流转，不经 Engine 执行 node_def）。

  - **实例 key**：`"enrollment_<enrollment_id>"`（一个报名 = 一个 learning run；
    expired 后重提 → 新 enrollment → 新 key）。
  - **幂等两层**：① `SignalIdempotency.claim`（键带消费者作用域后缀
    `:learning_instantiator`——裸键 `"enrollment.completed:<id>"` 已被
    `NotificationSubscriber` 占用，消费者作用域后缀是
    `SponsorshipEndedSubscriber`/`ResearchRunReaper` 既有惯例）；② find_or_create
    非终态 run（`ResearchInstantiator` 同款，终态后可重新实例化）。
  - **定义获取**：租户内已 published 的 `type=learning` 定义（多个取最新，
    version desc + inserted_at desc）。无 published 定义 → warning skip 供对账
    （E-10 规则：confirmed enrollment 无 learning run）。

  ## 信号订阅（生产路径）

  本模块同时是 GenServer：Application 启动时订阅 `enrollment.completed`，
  收到信号 → 校验链 → 实例化。测试直接调 `instantiate_from_signal/2`（同步，
  不依赖异步信号投递——同 `ResearchInstantiator` 测试纪律）。

  异步路径是 best-effort：任一环节失败只记日志不崩溃订阅进程（try/rescue 兜底）。
  """

  use GenServer

  require Ash.Query
  require Logger

  alias Cgc2046.Events.{Course, Enrollment, Event}
  alias Cgc2046.Workflows.{JidoAdapter, SignalIdempotency, WorkflowDefinition, WorkflowRun}

  @signal_patterns ["enrollment.completed"]
  @completed_signal "enrollment.completed"

  # --- 公开 API --------------------------------------------------------------

  @doc """
  学习 workflow 实例化：创建 learning WorkflowRun + `:start`（pending → running）。

  - `workspace_id`：租户（= Enrollment 所属 Event/Course 的 workspace_id）
  - `definition_id`：已 published 的学习 WorkflowDefinition ID
  - `input`：run 输入（含 `enrollment_id`/`user_id`/`event_id` 或 `course_id`/`title`；
    `enrollment_id` 是授权账本的锚——学员授权经它反查 Enrollment，设计 §4.1）

  幂等：同一 definition + instance key 已有非终态 run → 返回已有 run（不重复创建）。
  """
  @spec launch(String.t(), String.t(), map()) :: {:ok, WorkflowRun.t()} | {:error, term()}
  def launch(workspace_id, definition_id, input)
      when is_binary(workspace_id) and is_binary(definition_id) and is_map(input) do
    with {:ok, defn} <- fetch_definition(workspace_id, definition_id),
         :ok <- ensure_learning_definition(defn),
         {:ok, run} <- find_or_create_run(workspace_id, defn, input) do
      {:ok, run}
    end
  end

  # --- GenServer（生产信号订阅） ----------------------------------------------

  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @impl true
  def init(_opts) do
    # 订阅失败不阻塞启动（信号总线在 Application children 中先于本模块启动）。
    {:ok, %{subscriptions: subscribe_all(%{})}}
  end

  @impl true
  def handle_info({:DOWN, ref, :process, _pid, reason}, state) do
    case Map.pop(state.subscriptions, ref) do
      {{pattern, _sub_id}, subscriptions} ->
        # 转发进程崩溃（如测试沙箱下连接代理 :shutdown 退出）：重建该订阅。
        # GenServer 本体不受影响，监督树重启预算不被消耗。
        Logger.warning(
          "LearningInstantiator forwarder for #{pattern} down: #{inspect(reason)}; resubscribing"
        )

        {:noreply, %{state | subscriptions: subscribe_one(pattern, subscriptions)}}

      {nil, _} ->
        {:noreply, state}
    end
  end

  def handle_info(_other, state), do: {:noreply, state}

  defp subscribe_all(acc), do: Enum.reduce(@signal_patterns, acc, &subscribe_one/2)

  defp subscribe_one(pattern, acc) do
    case JidoAdapter.subscribe_detached(pattern, &handle_signal/1, nil) do
      {:ok, sub_id, monitor_ref} ->
        Map.put(acc, monitor_ref, {pattern, sub_id})

      {:error, reason} ->
        Logger.warning("LearningInstantiator subscribe #{pattern} failed: #{inspect(reason)}")
        acc
    end
  end

  # signal.data 形态（Enrollment create/confirm action 发布）：
  # %{"enrollment_id" => id, "workspace_id" => ..., "user_id" => ...,
  #   "event_id" => id | nil, "course_id" => id | nil, "idempotency_key" => ...}
  # 订阅回调在 JidoAdapter.subscribe 转发的独立进程中执行（非 GenServer 进程），
  # rescue 兜底防订阅进程崩溃（测试沙箱下异步 DB 访问会 raise）。
  defp handle_signal(signal) do
    data = Map.get(signal, :data) || %{}

    case Map.get(data, "enrollment_id") do
      enrollment_id when is_binary(enrollment_id) ->
        instantiate_from_signal(enrollment_id, data)

      _ ->
        Logger.warning(
          "LearningInstantiator received signal without enrollment id: #{inspect(data)}"
        )
    end

    :ok
  rescue
    e ->
      Logger.warning("LearningInstantiator signal handling failed: #{Exception.message(e)}")
      :ok
  end

  @doc """
  异步信号实例化入口（生产路径：GenServer 订阅回调 → 本函数；测试直接调用）。

  校验链（设计 §3）：enrollment 存在且 status=confirmed（孤儿防护）→ 反查
  entity（Event/Course）拿 workspace_id + title → 取该租户已 published 的学习
  定义 → claim 幂等键 → find_or_create run。任一环节失败返回 `:ok`
  （best-effort，不抛错；失败可见性交给对账扫描 E-10）。
  """
  @spec instantiate_from_signal(String.t(), map()) :: :ok
  def instantiate_from_signal(enrollment_id, _data) when is_binary(enrollment_id) do
    with {:ok, %Enrollment{} = enrollment} <- fetch_enrollment(enrollment_id),
         :ok <- ensure_confirmed(enrollment),
         {:ok, entity} <- fetch_entity(enrollment),
         {:ok, %WorkflowDefinition{} = defn} <- fetch_learning_definition(entity.workspace_id),
         :ok <- claim(enrollment_id, entity.workspace_id) do
      input = %{
        "enrollment_id" => enrollment.id,
        "user_id" => enrollment.user_id,
        "event_id" => enrollment.event_id,
        "course_id" => enrollment.course_id,
        "title" => entity_title(entity)
      }

      case launch(entity.workspace_id, defn.id, input) do
        {:ok, %WorkflowRun{}} ->
          :ok

        {:error, reason} ->
          Logger.error(
            "LearningInstantiator launch failed for enrollment #{enrollment_id}: #{inspect(reason)}"
          )

          :ok
      end
    else
      {:error, reason} ->
        Logger.warning(
          "LearningInstantiator skipped instantiation for enrollment #{enrollment_id}: #{inspect(reason)}"
        )

        :ok

      # 无已 published 学习定义（read_first 返回 nil）是合法场景，走 skipped 而非 unexpected
      # （同 research_instantiator.ex 模式；供 E-10 对账）。
      {:ok, nil} ->
        Logger.warning(
          "LearningInstantiator skipped instantiation for enrollment #{enrollment_id}: :learning_definition_not_found"
        )

        :ok

      # 幂等键已登记（重复投递）→ 跳过，不重复实例化。
      :duplicate ->
        :ok

      other ->
        Logger.warning(
          "LearningInstantiator unexpected instantiation result for enrollment #{enrollment_id}: #{inspect(other)}"
        )

        :ok
    end
  end

  # --- 私有实现 --------------------------------------------------------------

  # 孤儿防护：信号先于报名事务提交发布时，enrollment 可能不存在或未 confirmed。
  # Enrollment 是 global?(true) 租户资源，PK 全局唯一，可不带 tenant 读。
  defp fetch_enrollment(enrollment_id) do
    case Ash.get(Enrollment, enrollment_id, authorize?: false) do
      {:ok, %Enrollment{} = enrollment} -> {:ok, enrollment}
      {:ok, nil} -> {:error, :enrollment_not_found}
      {:error, _} -> {:error, :enrollment_not_found}
    end
  end

  defp ensure_confirmed(%Enrollment{status: :confirmed}), do: :ok

  defp ensure_confirmed(%Enrollment{status: status}),
    do: {:error, {:enrollment_not_confirmed, status}}

  # 反查 entity 拿 workspace_id + title（设计 §3 校验链；信号 payload 无 title）。
  defp fetch_entity(%Enrollment{event_id: event_id}) when is_binary(event_id) do
    case Ash.get(Event, event_id, authorize?: false) do
      {:ok, %Event{} = event} -> {:ok, event}
      _ -> {:error, :entity_not_found}
    end
  end

  defp fetch_entity(%Enrollment{course_id: course_id}) when is_binary(course_id) do
    case Ash.get(Course, course_id, authorize?: false) do
      {:ok, %Course{} = course} -> {:ok, course}
      _ -> {:error, :entity_not_found}
    end
  end

  defp fetch_entity(%Enrollment{}), do: {:error, :entity_not_found}

  defp entity_title(%Event{title: title}), do: title
  defp entity_title(%Course{title: title}), do: title

  defp fetch_definition(workspace_id, definition_id) do
    case Ash.get(WorkflowDefinition, definition_id, tenant: workspace_id, authorize?: false) do
      {:ok, defn} -> {:ok, defn}
      {:error, _} -> {:error, :definition_not_found}
    end
  end

  defp ensure_learning_definition(%WorkflowDefinition{type: :learning, status: :published}),
    do: :ok

  defp ensure_learning_definition(%WorkflowDefinition{type: type, status: status}) do
    {:error, {:definition_not_learning_published, type, status}}
  end

  # 幂等登记（设计 §2 层①）：消费者作用域键，重复投递返回 :already_claimed → :duplicate。
  defp claim(enrollment_id, workspace_id) do
    key = "#{@completed_signal}:#{enrollment_id}:learning_instantiator"

    case SignalIdempotency.claim(@completed_signal, key, workspace_id) do
      :ok -> :ok
      {:error, :already_claimed} -> :duplicate
    end
  end

  # 异步路径：取该租户已 published 的学习定义。多个时取最新（version desc，
  # inserted_at desc 兜底）——read_first 取排序首行（同 research 先例）。
  defp fetch_learning_definition(workspace_id) do
    WorkflowDefinition
    |> Ash.Query.filter(type == :learning and status == :published)
    |> Ash.Query.sort(version: :desc, inserted_at: :desc)
    |> Ash.read_first(tenant: workspace_id, authorize?: false)
  end

  # 幂等（设计 §2 层②）：同一 definition + instance key 已有非终态 run → 返回已有 run。
  defp find_or_create_run(workspace_id, defn, input) do
    key = instance_key(input)

    case existing_run(workspace_id, defn.id, key) do
      {:ok, %WorkflowRun{} = run} ->
        {:ok, run}

      {:ok, nil} ->
        create_and_start_run(workspace_id, defn, input, key)
    end
  end

  defp instance_key(input) do
    Map.get(input, "key") || Map.get(input, :key) ||
      "enrollment_#{Map.get(input, "enrollment_id") || Map.get(input, :enrollment_id)}"
  end

  defp existing_run(workspace_id, definition_id, key) do
    WorkflowRun
    |> Ash.Query.filter(
      definition_id == ^definition_id and
        status in [:pending, :running, :waiting] and
        input_snapshot["key"] == ^key
    )
    |> Ash.read_one(tenant: workspace_id, authorize?: false)
  end

  defp create_and_start_run(workspace_id, defn, input, key) do
    # ensure_confirmed 与 INSERT 之间的窗口内报名可能转 cancelled（取消联动属 E-2
    # 范围）——创建前重读 enrollment 二次校验（对齐 research BLOCKING 3 修复）；
    # 残余极小窗口由对账扫描（E-10）兜底。
    with {:ok, %Enrollment{} = enrollment} <- fetch_enrollment(input_enrollment_id(input)),
         :ok <- ensure_confirmed(enrollment) do
      attrs = %{
        definition_id: defn.id,
        definition_version: defn.version,
        input_snapshot: Map.put(input, "key", key)
      }

      # 学习 run 无平台侧执行步骤：纯 :start（pending → running），不经 :start_run
      # 的 Engine.run（设计 §5——协议而非 DAG）。
      with {:ok, run} <-
             WorkflowRun
             |> Ash.Changeset.for_create(:create, attrs, tenant: workspace_id, authorize?: false)
             |> Ash.create(tenant: workspace_id, authorize?: false),
           {:ok, started} <-
             run
             |> Ash.Changeset.for_update(:start, %{}, tenant: workspace_id, authorize?: false)
             |> Ash.update(tenant: workspace_id, authorize?: false) do
        {:ok, started}
      end
    end
  end

  defp input_enrollment_id(input) do
    Map.get(input, "enrollment_id") || Map.get(input, :enrollment_id)
  end
end
