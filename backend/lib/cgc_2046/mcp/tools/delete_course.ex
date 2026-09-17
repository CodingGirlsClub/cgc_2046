defmodule Cgc2046.Mcp.Tools.DeleteCourse do
  @moduledoc """
  删除草稿课程：物理删除 draft（#676，ADR-0015；Owner 专属管理工具，确认流 two-tool
  写，D-D3）。

  语义对齐 GraphQL deleteCourse（同 `Courses.Course :delete` action）。与
  close/cancel 的差别：**只有 draft 可删**——已发布课程走 close/cancel（终态不可逆
  但保留行与 slug），draft 删除不可恢复：课程行、教研草稿（curriculum_outputs，
  若有）一并删除，slug 立即释放可复用（ADR-0014 锁的是发布后的 URL 段，draft slug
  从未发布、无公开契约）。

  权限（#676 收窄面，与 cancel 的 Owner/Admin **刻意不同**）：Owner ∪ 平台管理员。
  admin 不放行（删除不可逆、无回收站）；member-only 门的既有契约（S2）不含
  platform_admin 豁免，非成员平台管理员经 GraphQL 域放行。

  第一次调用：不落业务库，建 PendingOperation，返回 needs_confirmation。
  非 draft 课程快速失败（不建 pending）；并发竞态（确认窗内被 launch）由 domain
  的行锁守卫在 confirm 段兜底。
  """
  use Anubis.Server.Component, type: :tool

  alias Cgc2046.Accounts.Policies.PlatformAdmin
  alias Cgc2046.Accounts.Rbac
  alias Cgc2046.Courses.Course
  alias Cgc2046.Mcp.{Confirmation, Wrapper}

  schema do
    field(:workspace_id, {:required, :string}, description: "目标工作台 ID（UUID）")
    field(:course_id, {:required, :string}, description: "待删除课程 ID（UUID，须为 draft）")
  end

  @impl true
  def execute(params, frame) do
    result =
      Wrapper.run(frame, params, "delete_course", fn actor, workspace_id, params ->
        course_id = params["course_id"]

        with :ok <- authorize(actor, workspace_id),
             {:ok, course} <- Course.fetch_scoped(workspace_id, course_id, actor: actor) do
          if course.status != :draft do
            {:error, "cannot delete from status=#{course.status}（仅 draft 可删除）"}
          else
            summary =
              "删除草稿课程「#{course.title}」（#{course.id}）：" <>
                "课程行与教研草稿（若有）将永久删除、不可恢复；" <>
                "slug #{course.slug} 将释放可复用"

            Confirmation.request(
              frame.assigns[:current_user],
              "delete_course",
              params,
              summary
            )
          end
        end
      end)

    Cgc2046.Mcp.Tools.Response.to_response(result, frame)
  end

  @doc """
  确认后真正执行（由 `Confirmation.execute/3` 直接分派调用）。
  params 为 pending 落库的 redact 后参数（本工具参数无敏感键，直接可用）。
  """
  @spec execute_confirmed(term(), map()) :: {:ok, map()} | {:error, String.t()}
  def execute_confirmed(actor, params) do
    workspace_id = params["workspace_id"]
    course_id = params["course_id"]

    with {:ok, course} <- Course.fetch_scoped(workspace_id, course_id, actor: actor) do
      case course
           |> Ash.Changeset.for_destroy(:delete, %{}, tenant: workspace_id)
           |> Ash.destroy(actor: actor, tenant: workspace_id) do
        :ok ->
          {:ok, %{course_id: course.id, title: course.title, slug: course.slug}}

        {:error, %Ash.Error.Forbidden{}} ->
          {:error,
           "forbidden: owner or platform admin required to delete course in workspace #{workspace_id}"}

        {:error, err} ->
          {:error, Cgc2046.Mcp.Errors.message(err, "failed to delete course")}
      end
    end
  end

  # Owner ∪ 平台管理员（#676 收窄面）：admin 不在内。平台管理员分支同时兜住
  # 「成员平台管理员」与「非成员平台管理员」——后者撞 Wrapper member-only 门
  # （S2 成文契约：MCP 门不放宽 admin 豁免），只有 GraphQL 域放行。
  defp authorize(actor, workspace_id) do
    if PlatformAdmin.platform_admin?(actor) or Rbac.owner?(actor, workspace_id) do
      :ok
    else
      {:error, "forbidden: owner or platform admin required to delete courses"}
    end
  end
end
