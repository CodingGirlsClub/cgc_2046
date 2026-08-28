defmodule Cgc2046.Workflows.CourseContent do
  @moduledoc """
  课程内容(issue 卡集)的形状契约纯函数族(切片 H U1, #180)。

  course content = `%{"goals" => [String.t()], "issues" => [issue]}`,issue 形状
  (设计 `课程issue学习闭环详细设计.md` §2):

      %{
        "id" => "py-first-program",
        "kind" => "handwork",
        "title" => "写你的第一个程序",
        "story" => %{
          "as_a" => ..., "given" => [...], "goal" => ...,
          "materials" => [%{"title" => ..., "ref" => ...}],
          "checklist" => [%{"id" => "c1", "text" => ...}]
        }
      }

  消费方:Curriculum.Output changeset 校验(U1)、LearningProgress issue 级投影与
  完成判定(U4)。JSONB 只按 string keys 校验(MCP `save_course_content` 经
  Jason 解码是唯一写入口;SponsorshipTier 同款先例)。

  id 稳定纪律(R2/KTD4):issue `id` 与 checklist `item id` 发布后不改不删;
  本模块只做形状与卡集内唯一性校验(id 非空、issue id 卡集内唯一、item id
  issue 内唯一),语义纪律由教研 Agent 指令承担。
  """

  @issue_kinds ["thoughtwork", "handwork"]

  @doc "issue kind 二分(证据在哪为界:thoughtwork 对话 / handwork 产物)。"
  @spec issue_kinds() :: [String.t()]
  def issue_kinds, do: @issue_kinds

  @doc """
  结构性校验 course content:

  - `goals`:非空字符串数组
  - `issues`:非空数组,每张卡 `id`/`kind`/`title`/`story` 必填
    (`kind ∈ thoughtwork | handwork`)
  - `story.checklist`:非空数组,每条含非空 `id`/`text`
  - issue `id` 卡集内唯一;checklist item `id` issue 内唯一
  """
  @spec valid?(term()) :: boolean()
  def valid?(content) when is_map(content) do
    with true <- non_empty_goals?(content),
         {:ok, issues} <- issues_or_error(content),
         true <- Enum.all?(issues, &valid_issue?/1),
         true <- unique_issue_ids?(issues) do
      true
    else
      _ -> false
    end
  end

  def valid?(_content), do: false

  @doc "合法 content 的 issue 列表;非法(缺失/非列表/空)返回 []。"
  @spec issues(term()) :: [map()]
  def issues(content) when is_map(content) do
    case content["issues"] do
      issues when is_list(issues) and issues != [] -> issues
      _ -> []
    end
  end

  def issues(_content), do: []

  @doc "issue 的 checklist item id 列表(学习记录 item_id 的匹配目标;畸形返回 [])。"
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

  # --- 私有实现 ----------------------------------------------------------------

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

  defp non_empty_string?(value), do: is_binary(value) and value != ""
end

defmodule Cgc2046.Workflows.CourseContentValidation do
  @moduledoc """
  `Curriculum.Output.data` 的 course content 形状校验(Ash Resource.Validation)。

  非法内容在入库前拒绝(fail-fast),错误挂 `:data` 字段。
  """

  use Ash.Resource.Validation

  alias Cgc2046.Workflows.CourseContent

  @impl true
  def validate(changeset, _opts, _context) do
    case Ash.Changeset.get_attribute(changeset, :data) do
      nil ->
        :ok

      content ->
        if CourseContent.valid?(content) do
          :ok
        else
          {:error,
           field: :data,
           message:
             "course content must be %{goals: non-empty string list, issues: non-empty list of " <>
               "issue cards (id/kind/title/story required, kind in [thoughtwork, handwork], " <>
               "non-empty checklist with unique-in-issue item ids, issue ids unique in deck))"}
        end
    end
  end
end
