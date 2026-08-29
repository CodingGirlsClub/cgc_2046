defmodule Cgc2046.Curriculum.PrepGate do
  @moduledoc """
  课程教研结构门禁 v1（role-agent-journeys-v2 S5，R26）：提交质量检查
  （submit_prep_for_check）与发布前的确定性结构判定，纯函数无 IO。

  v1 检查项：

  - 课程标题不是临时占位标题（S3 `provisional_title`）；
  - 课程内容存在（Curriculum.Output `kind=:issues` 草稿行）；
  - `goals` 非空、`issues` 非空；
  - `Curriculum.Content` v1 形状复核（id 非空且卡集内唯一 / kind 合法 /
    story 为 map 且 checklist 合规——入库时已校验，此处为发布前的确定性复核）。

  objectives 加严（schema v2 硬性要求）属 S6，本片不查。

  返回 `%{passed: boolean, violations: [String.t()]}`——violations 逐条可执行
  （tutor agent 按清单逐条修复后重新提交）。
  """

  alias Cgc2046.Courses.Course
  alias Cgc2046.Curriculum.{Content, Output}

  @doc """
  对课程 + 其内容草稿行（`Output.t() | nil`）跑结构门禁。
  """
  @spec check(Course.t(), Output.t() | nil) :: %{passed: boolean(), violations: [String.t()]}
  def check(course, output) do
    violations =
      []
      |> check_title(course)
      |> check_content(output)

    %{passed: violations == [], violations: violations}
  end

  defp check_title(violations, %{provisional_title: true}) do
    violations ++ ["课程标题仍是系统生成的临时标题：请先经 update_course 设置正式标题"]
  end

  defp check_title(violations, _course), do: violations

  defp check_content(violations, nil) do
    violations ++ ["课程内容为空：尚无经 save_course_content 保存的内容草稿"]
  end

  defp check_content(violations, %Output{data: content}) do
    violations
    |> check_goals(content)
    |> check_issues(content)
    |> check_shape(content)
  end

  defp check_goals(violations, content) do
    case content["goals"] do
      goals when is_list(goals) and goals != [] ->
        violations

      _ ->
        violations ++ ["课程目标（goals）为空：至少一条课程级目标"]
    end
  end

  defp check_issues(violations, content) do
    case content["issues"] do
      issues when is_list(issues) and issues != [] ->
        violations

      _ ->
        violations ++ ["issue 卡集为空：至少一张 issue 卡"]
    end
  end

  # goals/issues 均非空才做整形状复核（空集违规已各报一条，避免同因多报）。
  defp check_shape(violations, content) do
    if shape_checkable?(content) and not Content.valid?(content) do
      violations ++
        [
          "课程内容结构不合法：issue 须含非空 id/kind（thoughtwork|handwork）/title/story，" <>
            "issue id 在卡集内唯一"
        ]
    else
      violations
    end
  end

  defp shape_checkable?(content) do
    is_map(content) and is_list(content["goals"]) and content["goals"] != [] and
      is_list(content["issues"]) and content["issues"] != []
  end
end
