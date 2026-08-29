defmodule Cgc2046.Mcp.DraftVersioningTest do
  @moduledoc """
  S4 草稿版本契约测试(role-agent-journeys-v2,R9/R10,AE2)。

  - save_course_content base_version 契约:缺省必填错 / 首存传错基准冲突 /
    0→v1→v2 递增 / 陈旧基准冲突且草稿不变 / 冲突后按新基准写入成功;
  - AE2 双入口并发编辑语义:面板与 Agent 会话是同一 save_course_content 的
    两个等价入口(R9)——面板(owner)写入后,Agent(tutor)持旧基准的写入被
    version_conflict 拦截(附最新 version),面板修改不被旧版本覆盖;
  - 并发首存竞态(unboxed 真实事务,非 mock):两任务同传 base_version 0,
    恰一成一败,落败方 version_conflict(撞 (key,kind) 唯一索引归并语义);
  - get_course_content 响应含 version;
  - 冲突调用落 ToolCallLog(result_status :error)。
  """
  use Cgc2046.DataCase, async: false

  alias Anubis.Server.Frame
  alias Cgc2046.AccountsFixtures, as: Fixtures
  alias Cgc2046.Curriculum.Output
  alias Cgc2046.EventsFixtures, as: EventFixtures
  alias Cgc2046.Mcp.ToolCallLog
  alias Cgc2046.Mcp.Tools.GetCourseContent
  alias Cgc2046.Mcp.Tools.SaveCourseContent
  alias Cgc2046.MiniprogramFixtures.Barrier

  require Ash.Query

  defp frame_for(user), do: Frame.new(current_user: user)

  defp decode({:reply, response, _frame}) do
    [content] = response.content
    Jason.decode!(content["text"])
  end

  defp content_fixture(goals \\ ["能写简单程序"]) do
    %{
      "goals" => goals,
      "issues" => [
        %{
          "id" => "py-first-program",
          "kind" => "handwork",
          "title" => "写你的第一个程序",
          "story" => %{
            "as_a" => "学员",
            "given" => [],
            "goal" => "独立写问候程序",
            "materials" => [],
            "checklist" => [
              %{"id" => "c1", "text" => "程序能运行并正确输出"},
              %{"id" => "c2", "text" => "能讲懂代码"}
            ]
          }
        }
      ]
    }
  end

  defp save(user, workspace, course, params) do
    SaveCourseContent.execute(
      Map.merge(
        %{
          "workspace_id" => workspace.id,
          "course_id" => course.id,
          "content" => content_fixture()
        },
        params
      ),
      frame_for(user)
    )
  end

  defp draft_row(workspace, course) do
    Output
    |> Ash.Query.filter(key == ^Output.course_key(course.id) and kind == :issues)
    |> Ash.read_one!(authorize?: false, tenant: workspace.id)
  end

  describe "save_course_content base_version 契约" do
    test "缺 base_version → required 错误(草稿未落库)" do
      admin = Fixtures.platform_admin("dv-req")
      workspace = Fixtures.create_workspace(admin)
      tutor = Fixtures.register_user("dv-req-tutor")
      Fixtures.add_member(workspace, tutor, [:tutor])
      course = EventFixtures.create_course(workspace, admin, %{})

      assert {:error, %Anubis.MCP.Error{message: msg}, _} =
               SaveCourseContent.execute(
                 %{
                   "workspace_id" => workspace.id,
                   "course_id" => course.id,
                   "content" => content_fixture()
                 },
                 frame_for(tutor)
               )

      assert msg =~ "base_version is required"
      assert msg =~ "get_course_content"
      assert draft_row(workspace, course) == nil
    end

    test "首存传非 0 基准(无草稿)→ version_conflict(version 0)" do
      admin = Fixtures.platform_admin("dv-first")
      workspace = Fixtures.create_workspace(admin)
      tutor = Fixtures.register_user("dv-first-tutor")
      Fixtures.add_member(workspace, tutor, [:tutor])
      course = EventFixtures.create_course(workspace, admin, %{})

      assert {:error, %Anubis.MCP.Error{message: msg}, _} =
               save(tutor, workspace, course, %{"base_version" => 1})

      assert msg =~ "version_conflict"
      assert msg =~ "version 0"
      assert msg =~ "get_course_content"
      assert draft_row(workspace, course) == nil
    end

    test "完整序:0→v1,1→v2,再用 1→version_conflict 且草稿不变,2→v3" do
      admin = Fixtures.platform_admin("dv-seq")
      workspace = Fixtures.create_workspace(admin)
      tutor = Fixtures.register_user("dv-seq-tutor")
      Fixtures.add_member(workspace, tutor, [:tutor])
      course = EventFixtures.create_course(workspace, admin, %{})

      # 首存:base 0 → version 1
      assert {:reply, _, _} = reply1 = save(tutor, workspace, course, %{"base_version" => 0})
      assert decode(reply1)["version"] == 1

      # get_course_content 透出当前 version
      assert {:reply, _, _} =
               get_reply =
               GetCourseContent.execute(
                 %{"workspace_id" => workspace.id, "course_id" => course.id},
                 frame_for(tutor)
               )

      assert decode(get_reply)["version"] == 1

      # 正确基准:base 1 → version 2
      assert {:reply, _, _} =
               reply2 =
               save(tutor, workspace, course, %{
                 "base_version" => 1,
                 "content" => content_fixture(["目标 v2"])
               })

      assert decode(reply2)["version"] == 2

      # 陈旧基准 base 1 → version_conflict(含当前版本 2),草稿不变
      assert {:error, %Anubis.MCP.Error{message: msg}, _} =
               save(tutor, workspace, course, %{
                 "base_version" => 1,
                 "content" => content_fixture(["覆盖"])
               })

      assert msg =~ "version_conflict"
      assert msg =~ "version 2"
      assert msg =~ "get_course_content"

      row = draft_row(workspace, course)
      assert row.version == 2
      assert row.data["goals"] == ["目标 v2"]

      # 冲突后按正确基准 2 重试成功 → version 3
      assert {:reply, _, _} =
               reply3 =
               save(tutor, workspace, course, %{
                 "base_version" => 2,
                 "content" => content_fixture(["目标 v3"])
               })

      assert decode(reply3)["version"] == 3
      assert draft_row(workspace, course).data["goals"] == ["目标 v3"]
    end

    test "冲突与成功调用均落 ToolCallLog(冲突行 result_status :error)" do
      admin = Fixtures.platform_admin("dv-log")
      workspace = Fixtures.create_workspace(admin)
      tutor = Fixtures.register_user("dv-log-tutor")
      Fixtures.add_member(workspace, tutor, [:tutor])
      course = EventFixtures.create_course(workspace, admin, %{})

      assert {:reply, _, _} = save(tutor, workspace, course, %{"base_version" => 0})

      assert {:error, %Anubis.MCP.Error{message: msg}, _} =
               save(tutor, workspace, course, %{"base_version" => 0})

      assert msg =~ "version_conflict"

      logs =
        ToolCallLog
        |> Ash.Query.filter(user_id == ^tutor.id and tool == "save_course_content")
        |> Ash.read!(authorize?: false)
        |> Enum.sort_by(& &1.inserted_at, DateTime)

      assert [%{result_status: :ok}, %{result_status: :error} = conflict_log] = logs
      assert conflict_log.error_message =~ "version_conflict"
    end
  end

  # AE2(R9):面板编辑与 Agent 对话是同一 save_course_content 的两个等价入口——
  # 面板(owner)写入成功后,Agent(tutor)持旧基准的写入必须被 version_conflict
  # 拦截并附最新 version,面板修改不被旧版本静默覆盖。
  describe "AE2 双入口并发编辑语义" do
    test "面板写入后 Agent 旧基准写入被拒(附最新 version),草稿保持面板版" do
      admin = Fixtures.platform_admin("dv-ae2")
      workspace = Fixtures.create_workspace(admin)
      owner = Fixtures.register_user("dv-ae2-owner")
      Fixtures.add_member(workspace, owner, [:owner])
      tutor = Fixtures.register_user("dv-ae2-tutor")
      Fixtures.add_member(workspace, tutor, [:tutor])
      course = EventFixtures.create_course(workspace, admin, %{})

      # Agent 首存(base 0 → v1)
      assert {:reply, _, _} = save(tutor, workspace, course, %{"base_version" => 0})

      # 面板入口(owner)读取草稿(get_course_content 返回 version 1),编辑后以
      # base 1 写入 → v2(面板修改 = goals ["面板修订"])
      assert {:reply, _, _} =
               panel_read =
               GetCourseContent.execute(
                 %{"workspace_id" => workspace.id, "course_id" => course.id},
                 frame_for(owner)
               )

      assert decode(panel_read)["version"] == 1

      assert {:reply, _, _} =
               panel_save =
               save(owner, workspace, course, %{
                 "base_version" => 1,
                 "content" => content_fixture(["面板修订"])
               })

      assert decode(panel_save)["version"] == 2

      # Agent 持旧基准(base 1)写入 → version_conflict 附最新 version 2,草稿不变
      assert {:error, %Anubis.MCP.Error{message: msg}, _} =
               save(tutor, workspace, course, %{
                 "base_version" => 1,
                 "content" => content_fixture(["Agent 旧版覆盖"])
               })

      assert msg =~ "version_conflict"
      assert msg =~ "version 2"

      row = draft_row(workspace, course)
      assert row.version == 2
      assert row.data["goals"] == ["面板修订"]

      # Agent 重读(拿到 version 2 与面板内容),合并后以 base 2 写入成功 → v3
      assert {:reply, _, _} =
               agent_reread =
               GetCourseContent.execute(
                 %{"workspace_id" => workspace.id, "course_id" => course.id},
                 frame_for(tutor)
               )

      reread = decode(agent_reread)
      assert reread["version"] == 2
      assert reread["goals"] == ["面板修订"]

      assert {:reply, _, _} =
               agent_save =
               save(tutor, workspace, course, %{
                 "base_version" => 2,
                 "content" => content_fixture(["面板修订", "Agent 补充"])
               })

      assert decode(agent_save)["version"] == 3
    end
  end

  # unboxed 真实事务竞态(sponsorship_concurrency_test 同款纪律):两任务各自
  # 持真实连接并发首存同一课程草稿,单语句 check-and-insert 保证恰一方成功。
  describe "并发首存竞态" do
    test "两任务同传 base_version 0 → 恰一成一败(version_conflict),落库一行 version 1" do
      {admin, workspace, course, tutors} =
        unboxed(fn ->
          admin = Fixtures.platform_admin("dv-race-admin")
          workspace = Fixtures.create_workspace(admin)
          course = EventFixtures.create_course(workspace, admin, %{})

          tutors =
            for name <- ["dv-race-a", "dv-race-b"] do
              tutor = Fixtures.register_user(name)
              Fixtures.add_member(workspace, tutor, [:tutor])
              tutor
            end

          {admin, workspace, course, tutors}
        end)

      cleanup_on_exit(workspace.id, [admin | tutors])
      barrier = start_supervised!({Barrier, 2})

      results =
        tutors
        |> Enum.with_index()
        |> Enum.map(fn {tutor, idx} ->
          Task.async(fn ->
            unboxed(fn ->
              Barrier.arrive(barrier)

              case save(tutor, workspace, course, %{
                     "base_version" => 0,
                     "content" => content_fixture(["tutor #{idx} 的内容"])
                   }) do
                {:reply, response, _frame} ->
                  [content] = response.content
                  {:ok, Jason.decode!(content["text"])}

                {:error, %Anubis.MCP.Error{message: msg}, _frame} ->
                  {:error, msg}
              end
            end)
          end)
        end)
        |> Task.await_many(15_000)

      assert Enum.count(results, &match?({:ok, _}, &1)) == 1
      assert Enum.count(results, &match?({:error, _}, &1)) == 1

      {:ok, winner} = Enum.find(results, &match?({:ok, _}, &1))
      assert winner["version"] == 1

      {:error, loser_msg} = Enum.find(results, &match?({:error, _}, &1))
      assert loser_msg =~ "version_conflict"
      assert loser_msg =~ "version 1"
      assert loser_msg =~ "get_course_content"

      # 落库恰一行,version 1(胜者首存)
      unboxed(fn ->
        rows =
          Output
          |> Ash.Query.filter(key == ^Output.course_key(course.id))
          |> Ash.read!(authorize?: false)

        assert [%{version: 1}] = rows
      end)
    end
  end

  # unboxed 真实提交行的显式清理(sponsorship_concurrency_test 同款):
  # mcp_tool_call_logs 无 FK,admin_action_logs 无 FK 不级联,必须显式删
  defp cleanup_on_exit(workspace_id, users) do
    on_exit(fn ->
      unboxed(fn ->
        Cgc2046.Repo.query!(
          "DELETE FROM mcp_tool_call_logs WHERE user_id = ANY($1)",
          [Enum.map(users, &Ecto.UUID.dump!(&1.id))]
        )

        Cgc2046.Repo.query!("DELETE FROM curriculum_outputs WHERE workspace_id = $1", [
          Ecto.UUID.dump!(workspace_id)
        ])

        Cgc2046.Repo.query!("DELETE FROM courses WHERE workspace_id = $1", [
          Ecto.UUID.dump!(workspace_id)
        ])

        Cgc2046.Repo.query!(
          "DELETE FROM admin_action_logs WHERE target_type = 'workspace' AND target_id = $1",
          [Ecto.UUID.dump!(workspace_id)]
        )

        Cgc2046.Repo.query!(
          "DELETE FROM membership_roles WHERE membership_id IN " <>
            "(SELECT id FROM workspace_memberships WHERE workspace_id = $1)",
          [Ecto.UUID.dump!(workspace_id)]
        )

        Cgc2046.Repo.query!("DELETE FROM workspace_memberships WHERE workspace_id = $1", [
          Ecto.UUID.dump!(workspace_id)
        ])

        Cgc2046.Repo.query!("DELETE FROM workspaces WHERE id = $1", [
          Ecto.UUID.dump!(workspace_id)
        ])

        Enum.each(users, fn user ->
          Cgc2046.Repo.query!("DELETE FROM users WHERE id = $1", [Ecto.UUID.dump!(user.id)])
        end)
      end)
    end)
  end

  defp unboxed(fun), do: Ecto.Adapters.SQL.Sandbox.unboxed_run(Cgc2046.Repo, fun)
end
