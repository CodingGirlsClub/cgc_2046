defmodule Cgc2046.Learning.LearningRecordTest do
  @moduledoc """
  LearningRecord 资源测试(切片 H U2, #180):

  - 新建记录成功;同键二次写覆盖 done/evidence/recorded_at(upsert 最新为准)
  - 同 issue 不同 item 独立成行;同 user 跨 enrollment(不同 enrollment_id 审计值)
    同键仍合并(AE1 底座)
  - 越权(actor ≠ 行 user_id 且非成员)写入被拒;非本人非成员读被置空
  - issue_id/item_id 空字符串拒;不校验内容存在性(宽存,KTD4)
  """
  use Cgc2046.DataCase, async: true

  alias Cgc2046.AccountsFixtures, as: Fixtures
  alias Cgc2046.EventsFixtures, as: EventFixtures
  alias Cgc2046.Learning.LearningRecord

  require Ash.Query

  defp upsert(workspace, learner, course, attrs) do
    defaults = %{
      course_id: course.id,
      user_id: learner.id,
      issue_id: "py-first-program",
      item_id: "c1",
      done: true,
      evidence: "程序运行正确输出问候",
      recorded_at: DateTime.utc_now(),
      enrollment_id: Ecto.UUID.generate(),
      run_id: Ecto.UUID.generate()
    }

    LearningRecord
    |> Ash.Changeset.for_create(:upsert_record, Map.merge(defaults, attrs),
      tenant: workspace.id,
      actor: learner
    )
    |> Ash.create(tenant: workspace.id, actor: learner)
  end

  describe "upsert 最新为准" do
    test "新建成功;同键二次写覆盖 done/evidence/recorded_at 与审计列" do
      admin = Fixtures.platform_admin("lr-up")
      workspace = Fixtures.create_workspace(admin)
      learner = Fixtures.register_user("lr-up-learner")
      course = EventFixtures.create_course(workspace, admin, %{title: "课程"})
      first_enrollment = Ecto.UUID.generate()
      {:ok, first} = upsert(workspace, learner, course, %{enrollment_id: first_enrollment})

      later = DateTime.add(DateTime.utc_now(), 3600, :second)
      second_enrollment = Ecto.UUID.generate()

      assert {:ok, second} =
               upsert(workspace, learner, course, %{
                 done: false,
                 evidence: "复盘中:产物能跑但解释不清",
                 recorded_at: later,
                 enrollment_id: second_enrollment
               })

      # 同键合并:一行,最新为准
      assert second.id == first.id
      assert second.done == false
      assert second.evidence == "复盘中:产物能跑但解释不清"
      assert second.enrollment_id == second_enrollment
      assert DateTime.compare(second.recorded_at, first.recorded_at) == :gt

      assert [row] =
               LearningRecord
               |> Ash.Query.filter(course_id == ^course.id and user_id == ^learner.id)
               |> Ash.read!(authorize?: false)
    end
  end

  describe "键粒度" do
    test "同 issue 不同 item 独立成行" do
      admin = Fixtures.platform_admin("lr-item")
      workspace = Fixtures.create_workspace(admin)
      learner = Fixtures.register_user("lr-item-learner")
      course = EventFixtures.create_course(workspace, admin, %{})

      {:ok, _} = upsert(workspace, learner, course, %{item_id: "c1"})
      {:ok, _} = upsert(workspace, learner, course, %{item_id: "c2", done: false})

      rows =
        LearningRecord
        |> Ash.Query.filter(user_id == ^learner.id)
        |> Ash.Query.sort(:item_id)
        |> Ash.read!(authorize?: false)

      assert length(rows) == 2
      assert Enum.map(rows, & &1.item_id) == ["c1", "c2"]
    end

    test "同 user 跨 enrollment 同键仍合并(AE1 底座,审计值切换)" do
      admin = Fixtures.platform_admin("lr-ae1")
      workspace = Fixtures.create_workspace(admin)
      learner = Fixtures.register_user("lr-ae1-learner")
      course = EventFixtures.create_course(workspace, admin, %{})
      old_enrollment = Ecto.UUID.generate()

      {:ok, old} =
        upsert(workspace, learner, course, %{enrollment_id: old_enrollment, done: true})

      # 退款重报:新 enrollment_id,同键记录延续不清零
      new_enrollment = Ecto.UUID.generate()

      assert {:ok, renewed} =
               upsert(workspace, learner, course, %{
                 enrollment_id: new_enrollment,
                 done: true,
                 evidence: "重报后延续"
               })

      assert renewed.id == old.id
      assert renewed.enrollment_id == new_enrollment
    end
  end

  describe "授权" do
    test "越权写(actor ≠ 行 user_id 且非成员)被拒" do
      admin = Fixtures.platform_admin("lr-auth")
      workspace = Fixtures.create_workspace(admin)
      learner = Fixtures.register_user("lr-auth-learner")
      other = Fixtures.register_user("lr-auth-other")
      course = EventFixtures.create_course(workspace, admin, %{})

      assert {:error, %Ash.Error.Forbidden{}} =
               upsert(workspace, other, course, %{user_id: learner.id})
    end

    test "非本人非成员读被置空;本人可读自己的记录" do
      admin = Fixtures.platform_admin("lr-read")
      workspace = Fixtures.create_workspace(admin)
      learner = Fixtures.register_user("lr-read-learner")
      outsider = Fixtures.register_user("lr-read-outsider")
      course = EventFixtures.create_course(workspace, admin, %{})
      {:ok, _} = upsert(workspace, learner, course, %{})

      assert {:ok, []} =
               LearningRecord
               |> Ash.Query.for_read(:read)
               |> Ash.read(tenant: workspace.id, actor: outsider)

      assert {:ok, [row]} =
               LearningRecord
               |> Ash.Query.for_read(:read)
               |> Ash.read(tenant: workspace.id, actor: learner)

      assert row.user_id == learner.id
    end
  end

  describe "宽存与输入校验" do
    test "issue_id/item_id 空字符串拒" do
      admin = Fixtures.platform_admin("lr-empty")
      workspace = Fixtures.create_workspace(admin)
      learner = Fixtures.register_user("lr-empty-learner")
      course = EventFixtures.create_course(workspace, admin, %{})

      assert {:error, changeset} =
               upsert(workspace, learner, course, %{issue_id: ""})

      assert %{errors: errors} = changeset
      assert Enum.any?(errors, &(&1.field == :issue_id))

      assert {:error, changeset} =
               upsert(workspace, learner, course, %{item_id: ""})

      assert %{errors: errors} = changeset
      assert Enum.any?(errors, &(&1.field == :item_id))
    end

    test "不校验内容存在性(宽存,KTD4)——引用不存在的 issue/item 也可写" do
      admin = Fixtures.platform_admin("lr-wide")
      workspace = Fixtures.create_workspace(admin)
      learner = Fixtures.register_user("lr-wide-learner")
      course = EventFixtures.create_course(workspace, admin, %{})

      assert {:ok, row} =
               upsert(workspace, learner, course, %{
                 issue_id: "future-issue-not-in-content",
                 item_id: "ghost-item"
               })

      assert row.issue_id == "future-issue-not-in-content"
    end
  end
end
