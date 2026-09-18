defmodule Cgc2046.Courses.CourseGovernanceWriteTest do
  @moduledoc """
  平台管理员治理写（U1/KTD1、KTD2）Course 侧：逐 action 放行 + 治理写逐笔留痕 +
  工作台 Owner 审计语义不变。与 `EventGovernanceWriteTest` 同构（Course 无
  deposit_enabled，留痕闭集标量少一列）。
  """

  use Cgc2046.DataCase, async: true

  alias Cgc2046.Accounts.AdminActionLog
  alias Cgc2046.Accounts.MembershipContext
  alias Cgc2046.AccountsFixtures, as: Fixtures
  alias Cgc2046.Courses.Course
  alias Cgc2046.EventsFixtures, as: EventFixtures

  require Ash.Query

  defp tenant do
    %{owner: owner, workspace: workspace} = Fixtures.workspace_with_member()
    %{owner: owner, workspace: workspace, admin: Fixtures.platform_admin()}
  end

  defp draft_course(workspace, actor, attrs \\ %{}) do
    Course
    |> Ash.Changeset.for_create(
      :create,
      Map.merge(%{title: "治理写课程草稿", enrollment_policy: :open}, attrs),
      tenant: workspace.id
    )
    |> Ash.create!(tenant: workspace.id, actor: actor)
  end

  defp write(course, workspace, actor, action, attrs \\ %{}) do
    course
    |> Ash.Changeset.for_update(action, attrs, tenant: workspace.id, actor: actor)
    |> Ash.update(tenant: workspace.id, actor: actor)
  end

  defp reload(course), do: Ash.get!(Course, course.id, authorize?: false)

  defp logs_for(action, target_id) do
    AdminActionLog
    |> Ash.Query.for_read(:read)
    |> Ash.Query.filter(action == ^action and target_id == ^target_id)
    |> Ash.read!(authorize?: false)
  end

  test "非成员平台管理员对 draft 课 launch：成功并留一行 admin_course_launch" do
    %{owner: owner, workspace: workspace, admin: admin} = tenant()
    course = draft_course(workspace, owner)
    refute MembershipContext.membership_of(admin, workspace.id)

    assert {:ok, launched} = write(course, workspace, admin, :launch)
    assert launched.status == :open
    assert reload(course).status == :open

    assert [log] = logs_for(:admin_course_launch, course.id)
    assert log.actor_id == admin.id
    assert log.target_type == :course
    assert log.result == :success
  end

  test "非成员平台管理员对 open 课 update/close/cancel：成功、逐笔留痕、自由文本不落 metadata" do
    %{owner: owner, workspace: workspace, admin: admin} = tenant()
    course = EventFixtures.create_course(workspace, owner, %{capacity: 10})

    assert {:ok, updated} =
             write(course, workspace, admin, :update, %{
               title: "治理改名",
               capacity: 20,
               description: "自由文本 secret"
             })

    assert updated.title == "治理改名"

    assert [update_log] = logs_for(:admin_course_update, course.id)
    assert update_log.target_type == :course
    assert update_log.metadata["title_before"] == "Test Course"
    assert update_log.metadata["title_after"] == "治理改名"
    assert update_log.metadata["capacity_before"] == 10
    assert update_log.metadata["capacity_after"] == 20
    refute Map.has_key?(update_log.metadata, "description")
    refute inspect(update_log.metadata) =~ "自由文本 secret"

    assert {:ok, closed} = write(reload(course), workspace, admin, :close)
    assert closed.status == :closed
    assert [close_log] = logs_for(:admin_course_close, course.id)
    assert close_log.actor_id == admin.id

    cancelled_course = EventFixtures.create_course(workspace, owner)
    assert {:ok, cancelled} = write(cancelled_course, workspace, admin, :cancel)
    assert cancelled.status == :cancelled
    assert [cancel_log] = logs_for(:admin_course_cancel, cancelled_course.id)
    assert cancel_log.actor_id == admin.id
  end

  test "平台管理员对任意租户 createCourse 被拒（create 不放行）" do
    %{workspace: workspace, admin: admin} = tenant()

    assert {:error, %Ash.Error.Forbidden{}} =
             Course
             |> Ash.Changeset.for_create(
               :create,
               %{title: "治理建课", enrollment_policy: :open},
               tenant: workspace.id
             )
             |> Ash.create(tenant: workspace.id, actor: admin)
  end

  test "平台管理员直调内部 action（:link_curriculum_run/:bind_current_revision）被拒（R7 无旁路）" do
    %{owner: owner, workspace: workspace, admin: admin} = tenant()
    course = EventFixtures.create_course(workspace, owner)

    assert {:error, %Ash.Error.Forbidden{}} =
             write(course, workspace, admin, :link_curriculum_run, %{
               workflow_run_id: Ecto.UUID.generate()
             })

    assert {:error, %Ash.Error.Forbidden{}} =
             write(course, workspace, admin, :bind_current_revision, %{
               current_revision_id: Ecto.UUID.generate()
             })

    assert reload(course).workflow_run_id == nil
    assert reload(course).current_revision_id == nil
  end

  test "平台管理员改已发布课 slug 被拒（code course_slug_locked）；draft 课仍可改" do
    %{owner: owner, workspace: workspace, admin: admin} = tenant()
    draft = draft_course(workspace, owner, %{slug: "gov-draft-course"})

    assert {:ok, renamed} = write(draft, workspace, admin, :update, %{slug: "gov-draft-course-2"})
    assert renamed.slug == "gov-draft-course-2"

    published = EventFixtures.create_course(workspace, owner, %{slug: "gov-published-course"})

    assert {:error, %Ash.Error.Invalid{errors: errors}} =
             write(published, workspace, admin, :update, %{slug: "gov-published-course-2"})

    assert [%Cgc2046.Errors.BusinessError{code: "course_slug_locked", fields: [:slug]}] = errors
    assert reload(published).slug == "gov-published-course"
  end

  test "工作台 Owner（非平台管理员）launch 成功且不落留痕（skip_unless 生效）" do
    %{owner: owner, workspace: workspace} = tenant()
    course = draft_course(workspace, owner)

    assert {:ok, launched} = write(course, workspace, owner, :launch)
    assert launched.status == :open
    assert logs_for(:admin_course_launch, course.id) == []
  end
end
