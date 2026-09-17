defmodule Cgc2046.Courses.CourseDraftDeletionTest do
  @moduledoc """
  #676 draft 课程删除（`Course :delete`，ADR-0015）：

  - draft 删除成功：行消失、**同 slug 立即可复用**（释放全局唯一索引）、教研内容行
    （curriculum_outputs）与非终态 prep run 同事务收口
  - 非 draft（open）拒绝：`cannot delete from status=open`，行不动
  - 域权限收窄：Owner ✅ / **admin ❌**（Forbidden）/ 平台管理员 ✅（非成员亦放行，
    = GraphQL 域那条路径；MCP 面另有 member-only 门，不在本文件）
  - launch × delete 并发（行锁互斥）：恰一成一败——launch 持锁提交后阻塞的 delete
    读到新状态被拒；delete 先提交后陈旧 draft struct 的 launch 被 CAS 拒绝

  `async: false`（并发用例经 `unboxed_run` 真实提交，行锁/提交对并发方可见——
  attendance_test / course_prep_tools_test 同款纪律）；其余用例走常规 sandbox 回滚。
  """
  use Cgc2046.DataCase, async: false

  alias Cgc2046.AccountsFixtures, as: Fixtures
  alias Cgc2046.Accounts.MembershipContext
  alias Cgc2046.Courses.Course
  alias Cgc2046.Curriculum.{Output, Prep, PrepInstantiator}
  alias Cgc2046.Workflows.{SignalSubscriber, WorkflowRun}

  require Ash.Query

  # 合法 content（ContentValidation：goals 非空 + issue 形状 + 至少一个完整 objective）
  defp content_fixture do
    %{
      "goals" => ["能写简单程序"],
      "issues" => [
        %{
          "id" => "py-first-program",
          "kind" => "handwork",
          "title" => "写你的第一个程序",
          "story" => %{
            "as_a" => "刚装好 Python 的学员",
            "given" => [],
            "goal" => "独立写一个问候程序",
            "materials" => [],
            "checklist" => [%{"id" => "c1", "text" => "程序能运行并正确输出"}]
          },
          "objectives" => [
            %{
              "id" => "obj-1",
              "title" => "能独立运行问候程序",
              "required" => true,
              "prereq_ids" => [],
              "materials" => [],
              "activity" => "动手写一个问候程序",
              "assessment" => "运行结果截图",
              "rubric" => [%{"id" => "r1", "text" => "程序能运行并输出问候"}]
            }
          ]
        }
      ]
    }
  end

  defp draft_course(workspace, actor, attrs \\ %{}) do
    attrs = Map.merge(%{title: "待删草稿", slug: "issue676-draft"}, attrs)

    Course
    |> Ash.Changeset.for_create(:create, attrs, tenant: workspace.id)
    |> Ash.create!(tenant: workspace.id, actor: actor)
  end

  defp launch(course, actor) do
    course
    |> Ash.Changeset.for_update(:launch, %{}, tenant: course.workspace_id)
    |> Ash.update(tenant: course.workspace_id, actor: actor)
  end

  defp delete(course, actor) do
    course
    |> Ash.Changeset.for_destroy(:delete, %{}, tenant: course.workspace_id)
    |> Ash.destroy(tenant: course.workspace_id, actor: actor)
  end

  defp output_rows(course, workspace_id) do
    Output
    |> Ash.Query.filter(key == ^Output.course_key(course.id))
    |> Ash.read!(authorize?: false, tenant: workspace_id)
  end

  # 行已删除：Ash.get 对不存在的主键回 NotFound（不是 {:ok, nil}）
  defp assert_deleted(id) do
    assert {:error, %Ash.Error.Invalid{errors: [%Ash.Error.Query.NotFound{}]}} =
             Ash.get(Course, id, authorize?: false)
  end

  test "draft 删除：行消失、slug 复用、教研内容行删除、非终态 prep run 收口" do
    %{owner: owner, workspace: workspace} = Fixtures.workspace_with_member()
    course = draft_course(workspace, owner)

    # 教研草稿（真实写入路径 upsert_content）+ prep run（course.created 真实 handler）
    {:ok, _output} =
      Output
      |> Ash.Changeset.for_create(
        :upsert_content,
        %{
          key: Output.course_key(course.id),
          kind: :issues,
          data: content_fixture(),
          submitted_by: owner.id,
          base_version: 0
        },
        tenant: workspace.id
      )
      |> Ash.create(tenant: workspace.id, actor: owner)

    assert [_] = output_rows(course, workspace.id)

    :ok =
      SignalSubscriber.deliver(PrepInstantiator, %{
        type: "course.created",
        data: %{"course_id" => course.id, "title" => course.title}
      })

    %WorkflowRun{} = run = Prep.fetch_run(course.id, workspace.id)
    assert run.status in [:pending, :running, :waiting]

    assert :ok = delete(course, owner)

    assert_deleted(course.id)
    assert output_rows(course, workspace.id) == []
    assert Ash.get!(WorkflowRun, run.id, authorize?: false).status == :cancelled

    # slug 释放：同 slug 立即可建新课程（未释放时撞 identity → course_slug_taken）
    assert {:ok, recreated} =
             Course
             |> Ash.Changeset.for_create(
               :create,
               %{title: "重建课程", slug: "issue676-draft"},
               tenant: workspace.id
             )
             |> Ash.create(tenant: workspace.id, actor: owner)

    assert recreated.slug == "issue676-draft"
    refute recreated.id == course.id
  end

  test "open 课程拒绝删除（cannot delete from status=open），行不动" do
    %{owner: owner, workspace: workspace} = Fixtures.workspace_with_member()
    course = draft_course(workspace, owner)

    # 真实 launch（测试内无 prep run → 教研门放行），不是 fixture 的裸 SQL 置位
    assert {:ok, %Course{status: :open} = open} = launch(course, owner)

    assert {:error, error} = delete(open, owner)
    assert Exception.message(error) =~ "cannot delete from status=open"

    assert {:ok, %Course{status: :open}} = Ash.get(Course, course.id, authorize?: false)
  end

  test "域权限：admin ❌（Forbidden）、非成员平台管理员 ✅" do
    %{owner: owner, workspace: workspace} = Fixtures.workspace_with_member()

    admin_member = Fixtures.register_user("issue676-del-admin")
    Fixtures.add_member(workspace, admin_member, [:admin])

    admin_course = draft_course(workspace, owner, %{slug: "issue676-admin-draft"})

    assert {:error, %Ash.Error.Forbidden{}} = delete(admin_course, admin_member)
    assert {:ok, %Course{status: :draft}} = Ash.get(Course, admin_course.id, authorize?: false)

    platform = Fixtures.platform_admin("issue676-del-platform")
    assert MembershipContext.membership_of(platform, workspace.id) == nil

    platform_course = draft_course(workspace, owner, %{slug: "issue676-platform-draft"})

    assert :ok = delete(platform_course, platform)
    assert_deleted(platform_course.id)
  end

  describe "launch × delete 并发（行锁互斥，恰一成一败）" do
    test "launch 持锁提交 open 后，阻塞在行锁上的 delete 读到新状态被拒" do
      # 布置须真实提交（unboxed）：并发两方各用独立 unboxed 连接，
      # sandbox 未提交数据对其不可见（course_prep_tools_test 同款纪律）
      {owner, workspace, course} =
        unboxed(fn ->
          owner = Fixtures.platform_admin("issue676-race-owner")
          workspace = Fixtures.create_workspace(owner)
          course = draft_course(workspace, owner, %{slug: "issue676-race-draft"})
          {owner, workspace, course}
        end)

      cleanup_on_exit(workspace.id, [owner], course.id)
      parent = self()

      # 胜方：真实事务内先取 course 行锁（= launch 的 status_transition UPDATE
      # 会取的那把锁），收到放行信号后提交 open。
      launcher =
        Task.async(fn ->
          unboxed(fn ->
            Repo.transaction(fn ->
              Repo.query!("SELECT status FROM courses WHERE id = $1 FOR UPDATE", [
                Repo.uuid!(course.id)
              ])

              send(parent, :locked)

              receive do
                :release -> :ok
              end

              Repo.query!("UPDATE courses SET status = 'open' WHERE id = $1", [
                Repo.uuid!(course.id)
              ])
            end)
          end)
        end)

      assert_receive :locked, 5_000

      delete_task = Task.async(fn -> unboxed(fn -> delete(course, owner) end) end)

      # 持锁期间 delete 必然阻塞在行锁上（SELECT … FOR UPDATE 拿不到锁）
      assert Task.yield(delete_task, 300) == nil

      send(launcher.pid, :release)
      assert {:ok, _} = Task.await(launcher, 5_000)

      # 败方：等锁恢复后读到已提交 open → 拒；行未删
      assert {:error, error} = Task.await(delete_task, 5_000)
      assert Exception.message(error) =~ "cannot delete from status=open"

      assert %Course{status: :open} =
               unboxed(fn -> Ash.get!(Course, course.id, authorize?: false) end)
    end

    test "delete 先提交后，陈旧 draft struct 的 launch 被 CAS 拒绝（行不复活）" do
      %{owner: owner, workspace: workspace} = Fixtures.workspace_with_member()
      course = draft_course(workspace, owner, %{slug: "issue676-cas-draft"})

      assert :ok = delete(course, owner)
      assert_deleted(course.id)

      # 败方持陈旧 struct（内存仍 draft）→ status_transition 条件 UPDATE 命中 0 行
      assert {:error, error} = launch(course, owner)
      assert Exception.message(error) =~ "concurrently"
      assert_deleted(course.id)
    end
  end

  # ── 并发用例布置（真实提交 → 显式收尾；course_prep_tools_test / attendance_test
  # 同款纪律：sandbox 事务里的行锁/未提交行对 unboxed 连接不可见）────────────

  defp unboxed(fun), do: Ecto.Adapters.SQL.Sandbox.unboxed_run(Repo, fun)

  defp cleanup_on_exit(workspace_id, users, course_id) do
    on_exit(fn ->
      unboxed(fn ->
        # course.created 的 outbox job 已真提交（无 FK，按 course_id 定位清）
        Repo.query!("DELETE FROM oban_jobs WHERE args->'data'->>'course_id' = $1", [course_id])

        Repo.query!("DELETE FROM courses WHERE workspace_id = $1", [Repo.uuid!(workspace_id)])

        Repo.query!(
          "DELETE FROM admin_action_logs WHERE target_type = 'workspace' AND target_id = $1",
          [Repo.uuid!(workspace_id)]
        )

        Repo.query!(
          "DELETE FROM membership_roles WHERE membership_id IN " <>
            "(SELECT id FROM workspace_memberships WHERE workspace_id = $1)",
          [Repo.uuid!(workspace_id)]
        )

        Repo.query!("DELETE FROM workspace_memberships WHERE workspace_id = $1", [
          Repo.uuid!(workspace_id)
        ])

        # workspace seed 落 workflow_definitions（FK）——先清子表再删 workspace
        Repo.query!("DELETE FROM workflow_definitions WHERE workspace_id = $1", [
          Repo.uuid!(workspace_id)
        ])

        Repo.query!("DELETE FROM workspaces WHERE id = $1", [Repo.uuid!(workspace_id)])

        Enum.each(users, fn user ->
          Repo.query!("DELETE FROM users WHERE id = $1", [Repo.uuid!(user.id)])
        end)
      end)
    end)
  end
end
