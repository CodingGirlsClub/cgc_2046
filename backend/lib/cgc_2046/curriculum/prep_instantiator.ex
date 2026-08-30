defmodule Cgc2046.Curriculum.PrepInstantiator do
  @moduledoc """
  课程教研 workflow 实例化（role-agent-journeys-v2 S5，R22；领域模型 §2.3
  课程教研流程落地）。

  `course.created` 信号 → 为该课程幂等种一个 `type=:course_preparation` 的
  WorkflowRun——**每门新课程恰有一个 prep run**（实例 key
  `course_prep_<course_id>`，`WorkflowRun.find_or_create_and_start/4` 非终态
  去重；信号重投命中已有 run 不重复创建）。

  与 learning run 同为**协议而非 DAG**（TD3）：实例化即 `:start`
  （pending → running），不经 Engine；prep_state 状态机与策略快照见
  `Cgc2046.Curriculum.Prep`。策略快照（`prep_policy` 默认值）随
  input_snapshot 在创建时固化（R22）。

  ## 幂等（state_based，骨架不写 claim）

  与 `Curriculum.Instantiator` 同款：同一课程已有非终态 prep run → 返回已有
  run。consumer_key 显式钉死 `"course_prep_instantiator"`（新订阅方必填，
  不随模块 leaf 改名漂移）。

  ## 守卫

  仅当课程仍为 `draft` 时实例化——created 信号的正常时点课程必为 draft；
  该守卫挡住「首投失败、课程已发布后重投」种出的永不可完成 run
  （课程已 open，publish 步的 launch CAS 必然失败）。存量课程（本特性前创建）
  无 created 信号，不产生 prep run，launch 教研门对其放行。

  run 创建成功后回写 `course.workflow_run_id`（产物引用链——课程详情
  `workflowRun` 关系与 `save_course_content` 的 facts 镜像都锚在它上；
  失败只记日志不阻塞，可对账补写）。

  订阅骨架（订阅生命周期 / DOWN 重订阅 / rescue 壳）由
  `Cgc2046.Workflows.SignalSubscriber` 统一持有。
  """

  use Cgc2046.Workflows.SignalSubscriber,
    patterns: ["course.created"],
    idempotency: :state_based,
    consumer_key: "course_prep_instantiator"

  require Ash.Query
  require Logger

  alias Cgc2046.Courses.Course
  alias Cgc2046.Curriculum.Prep
  alias Cgc2046.Workflows.{WorkflowDefinition, WorkflowRun}

  # --- 公开 API --------------------------------------------------------------

  @doc """
  课程教研 workflow 实例化：创建 course_preparation WorkflowRun + `:start`。

  - `workspace_id`：租户（= Course 的 workspace_id）
  - `definition_id`：已 published 的 course_preparation WorkflowDefinition ID
  - `input`：run 输入（含 `course_id`/`title`；`prep_policy` 缺省补默认值——
    快照于 input_snapshot 固化，R22）

  幂等：同一课程已有非终态 prep run → 返回已有 run（不重复创建）。
  """
  @spec launch(String.t(), String.t(), map()) :: {:ok, WorkflowRun.t()} | {:error, term()}
  def launch(workspace_id, definition_id, input)
      when is_binary(workspace_id) and is_binary(definition_id) and is_map(input) do
    with {:ok, defn} <- fetch_definition(workspace_id, definition_id),
         :ok <- ensure_prep_definition(defn),
         {:ok, run, _status} <-
           WorkflowRun.find_or_create_and_start(
             workspace_id,
             defn,
             Map.put_new(input, "prep_policy", Prep.default_policy()),
             # 教研 run 无平台侧执行步骤：纯 :start（pending → running），不经
             # :start_run 的 Engine.run（协议而非 DAG，learning run 同款）。
             key: Prep.instance_key(input_course_id(input)),
             start_action: :start
           ) do
      {:ok, run}
    end
  end

  # --- 信号处理 ----------------------------------------------------------------

  @impl Cgc2046.Workflows.SignalSubscriber
  def handle(_type, %{"course_id" => course_id} = data) when is_binary(course_id) do
    with {:ok, %Course{} = course} <- fetch_course(course_id),
         :ok <- ensure_draft(course),
         {:ok, %WorkflowDefinition{} = defn} <- fetch_prep_definition(course.workspace_id) do
      input = %{"course_id" => course.id, "title" => data["title"] || course.title}

      # advisor R2（R1-01b）：producer 参加与懒开次周期**同一** course 锁协议
      # （`Prep.spawn_under_course_lock/3`）——锁内重读最新 status（仍 draft
      # 才建；锁外 ensure_draft 只作快速拒绝，stale struct 窗口由锁内裁决
      # 封死）+ 锁内重读 active run（并发幂等）。
      course
      |> Prep.spawn_under_course_lock(["draft"], fn ->
        launch(course.workspace_id, defn.id, input)
      end)
      |> case do
        {:ok, %WorkflowRun{} = run} ->
          link_prep_run(course, run)

        {:error, reason} ->
          # terminal 状态的幂等放弃（课程已 launch/close/cancel——重投无意义）
          # 与 DB 失败同为 best-effort：记日志不抛错（信号路径原语义）
          Logger.error(
            "PrepInstantiator launch failed for course #{course_id}: #{inspect(reason)}"
          )

          :ok
      end
    else
      {:error, reason} ->
        Logger.warning(
          "PrepInstantiator skipped instantiation for course #{course_id}: #{inspect(reason)}"
        )

        :ok

      # 无已 published course_preparation 定义（read_first 返回 nil）是合法场景，
      # 走 skipped 而非 unexpected（同 curriculum instantiator 模式）。
      {:ok, nil} ->
        Logger.warning(
          "PrepInstantiator skipped instantiation for course #{course_id}: :course_preparation_definition_not_found"
        )

        :ok
    end
  end

  def handle(_type, data) do
    Logger.warning("PrepInstantiator received signal without course id: #{inspect(data)}")
    :ok
  end

  # --- 私有实现 --------------------------------------------------------------

  defp fetch_definition(workspace_id, definition_id) do
    case Ash.get(WorkflowDefinition, definition_id, tenant: workspace_id, authorize?: false) do
      {:ok, defn} -> {:ok, defn}
      {:error, _} -> {:error, :definition_not_found}
    end
  end

  defp ensure_prep_definition(%WorkflowDefinition{type: :course_preparation, status: :published}),
    do: :ok

  defp ensure_prep_definition(%WorkflowDefinition{type: type, status: status}) do
    {:error, {:definition_not_course_preparation_published, type, status}}
  end

  # 信号先于创建事务提交发布时课程可能尚不存在（outbox 结构保证投递在提交后，
  # 此为防御分支）；PK 全局唯一，global?(true) 下可不带 tenant。
  defp fetch_course(course_id) do
    case Ash.get(Course, course_id, authorize?: false) do
      {:ok, %Course{} = course} -> {:ok, course}
      _ -> {:error, :not_found}
    end
  end

  # 仅 draft 实例化（见 moduledoc 守卫段）
  defp ensure_draft(%Course{status: :draft}), do: :ok
  defp ensure_draft(%Course{status: status}), do: {:error, {:course_not_draft, status}}

  # 异步路径：取该租户已 published 的 course_preparation 定义。多个时取最新
  # （version desc，inserted_at desc 兜底）——Curriculum.Instantiator 同款：
  # read_one 无排序时 Postgres 返回任意行；read_one + sort 多行报
  # MultipleResults，取排序首行必须用 read_first。公开供测试直接驱动实例化。
  @doc false
  def fetch_prep_definition(workspace_id) do
    WorkflowDefinition
    |> Ash.Query.filter(type == :course_preparation and status == :published)
    |> Ash.Query.sort(version: :desc, inserted_at: :desc)
    |> Ash.read_first(tenant: workspace_id, authorize?: false)
  end

  # run 创建成功 → 回写 course.workflow_run_id（产物引用链；失败只记日志不阻塞，
  # 同 Curriculum.Instantiator.link_curriculum_run 容错语义）。
  @doc false
  def link_prep_run(course, run) do
    case course
         |> Ash.Changeset.for_update(:link_curriculum_run, %{workflow_run_id: run.id},
           tenant: course.workspace_id,
           authorize?: false
         )
         |> Ash.update(tenant: course.workspace_id, authorize?: false) do
      {:ok, _} ->
        :ok

      {:error, reason} ->
        Logger.error(
          "PrepInstantiator link_prep_run failed for course #{course.id}: #{inspect(reason)}"
        )

        :ok
    end
  end

  defp input_course_id(input) do
    Map.get(input, "course_id") || Map.get(input, :course_id)
  end
end
