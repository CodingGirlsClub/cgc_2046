defmodule Cgc2046.Learning.Analytics do
  @moduledoc """
  课程学习分析聚合(role-agent-journeys-v2 S10,R49/R50;AE14):
  tutor ∪ owner/admin 的教学数据回流聚合读面。

  数据范围:课程全部 learning run(`input_snapshot["course_id"]` 锚定的课程级
  查询——无 user 过滤)+ 这些 run 的全部不可变 LearningAttempt + 课程**当前
  published revision** 的 objectives。

  返回形状(消费方 = `get_course_learning_analytics` 工具):

  - `run_stats`:`%{total_runs, active_runs, completed_runs, completion_rate}`
    ——completion_rate = completed / total(一切 learning run 创建即 start,
    「started」= total),零 run 时 null(不除零)。
  - `objectives`:当前 revision 逐 objective 聚合行(objective_id/title/
    required + 掌握四态计数 mastered/developing/needs_review/unassessed +
    total_attempts/qualifying_passes/low_confidence_attempts/pass_rate/
    avg_attempts_to_first_mastery/last_activity_at)。**状态按 run 计**
    (一个 run 的 objective 状态 = 该 run attempts 经 Mastery 投影的条目;
    判定 rubric 用 attempt 所属 run 绑定 revision 的 objective——旧版 run
    不按新版 rubric 重判)。旧 revision 的 objective 仅在 id 与当前版本
    匹配时聚合到当前行;从新版移除的 objective 的 attempts 归入
    `orphan_objectives` 汇总行(不入任何当前行)。
  - `orphan_objectives`:`%{objective_ids, total_attempts, last_activity_at}`
    ——当前 revision 已不存在 objective 的 attempt 汇总(恒在,零时
    total_attempts=0)。
  - `drop_off`:`%{stale_run_count}` —— 非终态 run 中最后活动时间(最新
    attempt `created_at`,零 attempt 回退 run `inserted_at`)严格早于
    `Runs.stagnant_cutoff/1`(7 天,R50 口径同源)的条数;逐 objective 的
    流失位置由各行 `last_activity_at` 承载。
  - `generated_at`:聚合生成时间(可注入,测试用)。

  **红线(R49):纯聚合计数,永不返回 evidence / rubric_results / rationale
  正文**——分析面不含任何聊天/证据内容(服务端本无聊天;证据正文归
  LearningAttempt 账本,本模块只读其计数字段)。

  模块分两层:`for_course/2` 负责 IO(读取后即刻忘记证据字段),
  `compute/5` 为纯函数(注入 runs/attempts/revisions/now,可直测)。

  v2 适配(S10):run×revision 锚 = `input_snapshot["course_revision_id"]`
  (非旧版引擎列);Attempt = `Learning.Attempt`;revision =
  `Curriculum.CourseRevision`;objectives 取
  `Curriculum.Content.objectives/1`。
  """

  require Ash.Query

  alias Cgc2046.Curriculum.{Content, CourseRevision}
  alias Cgc2046.Courses.Course
  alias Cgc2046.Learning.{Attempt, Mastery, Runs}
  alias Cgc2046.Workflows.WorkflowRun

  @active_statuses [:pending, :running, :waiting]

  @doc """
  课程学习分析聚合(IO 层):读取课程全部 learning run + attempts + 涉及
  revision 后委托 `compute/5` 纯聚合。
  """
  @spec for_course(Course.t(), keyword()) :: map()
  def for_course(%Course{} = course, opts \\ []) do
    now = Keyword.get(opts, :now, DateTime.utc_now())
    workspace_id = course.workspace_id

    runs = fetch_runs(workspace_id, course.id)
    attempts = fetch_attempts(workspace_id, Enum.map(runs, & &1.id))
    revisions = fetch_revisions(workspace_id, involved_revision_ids(runs, course))

    current_revision =
      course.current_revision_id && Map.get(revisions, course.current_revision_id)

    compute(runs, attempts, revisions, current_revision, now)
  end

  @doc """
  纯聚合(IO-free):输入 = 课程全部 learning run + 其 attempts +
  `%{revision_id => revision}` + 当前 published revision(可无)+ now。
  """
  @spec compute(
          [WorkflowRun.t()],
          [Attempt.t()],
          %{
            String.t() => CourseRevision.t()
          },
          CourseRevision.t() | nil,
          DateTime.t()
        ) :: map()
  def compute(runs, attempts, revisions, current_revision, now) do
    attempts_by_run = Enum.group_by(attempts, & &1.learning_run_id)
    objectives_by_revision = Map.new(revisions, fn {id, rev} -> {id, objectives_of(rev)} end)

    current_objectives =
      case current_revision do
        %CourseRevision{} = revision -> objectives_of(revision)
        _ -> []
      end

    current_ids = MapSet.new(Enum.map(current_objectives, & &1["id"]))

    # 每 run 掌握投影:objectives 取该 run 绑定 revision(v2 锚 = input_snapshot
    # 的 course_revision_id;未绑 revision 的宽限 run 无 objectives → 空投影,
    # 其 attempts 不存在——attempt 强制绑版)
    states_by_run =
      Map.new(runs, fn run ->
        objectives = Map.get(objectives_by_revision, run_revision_id(run), [])
        {run.id, Mastery.states(Map.get(attempts_by_run, run.id, []), objectives)}
      end)

    %{
      run_stats: run_stats(runs),
      objectives:
        Enum.map(
          current_objectives,
          &objective_row(
            &1,
            runs,
            attempts,
            attempts_by_run,
            objectives_by_revision,
            states_by_run
          )
        ),
      orphan_objectives: orphan_rollup(attempts, current_ids),
      drop_off: %{stale_run_count: stale_run_count(runs, attempts_by_run, now)},
      generated_at: now
    }
  end

  # --- run 级统计 ----------------------------------------------------------------

  defp run_stats(runs) do
    total = length(runs)
    active = Enum.count(runs, &(&1.status in @active_statuses))
    completed = Enum.count(runs, &(&1.status == :succeeded))

    %{
      total_runs: total,
      active_runs: active,
      completed_runs: completed,
      completion_rate: if(total > 0, do: Float.round(completed / total, 4), else: nil)
    }
  end

  # --- objective 级聚合 ------------------------------------------------------------

  defp objective_row(
         objective,
         runs,
         attempts,
         attempts_by_run,
         objectives_by_revision,
         states_by_run
       ) do
    objective_id = objective["id"]

    # 命中本 objective 的 attempts(按 objective_id 跨 run 聚合,含旧版 run)
    hits = Enum.filter(attempts, &(&1.objective_id == objective_id))

    # 掌握四态按 run 计:仅计入其绑定 revision 含本 objective 的 run
    state_counts =
      Enum.reduce(runs, %{mastered: 0, developing: 0, needs_review: 0, unassessed: 0}, fn run,
                                                                                          acc ->
        run_objectives = Map.get(objectives_by_revision, run_revision_id(run), [])

        if Enum.any?(run_objectives, &(&1["id"] == objective_id)) do
          state = states_by_run |> Map.get(run.id, %{}) |> Map.get(objective_id, %{})
          Map.update(acc, Map.get(state, :state, :unassessed), 1, &(&1 + 1))
        else
          acc
        end
      end)

    qualifying =
      Enum.count(hits, fn attempt ->
        run_objectives = Map.get(objectives_by_revision, attempt_revision_id(attempt), [])

        case Enum.find(run_objectives, &(&1["id"] == objective_id)) do
          nil -> false
          attempt_objective -> Mastery.qualifying?(attempt, attempt_objective)
        end
      end)

    %{
      objective_id: objective_id,
      title: objective["title"],
      required: Content.required_objective?(objective),
      mastered: state_counts.mastered,
      developing: state_counts.developing,
      needs_review: state_counts.needs_review,
      unassessed: state_counts.unassessed,
      total_attempts: length(hits),
      qualifying_passes: qualifying,
      low_confidence_attempts: Enum.count(hits, &(&1.confidence < Mastery.confidence_floor())),
      pass_rate: rate(qualifying, length(hits)),
      avg_attempts_to_first_mastery:
        avg_attempts_to_first_mastery(
          objective_id,
          runs,
          attempts_by_run,
          objectives_by_revision,
          states_by_run
        ),
      last_activity_at: latest_at(hits)
    }
  end

  # 平均「首次掌握所需评价次数」(重试热点反向口径):仅统计曾 ever_mastered 的
  # run;某 run 的值 = 该 run 内本 objective 按时间序首条 qualifying 的序号
  # (1 起计)。无人掌握 → null
  defp avg_attempts_to_first_mastery(
         objective_id,
         runs,
         attempts_by_run,
         objectives_by_revision,
         states_by_run
       ) do
    counts =
      Enum.flat_map(runs, fn run ->
        entry = states_by_run |> Map.get(run.id, %{}) |> Map.get(objective_id, %{})

        if Map.get(entry, :ever_mastered, false) do
          run_objectives = Map.get(objectives_by_revision, run_revision_id(run), [])
          objective = Enum.find(run_objectives, &(&1["id"] == objective_id))

          first_qualifying_index(
            Map.get(attempts_by_run, run.id, []),
            objective_id,
            objective
          )
        else
          []
        end
      end)

    case counts do
      [] -> nil
      _ -> Float.round(Enum.sum(counts) / length(counts), 2)
    end
  end

  # 首条 qualifying attempt 的 1 起序号;判据 = Mastery.qualifying?/2 单源
  # (数据矛盾防御:ever_mastered 为 true 必存在 qualifying,找不到时返回 [])
  defp first_qualifying_index(run_attempts, objective_id, objective) do
    run_attempts
    |> Enum.filter(&(&1.objective_id == objective_id))
    |> Enum.sort_by(& &1.created_at, &compare_time/2)
    |> Enum.with_index(1)
    |> Enum.find_value(fn {attempt, index} ->
      if objective && Mastery.qualifying?(attempt, objective), do: index, else: nil
    end)
    |> case do
      nil -> []
      index -> [index]
    end
  end

  # --- orphan / 流失 --------------------------------------------------------------

  # 当前 revision 已移除 objective 的 attempts 汇总(不计入任何当前行)
  defp orphan_rollup(attempts, current_ids) do
    orphans = Enum.reject(attempts, &MapSet.member?(current_ids, &1.objective_id))

    %{
      objective_ids: orphans |> Enum.map(& &1.objective_id) |> Enum.uniq() |> Enum.sort(),
      total_attempts: length(orphans),
      last_activity_at: latest_at(orphans)
    }
  end

  # R50 口径同源:阈值只引 `Runs.stagnant_cutoff/1`;最后活动时间规则同
  # `Runs.last_activity_at/1`(最新 attempt created_at,零 attempt 回退
  # run.inserted_at)——此处从已加载数据内存计算,不逐 run 再查库
  defp stale_run_count(runs, attempts_by_run, now) do
    cutoff = Runs.stagnant_cutoff(now)

    Enum.count(runs, fn run ->
      run.status in @active_statuses and
        DateTime.compare(run_last_activity_at(run, Map.get(attempts_by_run, run.id, [])), cutoff) ==
          :lt
    end)
  end

  defp run_last_activity_at(run, []) do
    run.inserted_at
  end

  defp run_last_activity_at(_run, attempts) do
    latest_at(attempts)
  end

  # --- 读取(IO) -------------------------------------------------------------------

  # 课程全部 learning run(任意状态;课程级锚定 = input_snapshot["course_id"],
  # 无 user 过滤——Runs 私有 runs_query 带 user 过滤故此处自建)
  defp fetch_runs(workspace_id, course_id) do
    WorkflowRun
    |> Ash.Query.filter(
      definition.type == :learning and input_snapshot["course_id"] == ^course_id
    )
    |> Ash.read!(authorize?: false, tenant: workspace_id)
  end

  defp fetch_attempts(_workspace_id, []), do: []

  defp fetch_attempts(workspace_id, run_ids) do
    Attempt
    |> Ash.Query.filter(learning_run_id in ^run_ids)
    |> Ash.read!(authorize?: false, tenant: workspace_id)
  end

  defp fetch_revisions(_workspace_id, []), do: %{}

  defp fetch_revisions(workspace_id, revision_ids) do
    CourseRevision
    |> Ash.Query.filter(id in ^revision_ids)
    |> Ash.read!(authorize?: false, tenant: workspace_id)
    |> Map.new(fn revision -> {revision.id, revision} end)
  end

  defp involved_revision_ids(runs, course) do
    [course.current_revision_id | Enum.map(runs, &run_revision_id/1)]
    |> Enum.reject(&is_nil/1)
    |> Enum.uniq()
  end

  # --- 小工具 ---------------------------------------------------------------------

  # v2 适配:run 绑定 revision = input_snapshot["course_revision_id"]
  defp run_revision_id(%WorkflowRun{input_snapshot: %{"course_revision_id" => revision_id}}),
    do: revision_id

  defp run_revision_id(_run), do: nil

  defp objectives_of(%CourseRevision{content: content}),
    do: Content.objectives(content || %{})

  # attempt 所属 run 的 revision = attempt.course_revision_id(账本行锚定,
  # 与 run 绑定同一版本——submit 工具落库时同源写入)
  defp attempt_revision_id(%Attempt{course_revision_id: revision_id}), do: revision_id

  defp latest_at([]), do: nil

  defp latest_at(attempts) do
    attempts
    |> Enum.map(& &1.created_at)
    |> Enum.reject(&is_nil/1)
    |> case do
      [] -> nil
      times -> Enum.max(times, &compare_time/2)
    end
  end

  defp compare_time(a, b), do: DateTime.compare(a, b) != :gt

  defp rate(_numerator, 0), do: nil
  defp rate(numerator, denominator), do: Float.round(numerator / denominator, 4)
end
