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
          "materials" => [%{"kind" => "web", "title" => ..., "url" => "https://..."}],
          "checklist" => [%{"id" => "c1", "text" => ...}]
        },
        "objectives" => [
          %{
            "id" => "obj-hello",
            "title" => "能独立运行问候程序",
            "required" => true,
            "prereq_ids" => [],
            "materials" => [%{"kind" => "web", "title" => ..., "url" => "https://..."}],
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
  @material_kinds ["text", "markdown", "web", "image", "video"]
  @video_providers ["bilibili"]

  @doc "issue kind 二分(证据在哪为界:thoughtwork 对话 / handwork 产物)。"
  @spec issue_kinds() :: [String.t()]
  def issue_kinds, do: @issue_kinds

  @doc "Typed material kinds accepted by the shared Web/MCP/extension contract."
  @spec material_kinds() :: [String.t()]
  def material_kinds, do: @material_kinds

  @doc "Video providers currently supported by the first-party renderer."
  @spec video_providers() :: [String.t()]
  def video_providers, do: @video_providers

  @doc """
  结构性校验 course content(保存时全规则 = v1 形状 + objectives 强制存在):

  - `goals`:非空字符串数组
  - `issues`:非空数组,每张卡 `id`/`kind`/`title`/`story` 必填
    (`kind ∈ thoughtwork | handwork`)
  - `story.checklist`:非空数组,每条含非空 `id`/`text`
  - issue `id` 卡集内唯一;checklist item `id` issue 内唯一
  - `objectives`:**强制至少一个**(全课程)且全部 v2 规则必须过——与发布门禁
    对齐(校验前移):保存时即拦缺 objectives,省掉「存 v1 → 交质检被拦 →
    补 objectives → 存 v2」的往返。存量 v1-only 数据读取路径仍兼容
    (`objectives/1` 返回 [])。
  """
  @spec valid?(term()) :: boolean()
  def valid?(content) when is_map(content) do
    valid_v1?(content) and objectives(content) != [] and objective_violations(content) == []
  end

  def valid?(_content), do: false

  @doc """
  v1 形状校验(不含 objectives 规则):发布门禁的通用形状复核用——objective
  违规由 `objective_violations/1` 逐条另报,不并入通用形状违规文案。

  规则单源:本函数即 `shape_violations/1` 的 `== []`——布尔与逐条诊断同一份规则,
  杜绝双源漂移(发布门禁等既有 caller 只消费布尔,行为不变)。
  """
  @spec valid_v1?(term()) :: boolean()
  def valid_v1?(content), do: shape_violations(content) == []

  @doc """
  v1 形状违规逐条清单(与 `objective_violations/1`、`material_violations/1` 对称的
  public 诊断出口;保存校验经此把具体违规透出给教研 Agent,#677)。

  覆盖:`goals`/`issues` 存在性与形状、`chapters` 形状与 id 唯一性、每张 issue 卡
  `id`/`kind`/`title`/`story`、`story.checklist`(须嵌在 story 内,非 issue 卡顶层)、
  `story.materials` 形状、issue id 卡集内唯一、`chapter_id` 引用。

  每条单行,只含结构位置与类型/长度(标题/正文等用户内容不入文案;issue id 仅作
  位置标签,经换行清洗与截断)——报告体积有界。
  """
  @spec shape_violations(term()) :: [String.t()]
  def shape_violations(content) when is_map(content) do
    issues = content["issues"]

    goals_violations(content) ++
      issues_violations(issues) ++
      chapters_violations(content) ++
      chapter_ref_violations(content, issues)
  end

  def shape_violations(content),
    do: ["course content 须为 map(含 goals/issues),当前:#{describe(content)}"]

  @doc """
  `Value:` 形状摘要(保存校验错误里「服务端实际收到什么」的单源,#677):固定 3 个
  契约顶层键(`nil` = 未提交),值只给类型/长度——

      %{"goals" => "list(4)", "chapters" => "nil", "issues" => "list(9)"}

  绝不回显字符串内容或额外顶层键(体积与泄露面有界),据此消灭 `Value: nil` 误导。
  """
  @spec shape_summary(term()) :: map()
  def shape_summary(content) when is_map(content) do
    for key <- ["goals", "chapters", "issues"], into: %{}, do: {key, describe(content[key])}
  end

  def shape_summary(content), do: %{"content" => describe(content)}

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
  存在性由 `valid?/1` 强制,presence 违规文案归发布门禁 `require_objectives`):

  - per-objective 形状:`id`/`title` 非空字符串;`required` 布尔(缺省 true);
    `prereq_ids` 为字符串数组;`activity`/`assessment` 为字符串(可空串);
    `materials` 为 typed Material 数组;`rubric` 非空且条目 `{id, text}`、
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

  @doc "Return the optional narrative chapters, dropping malformed entries."
  @spec chapters(term()) :: [map()]
  def chapters(%{"chapters" => chapters}) when is_list(chapters),
    do: Enum.filter(chapters, &is_map/1)

  def chapters(_content), do: []

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

  @doc """
  逐条报告材料协议错误（保存校验 ContentValidation 与发布门禁 PrepGate 共用
  的同一份违规报告，H3/H4）；旧 {title, ref} 草稿必须重新保存为 typed Material。

  每条格式 `<位置路径>: <错误码>，<说明>`——位置路径精确到
  `issue "<id>" story.materials[<i>]` 或 `issue "<id>" objective "<id>" materials[<i>]`；
  错误码机读：

  - `legacy_material_ref`：旧 `{title, ref}` 材料，需重新保存为 typed Material；
  - `invalid_material_access_scope`：显式 `access`/`access_scope` 键仅允许 `"public"`；
  - `missing_material_metadata`：image 材料缺 trim 后非空的 `alt_text`；
  - `invalid_material_source`：来源/形状不合法（非 https URL、未知 provider、
    缺 body、未知或缺失 kind 等）。
  """
  @spec material_violations(term()) :: [String.t()]
  def material_violations(content) when is_map(content) do
    content
    |> issues()
    |> Enum.flat_map(fn issue ->
      issue_label = if is_map(issue), do: Map.get(issue, "id", "issue"), else: "issue"
      story_materials = if is_map(issue), do: get_in(issue, ["story", "materials"]), else: nil

      story_violations =
        story_materials
        |> List.wrap()
        |> Enum.with_index()
        |> Enum.flat_map(fn {material, index} ->
          material_violation(material, ~s(issue "#{issue_label}" story.materials[#{index}]))
        end)

      objective_violations =
        if is_map(issue) and is_list(issue["objectives"]) do
          Enum.flat_map(issue["objectives"], fn objective ->
            objective_label =
              if is_map(objective), do: Map.get(objective, "id", "objective"), else: "objective"

            materials =
              if is_map(objective) and is_list(objective["materials"]),
                do: objective["materials"],
                else: []

            materials
            |> Enum.with_index()
            |> Enum.flat_map(fn {material, index} ->
              material_violation(
                material,
                ~s(issue "#{issue_label}" objective "#{objective_label}" materials[#{index}])
              )
            end)
          end)
        else
          []
        end

      story_violations ++ objective_violations
    end)
  end

  def material_violations(_content), do: []

  # 单条材料的协议违规分类（nil = 合规）。优先级：legacy 整条重存 >
  # 显式 access scope 语义键 > image 元数据 > 来源/形状——每条材料报一行,
  # 首要违规即行动指引。
  defp material_violation(material, path) do
    case material_error_code(material) do
      nil -> []
      {code, detail} -> ["#{path}: #{code}，#{detail}"]
    end
  end

  defp material_error_code(material) do
    cond do
      is_map(material) and Map.has_key?(material, "ref") ->
        {:legacy_material_ref, "旧 {title, ref} 材料需重新保存为 typed Material"}

      not valid_material_scope?(material) ->
        {:invalid_material_access_scope, ~s/access\/access_scope 仅允许 "public"/}

      image_missing_alt?(material) ->
        {:missing_material_metadata, "image 材料须含 trim 后非空的 alt_text"}

      not valid_material?(material) ->
        {:invalid_material_source, "材料来源不合法（kind/URL/provider/body 约束）"}

      true ->
        nil
    end
  end

  defp image_missing_alt?(material) when is_map(material) do
    material["kind"] == "image" and https_url?(material["url"]) and
      not non_blank_string?(material["alt_text"])
  end

  defp image_missing_alt?(_material), do: false

  # --- 私有实现(v1) ------------------------------------------------------------

  defp non_empty_goals?(content) do
    case content["goals"] do
      goals when is_list(goals) and goals != [] ->
        Enum.all?(goals, &(is_binary(&1) and &1 != ""))

      _ ->
        false
    end
  end

  defp goals_violations(content) do
    if non_empty_goals?(content) do
      []
    else
      ["goals 须为非空字符串数组,当前:#{describe(content["goals"])}"]
    end
  end

  defp issues_violations(issues) when is_list(issues) and issues != [] do
    issues
    |> Enum.with_index(1)
    |> Enum.flat_map(fn {issue, index} -> issue_violations(issue, index) end)
    |> Kernel.++(duplicate_issue_id_violations(issues))
  end

  defp issues_violations(issues),
    do: ["issues 须为非空 issue 卡数组,当前:#{describe(issues)}"]

  defp issue_violations(issue, index) when is_map(issue) do
    label = issue_label(issue, index)
    story = issue["story"]

    field_violations = [
      {non_empty_string?(issue["id"]), "#{label} 缺非空 id"},
      {issue["kind"] in @issue_kinds,
       "#{label} 的 kind 须为 thoughtwork 或 handwork,当前:#{describe(issue["kind"])}"},
      {non_empty_string?(issue["title"]), "#{label} 缺非空 title"},
      {is_map(story), "#{label} 缺 story(须为 map,checklist/materials 嵌在 story 内)"}
    ]

    for({false, message} <- field_violations, do: message) ++
      if(is_map(story),
        do: story_violations(story, label, Map.has_key?(issue, "checklist")),
        else: []
      )
  end

  defp issue_violations(issue, index),
    do: ["issue[#{index}] 须为 map(含 id/kind/title/story),当前:#{describe(issue)}"]

  defp story_violations(story, label, top_level_checklist?) do
    checklist_violations(story["checklist"], label, top_level_checklist?) ++
      materials_shape_violations(story["materials"], label)
  end

  # 本次事故直接触发点:checklist 放 issue 卡顶层(或省略)→ 文案点名
  # `story.checklist` 与「非卡顶层」,并回显顶层误放的事实。
  defp checklist_violations(checklist, label, top_level_checklist?) do
    cond do
      not (is_list(checklist) and checklist != []) ->
        [
          "#{label} 的 story.checklist 须为非空数组,且嵌在 story 内(非卡顶层)," <>
            "当前:#{describe(checklist)}#{top_level_checklist_hint(top_level_checklist?)}"
        ]

      Enum.all?(checklist, &valid_checklist_item?/1) ->
        if unique_checklist_ids?(checklist) do
          []
        else
          ["#{label} 的 story.checklist 条目 id 在 issue 内重复"]
        end

      true ->
        ["#{label} 的 story.checklist 条目须含非空 id 与 text"]
    end
  end

  defp top_level_checklist_hint(true), do: ";检测到 issue 卡顶层有 checklist 键,请移入 story"
  defp top_level_checklist_hint(false), do: ""

  defp valid_checklist_item?(item) do
    is_map(item) and non_empty_string?(item["id"]) and non_empty_string?(item["text"])
  end

  # R2:checklist item id 在 issue 内唯一(学习记录 item_id 的匹配目标)
  defp unique_checklist_ids?(checklist) do
    ids = Enum.map(checklist, & &1["id"])
    length(ids) == length(Enum.uniq(ids))
  end

  defp materials_shape_violations(materials, label) do
    if valid_materials?(materials) do
      []
    else
      ["#{label} 的 story.materials 形状不合法(须为 typed Material 数组),当前:#{describe(materials)}"]
    end
  end

  defp duplicate_issue_id_violations(issues) do
    ids =
      issues
      |> Enum.filter(&is_map/1)
      |> Enum.map(& &1["id"])
      |> Enum.filter(&non_empty_string?/1)

    ids
    |> Enum.uniq()
    |> then(fn unique -> ids -- unique end)
    |> Enum.uniq()
    |> Enum.map(fn id -> ~s(issue id 在卡集内重复:"#{safe_label(id)}") end)
  end

  defp chapters_violations(content) do
    case Map.get(content, "chapters") do
      nil ->
        []

      chapters when is_list(chapters) ->
        chapter_entry_violations(chapters) ++ duplicate_chapter_id_violations(chapters)

      other ->
        ["chapters 须为数组(每项 {id, title}),当前:#{describe(other)}"]
    end
  end

  defp chapter_entry_violations(chapters) do
    for {chapter, index} <- Enum.with_index(chapters, 1), not chapter_valid?(chapter) do
      if is_map(chapter) do
        "chapters[#{index}] 缺非空 id/title"
      else
        "chapters[#{index}] 须为 map,当前:#{describe(chapter)}"
      end
    end
  end

  defp chapter_valid?(chapter) do
    is_map(chapter) and non_empty_string?(chapter["id"]) and non_empty_string?(chapter["title"])
  end

  defp duplicate_chapter_id_violations(chapters) do
    ids = Enum.map(chapters, &if(is_map(&1), do: &1["id"], else: nil))

    if length(ids) == length(Enum.uniq(ids)),
      do: [],
      else: ["chapters 条目 id 须在课程内唯一(存在重复)"]
  end

  # 引用集合沿用公开 `chapters/1`(丢弃非 map 条目)——与旧 valid_v1? 语义逐字一致。
  defp chapter_ref_violations(content, issues) do
    chapter_ids = content |> chapters() |> Enum.map(& &1["id"]) |> MapSet.new()

    issues
    |> List.wrap()
    |> Enum.with_index(1)
    |> Enum.flat_map(fn
      {issue, index} when is_map(issue) ->
        case issue["chapter_id"] do
          nil ->
            []

          chapter_id when is_binary(chapter_id) ->
            if MapSet.member?(chapter_ids, chapter_id) do
              []
            else
              ["#{issue_label(issue, index)} 的 chapter_id 引用不存在的 chapter"]
            end

          other ->
            ["#{issue_label(issue, index)} 的 chapter_id 须为字符串,当前:#{describe(other)}"]
        end

      {_other, _index} ->
        []
    end)
  end

  defp issue_label(issue, index) do
    case issue["id"] do
      id when is_binary(id) and id != "" -> ~s(issue "#{safe_label(id)}")
      _ -> "issue[#{index}](缺非空 id)"
    end
  end

  # 位置标签清洗:换行/控制字符折平 + 截断——每条违规单行且长度有界。
  defp safe_label(value) do
    cleaned = value |> String.replace(~r/[\s\x00-\x1F]+/u, " ") |> String.trim()

    if String.length(cleaned) > 60, do: String.slice(cleaned, 0, 60) <> "…", else: cleaned
  end

  # 只回显类型/长度,绝不回显字符串内容(错误体积与泄露面有界)。
  defp describe(value) when is_list(value), do: "list(#{length(value)})"
  defp describe(value) when is_map(value), do: "map"
  defp describe(value) when is_binary(value), do: "string(#{byte_size(value)})"
  defp describe(nil), do: "nil"
  defp describe(value) when is_boolean(value), do: "boolean"
  defp describe(value) when is_integer(value), do: "integer"
  defp describe(value) when is_float(value), do: "float"
  defp describe(value) when is_atom(value), do: "atom"
  defp describe(_value), do: "其他类型"

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
      {valid_materials?(objective["materials"]), "#{label} 的 materials 形状不合法"}
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

  defp valid_materials?(materials) do
    case materials do
      nil ->
        true

      materials when is_list(materials) ->
        Enum.all?(materials, &valid_material?/1)

      _ ->
        false
    end
  end

  # H3/H4：image 除 https URL 外须带 trim 后非空的 alt_text（无 alt 的图对读屏
  # 与弱网均为死内容）；显式语义键 access/access_scope 仅允许 "public"（材料随
  # 内容公开分发，enrolled/workspace 等收窄值拒绝）——缺键放行（向后兼容既有
  # typed 材料），未知展示键不参与判定（保 round-trip）。
  defp valid_material?(%{"kind" => kind} = material) when kind in @material_kinds do
    kind_valid? =
      case kind do
        kind when kind in ["text", "markdown"] ->
          is_binary(material["body"])

        "web" ->
          https_url?(material["url"])

        "image" ->
          https_url?(material["url"]) and non_blank_string?(material["alt_text"])

        "video" ->
          material["provider"] in @video_providers and valid_bilibili_id?(material["external_id"])
      end

    kind_valid? and valid_material_scope?(material)
  end

  defp valid_material?(_), do: false

  defp valid_material_scope?(material) when is_map(material) do
    Enum.all?(["access", "access_scope"], fn key ->
      not Map.has_key?(material, key) or material[key] == "public"
    end)
  end

  defp valid_material_scope?(_material), do: true

  defp non_blank_string?(value), do: is_binary(value) and String.trim(value) != ""

  defp https_url?(url) when is_binary(url) do
    case URI.parse(url) do
      %URI{scheme: "https", host: host, userinfo: nil} when is_binary(host) and host != "" -> true
      _ -> false
    end
  end

  defp https_url?(_), do: false

  defp valid_bilibili_id?(id) when is_binary(id), do: Regex.match?(~r/^BV[0-9A-Za-z]{10}$/, id)
  defp valid_bilibili_id?(_), do: false

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
  objectives 强制至少一个且全规则校验(与发布门禁对齐,校验前移——UAT
  journey 发现两级校验不一致导致 v1-only 草稿多一轮往返)。

  材料协议违规(H3/H4)随保存错误透出 `Content.material_violations/1` 的同一份
  报告——结构化错误码(legacy_material_ref / invalid_material_access_scope /
  missing_material_metadata / invalid_material_source)+ issue/objective/
  material 位置路径,教研 Agent 可按码定位修复。
  """

  use Ash.Resource.Validation

  alias Cgc2046.Curriculum.Content

  @base_message "course content must be %{goals: non-empty string list, issues: non-empty list of " <>
                  "issue cards (id/kind/title/story required, kind in [thoughtwork, handwork], " <>
                  "non-empty story.checklist (nested in story, not top-level) with unique-in-issue item ids, " <>
                  "issue ids unique in deck; " <>
                  "objectives required (at least one course-wide, non-empty per issue cards) — " <>
                  "id unique course-wide, non-empty title, " <>
                  "required boolean (default true), prereq_ids referencing existing objective ids " <>
                  "forming a DAG, activity/assessment strings, typed materials (kind + constrained source), " <>
                  "non-empty rubric with unique-in-objective criterion ids))"

  # 调用方可见整条文案上限 2 KB:违规条数与单条长度不设业务上限,但渲染出口必须
  # 有界,避免畸形超大 content 放大 MCP 响应/LLM 上下文。Ash 的 InvalidAttribute
  # 渲染会在 message 前后加固定包装("Invalid value provided for data: " 与
  # ".\n\nValue: <摘要>"),故 violations 文案按 @wrapper_headroom 预留余量截断。
  @max_message_bytes 2048
  @wrapper_headroom 256
  @truncation_suffix "…(truncated)"

  @impl true
  def validate(changeset, _opts, _context) do
    case Ash.Changeset.get_attribute(changeset, :data) do
      nil ->
        :ok

      content ->
        if Content.valid?(content) do
          :ok
        else
          # 显式异常:Ash 的 keyword 错误转换会无条件带 `value: nil`(渲染出
          # `Value: nil`,误导 agent 以为服务端收到 nil),这里显式给形状摘要。
          {:error,
           Ash.Error.Changes.InvalidAttribute.exception(
             field: :data,
             message: message(content),
             value: Content.shape_summary(content)
           )}
        end
    end
  end

  # 形状违规 + objective 违规 + 材料协议违规的同一份逐条报告;三组全空
  # (唯一情形:v1 合规但整份 content 无 objectives,presence 归 valid?/发布门禁)
  # 时不拼空尾巴,退回纯 @base_message。
  defp message(content) do
    case violations(content) do
      [] -> @base_message
      violations -> truncate(@base_message <> "; violations: " <> Enum.join(violations, "; "))
    end
  end

  defp violations(content) do
    Content.shape_violations(content) ++
      Content.objective_violations(content) ++
      Content.material_violations(content)
  end

  defp truncate(text)
       when byte_size(text) <= @max_message_bytes - @wrapper_headroom,
       do: text

  defp truncate(text) do
    keep = @max_message_bytes - @wrapper_headroom - byte_size(@truncation_suffix)

    text
    |> binary_part(0, keep)
    |> trim_incomplete_utf8()
    |> Kernel.<>(@truncation_suffix)
  end

  # binary_part 可能切断多字节字符——截到最后一个完整 UTF-8 序列。
  defp trim_incomplete_utf8(binary) do
    case :unicode.characters_to_binary(binary) do
      trimmed when is_binary(trimmed) -> trimmed
      {:incomplete, trimmed, _rest} -> trimmed
      {:error, trimmed, _rest} -> trimmed
    end
  end
end
