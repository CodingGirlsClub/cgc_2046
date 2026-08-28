defmodule Cgc2046.Workflows.LearningProgress do
  @moduledoc """
  学习 workflow 进度投影的纯函数(切片 H U4, #180)。

  分子分母切 learning_records(设计 §3 Q13):issue 三态由记录派生——
  Todo(无 done 记录)/ In Progress(部分 done)/ Done(全部 done);
  currentIssue = 首个非 Done issue(无则课程 Done 态)。

  `project/6` 数据源 = course content(Curriculum.Output.data,经
  `CourseContent.issues/1` 解析)+ 该 user 学习记录列表(宽存引用,
  不在内容中的记录不参与分母——id 稳定纪律下的内容编辑安全)。

  另承载学习 run 停滞口径(E-9 #122 补差同源常量):`stagnant_cutoff/1`
  同时是 `LearningProgressWorker` 停滞提醒(D6-③)与 E-10 对账规则⑦
  `learning_run_stalled` 的判定基准——两消费方只引用,不各自定义阈值。
  """

  alias Cgc2046.Workflows.CourseContent

  # 停滞阈值(天,D6-③):LearningProgressWorker 提醒与 ReconciliationScanWorker
  # 规则⑦同源——修改只在此一处。
  @stagnation_threshold_days 7

  @doc "学习 run 停滞阈值(天;D6-③ 口径,提醒与对账规则⑦同源)"
  def stagnation_threshold_days, do: @stagnation_threshold_days

  @doc """
  停滞判定 cutoff:`updated_at` 早于 cutoff(严格小于,7 天)视为停滞。
  与 LearningProgressWorker 停滞提醒(D6-③)同一判定;E-10 对账规则⑦复用。
  """
  @spec stagnant_cutoff(DateTime.t()) :: DateTime.t()
  def stagnant_cutoff(now \\ DateTime.utc_now()) do
    DateTime.add(now, -@stagnation_threshold_days, :day)
  end

  @typep learning_record_input :: %{optional(String.t() | atom()) => term()}

  @doc """
  issue 级进度投影。

  - `content`:course content map(`%{"goals" => [...], "issues" => [...]}`)或
    nil(无内容课程——doneIssues/totalIssues 记 0,currentIssueTitle nil)
  - `records`:该 (course, user) 的学习记录列表;`recorded_done?` 默认按
    `record.done == true` 判定

  返回:`%{done_issues, total_issues, current_issue_id, current_issue_title}`
  (issue key 派生函数 `issue_key/2` 单源,KTD6)。
  """
  @spec project_issues(term(), [learning_record_input()]) :: %{
          done_issues: non_neg_integer(),
          total_issues: non_neg_integer(),
          current_issue_id: String.t() | nil,
          current_issue_title: String.t() | nil
        }
  def project_issues(content, records) do
    issues = CourseContent.issues(content)
    done_items = done_item_ids(records)

    {done_count, current} =
      Enum.reduce(issues, {0, nil}, fn issue, {count, current} ->
        if current == nil and not issue_done?(issue, done_items) do
          {count, issue}
        else
          if issue_done?(issue, done_items), do: {count + 1, current}, else: {count, current}
        end
      end)

    %{
      done_issues: done_count,
      total_issues: length(issues),
      current_issue_id: current && current["id"],
      current_issue_title: current && current["title"]
    }
  end

  @doc """
  run 级投影(myLearningRuns 消费面):issue 级投影 + run 元信息。

  `project/6` 是 U4 的新投影入口(替换旧 `project/7` node_def/steps 口径);
  GraphQL resolver(U7 域,本批禁区)随后切换到此形状。
  """
  @spec project(String.t(), String.t(), String.t() | nil, atom() | String.t(), term(), [
          learning_record_input()
        ]) ::
          %{
            run_id: String.t(),
            enrollment_id: String.t(),
            target_title: String.t() | nil,
            status: String.t(),
            done_issues: non_neg_integer(),
            total_issues: non_neg_integer(),
            current_issue_id: String.t() | nil,
            current_issue_title: String.t() | nil
          }
  def project(run_id, enrollment_id, target_title, status, content, records) do
    issues = project_issues(content, records)

    %{
      run_id: run_id,
      enrollment_id: enrollment_id,
      target_title: target_title,
      status: to_string(status),
      done_issues: issues.done_issues,
      total_issues: issues.total_issues,
      current_issue_id: issues.current_issue_id,
      current_issue_title: issues.current_issue_title
    }
  end

  @doc """
  全 issue Done 判定(U4 worker 完成条件):有内容且每张 issue 的全部
  checklist 条目都有 done 记录。无内容课程返回 false(不判完成)。
  """
  @spec all_issues_done?(term(), [learning_record_input()]) :: boolean()
  def all_issues_done?(content, records) do
    issues = CourseContent.issues(content)

    issues != [] and Enum.all?(issues, &issue_done?(&1, done_item_ids(records)))
  end

  @doc """
  issue key 展示层派生(KTD6):课程 slug 短码大写截短 + issue 序号(1 起,
  补零两位),如 "PY-02"。不入库;Web 与扩展共用此形状约定。
  """
  @spec issue_key(String.t() | nil, non_neg_integer()) :: String.t()
  def issue_key(slug, index) when is_integer(index) and index >= 1 do
    "#{course_code(slug)}-#{:io_lib.format("~2..0B", [index])}"
  end

  def issue_key(_slug, _index), do: ""

  # --- 私有实现 ----------------------------------------------------------------

  # 该 issue 全部 checklist 条目均有 done 记录(记录按 (issue_id, item_id) 索引)
  defp issue_done?(issue, done_items) do
    item_ids = CourseContent.checklist_item_ids(issue)

    item_ids != [] and Enum.all?(item_ids, &MapSet.member?(done_items, {issue["id"], &1}))
  end

  defp done_item_ids(records) when is_list(records) do
    records
    |> Enum.filter(fn record ->
      Map.get(record, :done) == true or Map.get(record, "done") == true
    end)
    |> MapSet.new(fn record ->
      issue_id = Map.get(record, :issue_id) || Map.get(record, "issue_id")
      item_id = Map.get(record, :item_id) || Map.get(record, "item_id")
      {issue_id, item_id}
    end)
  end

  defp done_item_ids(_records), do: MapSet.new()

  # 课程短码:slug 非空 → 字母数字段大写截短(前 4 字符);无 slug → "C"
  defp course_code(nil), do: "C"

  defp course_code(slug) when is_binary(slug) do
    code =
      slug
      |> String.replace(~r/[^a-zA-Z0-9]/, "")
      |> String.upcase()
      |> String.slice(0, 4)

    if code == "", do: "C", else: code
  end
end
