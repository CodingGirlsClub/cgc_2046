defmodule Cgc2046.Events.CompanionRevisionValidationTest do
  @moduledoc """
  `course_revision_id` 配套锚校验三入口（issue #505 D1 + review BLOCKING 2）：

  - create：workspace_id argument 路径；
  - MCP update：changeset.tenant 路径；
  - GraphQL updateEvent：**无 tenant 注入、无 workspace_id argument**（#104），
    靠 record data 的 workspace_id 兜底——缺这级时合法 published revision
    恒被拒（BLOCKING 2 回归）。
  """
  use Cgc2046.DataCase, async: true

  alias Cgc2046.AccountsFixtures, as: Fixtures
  alias Cgc2046.Curriculum.CourseRevision
  alias Cgc2046.Events.Event
  alias Cgc2046.EventsFixtures, as: EventFixtures

  defp published_revision(workspace, course) do
    CourseRevision
    |> Ash.Changeset.for_create(
      :create,
      %{
        course_id: course.id,
        number: 1,
        content: %{"goals" => [], "issues" => []},
        published_at: DateTime.utc_now()
      },
      tenant: workspace.id
    )
    |> Ash.create!(tenant: workspace.id, authorize?: false)
  end

  setup do
    owner = Fixtures.platform_admin("companion-owner")
    workspace = Fixtures.create_workspace(owner)
    course = EventFixtures.create_course(workspace, owner, %{title: "配套课"})
    revision = published_revision(workspace, course)

    event =
      EventFixtures.create_event(workspace, owner, %{title: "沙龙"})

    %{workspace: workspace, owner: owner, course: course, revision: revision, event: event}
  end

  test "GraphQL update 路径（无 tenant、无 argument）挂合法锚放行", %{
    revision: revision,
    event: event
  } do
    # 复刻 ash_graphql updateEvent 的 changeset 形状：不传 tenant、不传
    # workspace_id argument——tenant 只能来自 record data（BLOCKING 2）。
    assert {:ok, updated} =
             event
             |> Ash.Changeset.for_update(:update, %{course_revision_id: revision.id})
             |> Ash.update(authorize?: false)

    assert updated.course_revision_id == revision.id
  end

  test "GraphQL update 路径挂不存在的 revision 拒绝", %{event: event} do
    # R29「发布即冻结」：revision 创建即 published（action 层 published_at
    # 必填），域内无草稿态——published 校验的可触发拒绝面 = 指向不存在
    # （或他租户，tenant 收窄）的 revision。
    assert {:error, changeset} =
             event
             |> Ash.Changeset.for_update(:update, %{course_revision_id: Ecto.UUID.generate()})
             |> Ash.update(authorize?: false)

    assert Enum.any?(changeset.errors, &(&1.field == :course_revision_id))
  end

  test "拆锚（nil）放行", %{event: event, revision: revision} do
    {:ok, anchored} =
      event
      |> Ash.Changeset.for_update(:update, %{course_revision_id: revision.id})
      |> Ash.update(authorize?: false)

    assert {:ok, detached} =
             anchored
             |> Ash.Changeset.for_update(:update, %{course_revision_id: nil})
             |> Ash.update(authorize?: false)

    assert detached.course_revision_id == nil
  end

  test "tenant 路径（MCP update 形状）挂合法锚放行", %{
    workspace: workspace,
    revision: revision,
    event: event
  } do
    assert {:ok, updated} =
             event
             |> Ash.Changeset.for_update(:update, %{course_revision_id: revision.id},
               tenant: workspace.id
             )
             |> Ash.update(tenant: workspace.id, authorize?: false)

    assert updated.course_revision_id == revision.id
  end
end
