defmodule Cgc2046.Mcp.Tools.SubmitPrepQualityReport do
  @moduledoc """
  提交课程教研质量报告（role-agent-journeys-v2 S5，R27，直接写）。

  前置 prep_state == quality_check（先经 submit_prep_for_check 过结构门禁）。
  报告 = tutor 本地 agent 对当前草稿版本的结构化评审：

      %{score: integer 0..100（必填）, summary: string（必填）,
        findings: [%{severity, message}]（可选）}

  存储时附带当前草稿版本（draft_version）/提交人/时间。结果：

  - score < 生效阈值 → 回 `authoring`（响应 outcome=below_threshold；reviewer 或
    Owner/Admin 可经 override_prep_gate 记理由覆盖）；
  - score ≥ 生效阈值 → review_required ? `review`（等待 approve_prep）:
    直接发布（outcome=published，课程 draft → open）。

  被指派的 tutor（其本地 agent）或 Owner/Admin 可提交。
  """
  use Anubis.Server.Component, type: :tool

  alias Cgc2046.Courses.Course
  alias Cgc2046.Curriculum.Prep
  alias Cgc2046.Mcp.Wrapper

  schema do
    field(:workspace_id, {:required, :string}, description: "目标工作台 ID（UUID）")
    field(:course_id, {:required, :string}, description: "课程 ID（UUID）")

    field(:report, {:required, :map},
      description:
        "质量报告：%{score: 0-100 整数（必填）, summary: 评审摘要（必填）, findings: [%{severity, message}]（可选）}"
    )
  end

  @impl true
  def execute(params, frame) do
    result =
      Wrapper.run(frame, params, "submit_prep_quality_report", fn actor, workspace_id, params ->
        course_id = params["course_id"] || params[:course_id]
        report = params["report"] || params[:report]

        with {:ok, course} <- fetch_course(workspace_id, course_id),
             {:ok, run} <- fetch_run(course),
             :ok <- authorize(actor, workspace_id, run),
             {:ok, report} <- validate_report(report),
             {:ok, updated, outcome} <- Prep.submit_quality_report(run, actor, report) do
          {:ok,
           %{
             course_id: course.id,
             outcome: to_string(outcome),
             prep_state: Prep.prep_state(updated),
             course_status: to_string(course_status(course.id, workspace_id)),
             threshold: Prep.policy(updated)["quality_threshold"]
           }}
        end
      end)

    Cgc2046.Mcp.Tools.Response.to_response(result, frame)
  end

  defp authorize(actor, workspace_id, run) do
    if Prep.assignee(run) == actor.id or Prep.manage?(actor, workspace_id) do
      :ok
    else
      {:error, "forbidden: assigned tutor, owner or admin required to submit quality report"}
    end
  end

  # 报告契约校验（score/summary 必填；findings 可选，逐条须含 severity+message）
  defp validate_report(report) when is_map(report) do
    score = report["score"] || report[:score]
    summary = report["summary"] || report[:summary]
    findings = report["findings"] || report[:findings] || []

    cond do
      not (is_integer(score) and score >= 0 and score <= 100) ->
        {:error, "report.score is required (integer 0..100)"}

      not (is_binary(summary) and summary != "") ->
        {:error, "report.summary is required (non-empty string)"}

      not (is_list(findings) and Enum.all?(findings, &valid_finding?/1)) ->
        {:error, "report.findings must be a list of %{severity, message} maps"}

      true ->
        {:ok, %{"score" => score, "summary" => summary, "findings" => findings}}
    end
  end

  defp validate_report(_report), do: {:error, "report must be a map"}

  defp valid_finding?(finding) when is_map(finding) do
    severity = finding["severity"] || finding[:severity]
    message = finding["message"] || finding[:message]
    is_binary(severity) and severity != "" and is_binary(message) and message != ""
  end

  defp valid_finding?(_finding), do: false

  # 响应里的课程状态重读（published 路径 launch 后应为 open；失败已在 with 拦截）
  defp course_status(course_id, workspace_id) do
    case Course
         |> Ash.Query.for_read(:get_by_id, %{id: course_id})
         |> Ash.read_one(authorize?: false, tenant: workspace_id) do
      {:ok, %Course{status: status}} -> status
      _ -> :unknown
    end
  end

  defp fetch_course(workspace_id, course_id) do
    case Course
         |> Ash.Query.for_read(:get_by_id, %{id: course_id})
         |> Ash.read_one(authorize?: false, tenant: workspace_id) do
      {:ok, nil} -> {:error, "course not found: #{course_id}"}
      {:ok, course} -> {:ok, course}
      {:error, _} -> {:error, "failed to load course"}
    end
  end

  defp fetch_run(course) do
    case Prep.fetch_run(course.id, course.workspace_id) do
      nil -> {:error, "no preparation run found for course #{course.id}"}
      run -> {:ok, run}
    end
  end
end
