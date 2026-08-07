defmodule Cgc2046.Workflows.ResearchInstantiator do
  @moduledoc """
  教研 workflow 实例化（Slice C #39，阶段 6）。

  Event/Course launch → 创建教研 WorkflowRun + start_run。领域模型 §2.3：
  每个 Event/Course 实例化一个教研 workflow 实例，instance key 为
  `"event_\#{id}"` / `"course_\#{id}"`。

  ## 幂等

  同一 Event/Course 已有非终态 run（pending/running/waiting）→ 返回已有 run，
  不重复创建。终态 run（succeeded/failed/cancelled/expired）后可重新实例化。

  ## 信号订阅（生产路径）

  本模块同时是 GenServer：Application 启动时订阅 `event.launched` /
  `course.launched` 信号，收到信号 → 解析实体/教研定义 → 调 `launch/4`。
  测试直接调 `launch/4`（同步，不依赖异步信号投递——信号总线异步投递在 POC
  已验证，测试不覆盖异步路径）。

  异步路径是 best-effort：信号不含租户，需按 entity_id 反查实体拿 workspace_id，
  再取该租户已 published 的教研定义（多个时取最新）。任一环节失败只记日志，
  不崩溃订阅进程（try/rescue 兜底——测试沙箱下异步 DB 查询会 raise，不能
  让订阅进程因此退出）。
  """

  use GenServer

  require Logger

  alias Cgc2046.Events.{Course, Event}
  alias Cgc2046.Workflows.{JidoAdapter, WorkflowDefinition, WorkflowRun}

  require Ash.Query

  @signal_patterns ["event.launched", "course.launched"]

  # --- 公开 API --------------------------------------------------------------

  @doc """
  教研 workflow 实例化：Event/Course launch → 创建 WorkflowRun + start_run。

  - `workspace_id`：租户（= Event/Course 的 workspace_id）
  - `definition_id`：已 published 的教研 WorkflowDefinition ID
  - `input`：run 输入（含 `key`/`event_id`/`course_id`/`title`/`research_requirements`）
  - `entity_type`：`:event | :course`，用于 instance key 前缀

  幂等：同一 Event/Course 已有非终态 run → 返回已有 run（不重复创建）。

  返回 `{:ok, run}`（waiting/succeeded/failed 均返回 run，调用方按 status 判定）
  或 `{:error, reason}`。
  """
  @spec launch(String.t(), String.t(), map(), atom()) ::
          {:ok, WorkflowRun.t()} | {:error, term()}
  def launch(workspace_id, definition_id, input, entity_type)
      when is_binary(workspace_id) and is_binary(definition_id) and is_map(input) and
             entity_type in [:event, :course] do
    with {:ok, defn} <- fetch_definition(workspace_id, definition_id),
         :ok <- ensure_research_definition(defn),
         {:ok, run} <- find_or_create_run(workspace_id, defn, input, entity_type) do
      {:ok, run}
    end
  end

  # --- GenServer（生产信号订阅） ----------------------------------------------

  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @impl true
  def init(_opts) do
    # 订阅 event/course launch 信号（异步投递，收到信号 → launch/4）。
    # 订阅失败不阻塞启动（信号总线在 Application children 中先于本模块启动）。
    Enum.each(@signal_patterns, fn pattern ->
      case JidoAdapter.subscribe(pattern, &handle_signal/1, nil) do
        {:ok, _sub_id} ->
          :ok

        {:error, reason} ->
          Logger.warning("ResearchInstantiator subscribe #{pattern} failed: #{inspect(reason)}")
      end
    end)

    {:ok, %{}}
  end

  # 信号 → 解析实体/教研定义 → launch/4。signal.data 形态（Event/Course launch
  # action 发布）：%{"event_id" => id, "title" => ..., "research_requirements" => ...}
  # 或 %{"course_id" => id, ...}。订阅回调在 JidoAdapter.subscribe 转发的独立进程
  # 中执行（非 GenServer 进程），rescue 兜底防订阅进程崩溃（测试沙箱下异步 DB
  # 访问会 raise）。
  defp handle_signal(signal) do
    data = Map.get(signal, :data) || %{}

    case {Map.get(data, "event_id"), Map.get(data, "course_id")} do
      {event_id, _} when is_binary(event_id) ->
        instantiate_from_signal(event_id, :event, data)

      {_, course_id} when is_binary(course_id) ->
        instantiate_from_signal(course_id, :course, data)

      _ ->
        Logger.warning("ResearchInstantiator received signal without entity id: #{inspect(data)}")
    end

    :ok
  rescue
    e ->
      Logger.warning("ResearchInstantiator signal handling failed: #{Exception.message(e)}")
      :ok
  end

  @doc """
  异步信号实例化入口（生产路径：GenServer 订阅回调 → 本函数；测试直接调用）。

  按 entity_id 反查实体 → 校验实体已 launch（status == :open，孤儿 run 防护：
  信号先于事务提交发布时，draft 实体不得实例化）→ 取该租户已 published 的教研
  定义 → `launch/4`。任一环节失败返回 `:ok`（best-effort，不抛错）。
  """
  @spec instantiate_from_signal(String.t(), atom(), map()) :: :ok
  def instantiate_from_signal(entity_id, entity_type, data) do
    with {:ok, entity} <- fetch_entity(entity_type, entity_id),
         :ok <- ensure_launched(entity),
         :ok <- ensure_research_enabled(entity),
         {:ok, %WorkflowDefinition{} = defn} <- fetch_research_definition(entity.workspace_id) do
      input =
        case entity_type do
          :event ->
            %{
              "event_id" => entity_id,
              "title" => data["title"],
              "research_requirements" => data["research_requirements"] || %{}
            }

          :course ->
            %{
              "course_id" => entity_id,
              "title" => data["title"],
              "research_requirements" => data["research_requirements"] || %{}
            }
        end

      # #13：不得丢弃 launch/4 返回值——创建成功但 start 失败（hibernate 写失败等）
      # 时 run 已落库但未启动，静默丢弃会让故障不可见。best-effort 语义保持
      # （异步路径不抛错），失败记 error 日志供对账。
      case launch(entity.workspace_id, defn.id, input, entity_type) do
        {:ok, %WorkflowRun{} = run} ->
          # #14：run 创建成功 → 回写实体 workflow_run_id（产物引用链；失败只记日志，
          # 不阻塞实例化——引用可对账补写）。
          link_research_run(entity, entity_type, run)

        {:error, reason} ->
          Logger.error(
            "ResearchInstantiator launch failed for #{entity_type} #{entity_id}: #{inspect(reason)}"
          )

          :ok
      end
    else
      {:error, reason} ->
        Logger.warning(
          "ResearchInstantiator skipped instantiation for #{entity_type} #{entity_id}: #{inspect(reason)}"
        )

        :ok

      other ->
        Logger.warning(
          "ResearchInstantiator unexpected instantiation result for #{entity_type} #{entity_id}: #{inspect(other)}"
        )

        :ok
    end
  end

  # --- 私有实现 --------------------------------------------------------------

  defp fetch_definition(workspace_id, definition_id) do
    case Ash.get(WorkflowDefinition, definition_id, tenant: workspace_id, authorize?: false) do
      {:ok, defn} -> {:ok, defn}
      {:error, _} -> {:error, :definition_not_found}
    end
  end

  defp ensure_research_definition(%WorkflowDefinition{type: :research, status: :published}),
    do: :ok

  defp ensure_research_definition(%WorkflowDefinition{type: type, status: status}) do
    {:error, {:definition_not_research_published, type, status}}
  end

  # 异步路径：按 entity_id 反查实体（PK 全局唯一，global?(true) 下可不带 tenant）。
  defp fetch_entity(:event, entity_id) do
    case Ash.get(Event, entity_id, authorize?: false) do
      {:ok, entity} -> {:ok, entity}
      {:error, _} -> {:error, :event_not_found}
    end
  end

  defp fetch_entity(:course, entity_id) do
    case Ash.get(Course, entity_id, authorize?: false) do
      {:ok, entity} -> {:ok, entity}
      {:error, _} -> {:error, :course_not_found}
    end
  end

  # 孤儿 run 防护：信号先于 launch 事务提交发布（change 回调在事务内，提交失败
  # 时事件仍为 draft 但信号已发），异步路径必须校验实体已 launch 才实例化。
  defp ensure_launched(%{status: :open}), do: :ok
  defp ensure_launched(%{status: status}), do: {:error, {:entity_not_launched, status}}

  # #6：教研开关门控——research_enabled=false 的活动/课程不实例化教研 run
  # （领域模型 §5.2：是否启用教研 workflow）。默认 true，仅显式关闭才拦截。
  defp ensure_research_enabled(%{research_enabled: true}), do: :ok

  defp ensure_research_enabled(%{research_enabled: false}),
    do: {:error, :research_disabled}

  # #14：run 创建成功后回写实体 workflow_run_id（产物引用链）。
  # 失败只记日志不阻塞——引用可对账补写（best-effort，同 launch 容错语义）。
  defp link_research_run(entity, _entity_type, run) do
    attrs = %{workflow_run_id: run.id}

    case entity
         |> Ash.Changeset.for_update(
           :link_research_run,
           attrs,
           tenant: entity.workspace_id,
           authorize?: false
         )
         |> Ash.update(tenant: entity.workspace_id, authorize?: false) do
      {:ok, _} ->
        :ok

      {:error, reason} ->
        Logger.error(
          "ResearchInstantiator link_research_run failed for #{entity.__struct__} #{entity.id}: #{inspect(reason)}"
        )

        :ok
    end
  end

  # 异步路径：取该租户已 published 的教研定义。多个时取最新（version desc，
  # inserted_at desc 兜底）——read_one 无排序时 Postgres 返回任意行，实例化
  # 会跑错 workflow（low-1）；且 read_one + sort 会因多行报 MultipleResults，
  # 取排序首行必须用 read_first。
  defp fetch_research_definition(workspace_id) do
    WorkflowDefinition
    |> Ash.Query.filter(type == :research and status == :published)
    |> Ash.Query.sort(version: :desc, inserted_at: :desc)
    |> Ash.read_first(tenant: workspace_id, authorize?: false)
  end

  # 幂等：同一 definition + instance key 已有非终态 run → 返回已有 run。
  # instance key 存于 input_snapshot["key"]（"event_#{id}" / "course_#{id}"）。
  defp find_or_create_run(workspace_id, defn, input, entity_type) do
    key = instance_key(entity_type, input)

    case existing_run(workspace_id, defn.id, key) do
      {:ok, %WorkflowRun{} = run} ->
        {:ok, run}

      {:ok, nil} ->
        create_and_start_run(workspace_id, defn, input, key)
    end
  end

  defp instance_key(entity_type, input) do
    case Map.get(input, "key") || Map.get(input, :key) do
      nil ->
        entity_id =
          Map.get(input, "event_id") || Map.get(input, :event_id) ||
            Map.get(input, "course_id") || Map.get(input, :course_id)

        "#{entity_type}_#{entity_id}"

      key ->
        key
    end
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
    attrs = %{
      definition_id: defn.id,
      definition_version: defn.version,
      input_snapshot: Map.put(input, "key", key)
    }

    with {:ok, run} <-
           WorkflowRun
           |> Ash.Changeset.for_create(:create, attrs, tenant: workspace_id, authorize?: false)
           |> Ash.create(tenant: workspace_id, authorize?: false),
         {:ok, started} <-
           run
           |> Ash.Changeset.for_update(:start_run, %{}, tenant: workspace_id, authorize?: false)
           |> Ash.update(tenant: workspace_id, authorize?: false) do
      {:ok, started}
    end
  end
end
