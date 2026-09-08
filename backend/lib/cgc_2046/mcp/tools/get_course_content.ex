defmodule Cgc2046.Mcp.Tools.GetCourseContent do
  @moduledoc """
  读取课程内容 issue 卡集(切片 H U3, #180;R4 读)。

  数据源 = Curriculum.Output(kind=:issues, key=course_<id>)可变草稿;无内容返回
  course 无教研产出的明确错误(agent 侧可提示等待教研)。

  授权(KTD2/M4):仅课程所在 workspace 的教研工作面——tutor ∪ owner/admin
  (与 save_course_content 同一谓词 `LearnerAuthorization.staff?/2`)。学员与
  run 持有者的内容读面是 `get_course_revision`(仅最新 published 快照)——
  草稿不成为意外的学员 API。

  响应(advisory H2/H3,KTD6「Web 与扩展共用形状约定」):`course_title` +
  草稿 `version`(S4 乐观并发基准,`save_course_content` 的 `base_version`
  来源)+ `chapters` 原样透出 + 逐 issue 注入展示层 `key`(slug 短码-序号派生,
  单源 `Cgc2046.Curriculum.Content.issue_key/2`)——面板与 agent 无需自算或
  退用内部 id。
  """
  use Anubis.Server.Component, type: :tool, meta: %{membership: :deferred}

  alias Cgc2046.Courses.Course
  alias Cgc2046.Mcp.Tools.LearnerAuthorization
  alias Cgc2046.Mcp.Wrapper

  schema do
    field(:workspace_id, {:required, :string}, description: "目标工作台 ID(UUID)")
    field(:course_id, {:required, :string}, description: "课程 ID(UUID)")
  end

  @impl true
  def execute(params, frame) do
    result =
      Wrapper.run(frame, params, "get_course_content", fn actor, workspace_id, params ->
        course_id = params["course_id"]

        with :ok <- authorize_staff(actor, workspace_id),
             {:ok, course} <- Course.fetch_scoped(workspace_id, course_id),
             {:ok, output} <- fetch_content(workspace_id, course_id) do
          content = output.data || %{}

          issues =
            (content["issues"] || [])
            |> Enum.with_index(1)
            |> Enum.map(fn {issue, idx} ->
              Map.put(
                issue,
                "key",
                Cgc2046.Curriculum.Content.issue_key(course.slug, idx)
              )
            end)

          {:ok,
           %{
             course_id: course_id,
             course_title: course.title,
             version: output.version,
             goals: content["goals"] || [],
             chapters: content["chapters"] || [],
             issues: issues
           }}
        end
      end)

    Cgc2046.Mcp.Tools.Response.to_response(result, frame)
  end

  # M4:tutor ∪ owner/admin(save_course_content 同款判定,同一谓词模块
  # LearnerAuthorization.staff?/2);learner/volunteer/无差异标签成员/学员/持有者拒。
  defp authorize_staff(actor, workspace_id) do
    if LearnerAuthorization.staff?(actor, workspace_id) do
      :ok
    else
      {:error, "forbidden: tutor, owner or admin required"}
    end
  end

  # 读经 Curriculum.content_output/2 单一入口(A4),authorize?: false——读门禁已
  # 在工具层真实发生(staff-only,M4);字符串错误为 MCP 工具契约。
  # 返回 Output 记录本体——响应需要顶层 version(S4 乐观并发读侧)。
  defp fetch_content(workspace_id, course_id) do
    case Cgc2046.Curriculum.content_output(workspace_id, course_id) do
      {:ok, nil} ->
        {:error, "no course content saved for course #{course_id} (curriculum pending)"}

      {:ok, output} ->
        {:ok, output}

      {:error, _} ->
        {:error, "failed to load course content"}
    end
  end
end
