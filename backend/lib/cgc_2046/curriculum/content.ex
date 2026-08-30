defmodule Cgc2046.Curriculum.Content do
  @moduledoc """
  课程内容(issue 卡集)的形状契约纯函数族(切片 H U1, #180;schema v2 随
  role-agent-journeys-v2 S6 到达)。

  course content = `%{"goals" => [String.t()], "issues" => [issue]}`,issue 形状
  (设计 `课程issue学习闭环详细设计.md` §2 + S6 schema v2):

      %{
        "id" => "py-first-program",
        "kind" => "handwork",
        "title" => "写你的第一个程序",
        "story" => %{
          "as_a" => ..., "given" => [...], "goal" => ...,
          "materials" => [%{"title" => ..., "ref" => ...}],
          "checklist" => [%{"id" => "c1", "text" => ...}]
        },
        "objectives" => [
          %{
            "id" => "obj-hello",
            "title" => "能独立运行问候程序",
            "required" => true,
            "prereq_ids" => [],
            "materials" => [%{"title" => ..., "ref" => ...}],
            "activity" => "...", "assessment" => "...",
            "rubric" => [%{"id" => "r1", "text" => "程序能运行并输出问候"}]
          }
        ]
      }

  **schema v2(S6,R38)**:issue 的 `objectives` 字段——LearningObjective 是掌握
  单元(mastery unit),携带稳定 id、required 必修/选修标志、机器可读先修关系
  `prereq_ids`(课程级引用,必须存在且构成 DAG)、Activity/Assessment、非空
  Rubric 与材料。objective id 课程级唯一(非仅 issue 内),id 稳定纪律同 issue
  (发布后不改不删)。v1 的 `story.checklist` 保留至 S8(届时 objectives 成为
  掌握与评价的唯一粒度)。

  消费方:Curriculum.Output changeset 校验(U1)、PrepGate 发布结构门禁(S6,
  R26)、LearningProgress issue 级投影与完成判定(U4)。JSONB 只按 string keys
  校验(MCP `save_course_content` 经 Jason 解码是唯一写入口;
  Accounts.SponsorshipTier 同款先例)。

  id 稳定纪律(R2/KTD4):issue `id` 与 objective `id` 发布后不改不删;本模块
  只做形状与唯一性/DAG 校验,语义纪律由教研 Agent 指令承担。
  """

  @issue_kinds ["thoughtwork", "handwork"]

  @doc "issue kind 二分(证据在哪为界:thoughtwork 对话 / handwork 产物)。"
  @spec issue_kinds() :: [String.t()]
  def issue_kinds, do: @issue_kinds

  @doc """
  结构性校验 course content(保存时全规则 = v1 形状 + objectives 存在即校验):

  - `goals`:非空字符串数组
  - `issues`:非空数组,每张卡 `id`/`kind`/`title`/`story` 必填
    (`kind ∈ thoughtwork | handwork`)
  - `story.checklist`:非空数组,每条含非空 `id`/`text`
  - issue `id` 卡集内唯一;checklist item `id` issue 内唯一
  - `objectives`(存在时):见 `objective_violations/1`——保存时不强制存在,
    存在则全部 v2 规则必须过
  """
  @spec valid?(term()) :: boolean()
  def valid?(content) when is_map(content) do
    valid_v1?(content) and objective_violations(content) == []
  end

  def valid?(_content), do: false

  @doc """
  v1 形状校验(不含 objectives 规则):发布门禁的通用形状复核用——objective
  违规由 `objective_violations/1` 逐条另报,不并入通用形状违规文案。
  """
  @spec valid_v1?(term()) :: boolean()
  def valid_v1?(content) when is_map(content) do
    with true <- non_empty_goals?(content),
         {:ok, issues} <- issues_or_error(content),
         true <- Enum.all?(issues, &valid_issue?/1),
         true <- unique_issue_ids?(issues) do
      true
    else
      _ -> false
    end
  end

  def valid_v1?(_content), do: false

  @doc "合法 content 的 issue 列表;非法(缺失/非列表/空)返回 []。"
  @spec issues(term()) :: [map()]
  def issues(content) when is_map(content) do
    case content["issues"] do
      issues when is_list(issues) and issues != [] -> issues
      _ -> []
    end
  end

  def issues(_content), do: []

  @doc """
  content 内全部 LearningObjective(schema v2 掌握单元,跨 issue 平铺,R38)。
  issue 非 map 或 objectives 非 list 的条目跳过(形状违规由
  `objective_violations/1` 另报)。无 objectives 的 v1 内容返回 []。
  """
  @spec objectives(term()) :: [term()]
  def objectives(content) when is_map(content) do
    content
    |> issues()
    |> Enum.flat_map(fn
      %{"objectives" => objectives} when is_list(objectives) -> objectives
      _ -> []
    end)
  end

  def objectives(_content), do: []

  @doc """
  objective 是否必修(`required` 缺省 = true;显式 false 为选修;非法值按选修
  计,形状违规由 `objective_violations/1` 另报)。
  """
  @spec required_objective?(term()) :: boolean()
  def required_objective?(objective) when is_map(objective),
    do: Map.get(objective, "required", true) == true

  def required_objective?(_objective), do: false

  @doc """
  objectives 规则违例清单(schema v2,R38;content 无 objectives 时返回 []——
  保存时不强制 objectives,发布门禁另行硬性要求):

  - per-objective 形状:`id`/`title` 非空字符串;`required` 布尔(缺省 true);
    `prereq_ids` 为字符串数组;`activity`/`assessment` 为字符串(可空串);
    `materials` 为 `%{title, ref}` 数组;`rubric` 非空且条目 `{id, text}`、
    id 在 objective 内唯一;
  - 课程级:objective `id` 全课程唯一;`prereq_ids` 引用必须存在;
    先修关系构成 DAG(无环、无自引用)。
  """
  @spec objective_violations(term()) :: [String.t()]
  def objective_violations(content) when is_map(content) do
    issue_list = issues(content)

    malformed =
      issue_list
      |> Enum.filter(fn issue ->
        is_map(issue) and Map.has_key?(issue, "objectives") and not is_list(issue["objectives"])
      end)
      |> Enum.map(fn issue -> "issue \"#{issue["id"]}\" 的 objectives 须为数组" end)

    objectives = objectives(content)

    malformed ++
      Enum.flat_map(objectives, &objective_shape_violations/1) ++
      duplicate_id_violations(objectives) ++
      missing_prereq_violations(objectives) ++
      cycle_violations(objectives)
  end

  def objective_violations(_content), do: []

  @doc """
  issue 的 objectives 平铺并各带 `issue_id`(S8 投影按 issue 分组/展示锚点用;
  学习地图与 web 面板消费)。issue 非 map 或 objectives 非 list 的条目跳过
  (形状违规由 `objective_violations/1` 另报)。无 objectives 的 v1 内容返回 []。
  """
  @spec objectives_with_issue(term()) :: [map()]
  def objectives_with_issue(content) when is_map(content) do
    content
    |> issues()
    |> Enum.flat_map(fn
      %{"id" => issue_id, "objectives" => objectives}
      when is_binary(issue_id) and is_list(objectives) ->
        Enum.map(objectives, fn
          objective when is_map(objective) -> Map.put(objective, "issue_id", issue_id)
          other -> other
        end)

      _ ->
        []
    end)
  end

  def objectives_with_issue(_content), do: []

  @doc """
  issue key 展示层派生(KTD6):课程 slug 短码大写截短 + issue 序号(1 起,
  补零两位),如 "PY-02"。不入库;Web 与扩展共用此形状约定。
  (S8 自 Learning.Progress 搬入——issue key 是内容形状契约,不依赖学习记录。)
  """
  @spec issue_key(String.t() | nil, non_neg_integer()) :: String.t()
  def issue_key(slug, index) when is_integer(index) and index >= 1 do
    "#{course_code(slug)}-#{:io_lib.format("~2..0B", [index])}"
  end

  def issue_key(_slug, _index), do: ""

  @doc "课程短码:slug 非空 → 字母数字段大写截短(前 4 字符);无 slug → \"C\"。"
  @spec course_code(String.t() | nil) :: String.t()
  def course_code(nil), do: "C"

  def course_code(slug) when is_binary(slug) do
    code =
      slug
      |> String.replace(~r/[^a-zA-Z0-9]/, "")
      |> String.upcase()
      |> String.slice(0, 4)

    if code == "", do: "C", else: code
  end

  @doc "issue 的 checklist item id 列表(畸形返回 [];v1 内容兼容保留——checklist 的学习消费面已随 LearningRecord 退役)。"
  @spec checklist_item_ids(term()) :: [String.t()]
  def checklist_item_ids(issue) when is_map(issue) do
    case issue["story"] do
      %{"checklist" => checklist} when is_list(checklist) ->
        checklist
        |> Enum.flat_map(fn
          %{"id" => id} when is_binary(id) -> [id]
          _ -> []
        end)

      _ ->
        []
    end
  end

  def checklist_item_ids(_issue), do: []

  # --- 私有实现(v1) ------------------------------------------------------------

  defp non_empty_goals?(content) do
    case content["goals"] do
      goals when is_list(goals) and goals != [] ->
        Enum.all?(goals, &(is_binary(&1) and &1 != ""))

      _ ->
        false
    end
  end

  defp issues_or_error(content) do
    case content["issues"] do
      issues when is_list(issues) and issues != [] -> {:ok, issues}
      _ -> :error
    end
  end

  defp valid_issue?(issue) when is_map(issue) do
    with true <- non_empty_string?(issue["id"]),
         true <- issue["kind"] in @issue_kinds,
         true <- non_empty_string?(issue["title"]),
         true <- is_map(issue["story"]),
         true <- valid_checklist?(issue["story"]["checklist"]) do
      true
    else
      _ -> false
    end
  end

  defp valid_checklist?(checklist) when is_list(checklist) and checklist != [] do
    Enum.all?(checklist, fn item ->
      is_map(item) and non_empty_string?(item["id"]) and non_empty_string?(item["text"])
    end) and unique_checklist_ids?(checklist)
  end

  defp valid_checklist?(_checklist), do: false

  # R2:checklist item id 在 issue 内唯一(学习记录 item_id 的匹配目标)
  defp unique_checklist_ids?(checklist) do
    ids = Enum.map(checklist, & &1["id"])
    length(ids) == length(Enum.uniq(ids))
  end

  defp unique_issue_ids?(issues) do
    ids = Enum.map(issues, & &1["id"])
    length(ids) == length(Enum.uniq(ids))
  end

  # --- objectives(schema v2)私有实现 --------------------------------------------

  defp objective_shape_violations(objective) when is_map(objective) do
    label = objective_label(objective)

    checks = [
      {non_empty_string?(objective["id"]), "objective 缺非空 id"},
      {non_empty_string?(objective["title"]), "#{label} 缺非空 title"},
      {valid_required?(objective), "#{label} 的 required 须为布尔值(缺省 = true 必修)"},
      {valid_prereq_shape?(objective), "#{label} 的 prereq_ids 须为 objective id 字符串数组"},
      {valid_optional_string?(objective, "activity"), "#{label} 的 activity 须为字符串(可为空串)"},
      {valid_optional_string?(objective, "assessment"), "#{label} 的 assessment 须为字符串(可为空串)"},
      {valid_materials?(objective), "#{label} 的 materials 须为 %{title, ref} 数组"}
    ]

    for({false, message} <- checks, do: message) ++ rubric_violations(objective, label)
  end

  defp objective_shape_violations(_objective),
    do: ["objective 形状非法:须为 map(含 id/title/rubric 等字段)"]

  defp objective_label(objective) do
    case objective["id"] do
      id when is_binary(id) and id != "" -> "objective \"#{id}\""
      _ -> "objective(缺非空 id)"
    end
  end

  defp valid_required?(objective) do
    not Map.has_key?(objective, "required") or is_boolean(objective["required"])
  end

  defp valid_prereq_shape?(objective) do
    case objective["prereq_ids"] do
      nil -> true
      ids when is_list(ids) -> Enum.all?(ids, &is_binary/1)
      _ -> false
    end
  end

  defp valid_optional_string?(objective, key) do
    case objective[key] do
      nil -> true
      value -> is_binary(value)
    end
  end

  defp valid_materials?(objective) do
    case objective["materials"] do
      nil ->
        true

      materials when is_list(materials) ->
        Enum.all?(materials, fn item ->
          is_map(item) and is_binary(item["title"]) and is_binary(item["ref"])
        end)

      _ ->
        false
    end
  end

  # 每个 objective 必须配非空 rubric(≥1 条 {id, text},id 组内唯一)——Rubric 是
  # 掌握的判定标准,空 rubric = 不可判定(R38)
  defp rubric_violations(objective, label) do
    case objective["rubric"] do
      rubric when is_list(rubric) and rubric != [] ->
        items_valid? =
          Enum.all?(rubric, fn item ->
            is_map(item) and non_empty_string?(item["id"]) and non_empty_string?(item["text"])
          end)

        ids = Enum.map(rubric, fn item -> if is_map(item), do: item["id"], else: nil end)

        cond do
          not items_valid? -> ["#{label} 的 rubric 条目须含非空 id 与 text"]
          length(ids) != length(Enum.uniq(ids)) -> ["#{label} 的 rubric 条目 id 在 objective 内重复"]
          true -> []
        end

      _ ->
        ["#{label} 的 rubric 为空:每个 objective 至少一条评分标准 {id, text}"]
    end
  end

  # objective id 课程级唯一(非仅 issue 内)——prereq_ids 跨 issue 引用的前提
  defp duplicate_id_violations(objectives) do
    ids =
      objectives
      |> Enum.filter(fn objective -> is_map(objective) and non_empty_string?(objective["id"]) end)
      |> Enum.map(& &1["id"])

    ids
    |> Enum.uniq()
    |> then(fn unique -> ids -- unique end)
    |> Enum.uniq()
    |> Enum.map(fn id -> "objective id 在课程内重复:\"#{id}\"" end)
  end

  defp missing_prereq_violations(objectives) do
    valid = valid_objectives(objectives)
    id_set = MapSet.new(Enum.map(valid, & &1["id"]))

    for objective <- valid,
        prereq <- prereq_ids_of(objective),
        not MapSet.member?(id_set, prereq),
        uniq: true do
      "objective \"#{objective["id"]}\" 的 prereq_ids 引用不存在的 objective:\"#{prereq}\""
    end
  end

  # 先修关系 DAG:DFS 三色标记找环(自引用 = 长度 1 的环,同路检出)。
  # 只取合法 id 的 objective 建图(重复/缺失 id 与引用不存在已各自报违规)。
  defp cycle_violations(objectives) do
    edges =
      objectives
      |> valid_objectives()
      |> Enum.uniq_by(& &1["id"])
      |> Map.new(fn objective -> {objective["id"], prereq_ids_of(objective)} end)

    ids = Map.keys(edges)

    case find_cycle(ids, edges) do
      nil ->
        []

      cycle ->
        [
          "objective 先修关系存在环(prereq_ids 不得成环或自引用):" <>
            Enum.join(cycle, " -> ")
        ]
    end
  end

  defp valid_objectives(objectives) do
    Enum.filter(objectives, fn objective ->
      is_map(objective) and non_empty_string?(objective["id"])
    end)
  end

  defp prereq_ids_of(objective) do
    case objective["prereq_ids"] do
      ids when is_list(ids) -> Enum.filter(ids, &is_binary/1)
      _ -> []
    end
  end

  defp find_cycle(ids, edges) do
    marks = Map.new(ids, &{&1, :white})

    ids
    |> Enum.reduce_while({:ok, marks}, fn id, {:ok, marks} ->
      case dfs(id, edges, marks, []) do
        {:ok, marks} -> {:cont, {:ok, marks}}
        {:cycle, cycle} -> {:halt, {:cycle, cycle}}
      end
    end)
    |> case do
      {:ok, _marks} -> nil
      {:cycle, cycle} -> cycle
    end
  end

  defp dfs(id, edges, marks, stack) do
    case Map.get(marks, id, :black) do
      :black ->
        {:ok, marks}

      :gray ->
        # id 已在当前 DFS 栈:环 = 栈中自 id 起的一段 + id(自引用得 [id, id])
        cycle = Enum.drop_while(stack, &(&1 != id)) ++ [id]
        {:cycle, cycle}

      :white ->
        marks = Map.put(marks, id, :gray)
        stack = stack ++ [id]

        edges
        |> Map.get(id, [])
        |> Enum.filter(&Map.has_key?(edges, &1))
        |> Enum.reduce_while({:ok, marks}, fn prereq, {:ok, marks} ->
          case dfs(prereq, edges, marks, stack) do
            {:ok, marks} -> {:cont, {:ok, marks}}
            {:cycle, _cycle} = cycle -> {:halt, cycle}
          end
        end)
        |> case do
          {:ok, marks} -> {:ok, Map.put(marks, id, :black)}
          {:cycle, _cycle} = cycle -> cycle
        end
    end
  end

  defp non_empty_string?(value), do: is_binary(value) and value != ""
end

defmodule Cgc2046.Curriculum.ContentValidation do
  @moduledoc """
  `Curriculum.Output.data` 的 course content 形状校验(Ash Resource.Validation)。

  非法内容在入库前拒绝(fail-fast),错误挂 `:data` 字段。schema v2(S6):
  objectives 存在即全规则校验(保存时不强制;发布门禁才硬性要求)。
  """

  use Ash.Resource.Validation

  alias Cgc2046.Curriculum.Content

  @impl true
  def validate(changeset, _opts, _context) do
    case Ash.Changeset.get_attribute(changeset, :data) do
      nil ->
        :ok

      content ->
        if Content.valid?(content) do
          :ok
        else
          {:error,
           field: :data,
           message:
             "course content must be %{goals: non-empty string list, issues: non-empty list of " <>
               "issue cards (id/kind/title/story required, kind in [thoughtwork, handwork], " <>
               "non-empty checklist with unique-in-issue item ids, issue ids unique in deck; " <>
               "optional objectives per issue — id unique course-wide, non-empty title, " <>
               "required boolean (default true), prereq_ids referencing existing objective ids " <>
               "forming a DAG, activity/assessment strings, materials [{title, ref}], " <>
               "non-empty rubric with unique-in-objective criterion ids))"}
        end
    end
  end
end
