defmodule Cgc2046.Curriculum.OutputDeletionTest do
  @moduledoc """
  #704：删除已提交或持有宿主行锁时，保存不得产生孤儿内容行或假成功。

  并发布置与双方操作均经 unboxed_run 真实提交，连接互相独立；Sandbox.allow
  共享同一物理连接，不能构造行锁交错。以 pg_blocking_pids 的实际阻塞关系
  或 save 提前完成作 witness，不用 sleep，也不靠任务启动顺序猜测锁已到达。
  """
  use Cgc2046.DataCase, async: false

  alias Cgc2046.AccountsFixtures, as: Fixtures
  alias Cgc2046.Courses.Course
  alias Cgc2046.Curriculum.Output

  require Ash.Query

  test "删除已提交后，陈旧课程的首存失败且无孤儿内容行" do
    admin = Fixtures.platform_admin("output-deleted")
    workspace = Fixtures.create_workspace(admin)
    course = draft_course(workspace, admin)
    assert :ok = Ash.destroy(course, action: :delete, actor: admin, tenant: workspace.id)
    assert {:error, error} = save(workspace, admin, course)
    assert Cgc2046.Mcp.Errors.message(error, "fallback") == "course not found"
    assert_no_output(workspace, course)
  end

  test "删除未提交时，save 等待删除提交后失败，而非提前 saved" do
    {admin, workspace, course} =
      unboxed(fn ->
        admin = Fixtures.platform_admin("output-delete-race")
        workspace = Fixtures.create_workspace(admin)
        {admin, workspace, draft_course(workspace, admin)}
      end)

    cleanup_on_exit(admin, workspace, course)
    supervisor = start_supervised!(Task.Supervisor)
    parent = self()
    release = make_ref()

    deleter =
      Task.Supervisor.async_nolink(supervisor, fn ->
        receive do
          :go -> :ok
        end

        unboxed(fn ->
          Repo.transact(fn ->
            %{rows: [[backend_pid]]} = Repo.query!("SELECT pg_backend_pid()")

            Repo.query!("SELECT id FROM courses WHERE id = $1 FOR UPDATE", [Repo.uuid!(course.id)])

            assert :ok = Ash.destroy(course, action: :delete, actor: admin, tenant: workspace.id)
            send(parent, {:deleted_uncommitted, self(), backend_pid})

            receive do
              {:release, ^release} ->
                send(parent, {:release_received, self()})
                {:ok, :deleted}
            after
              10_000 -> exit(:delete_release_not_received)
            end
          end)
        end)
      end)

    # 在触发 A 前即设置 monitor，不留 send 与 monitor 之间的退出盲区。
    deleter_monitor = Process.monitor(deleter.pid)
    send(deleter.pid, :go)

    saver =
      Task.Supervisor.async_nolink(supervisor, fn ->
        unboxed(fn ->
          %{rows: [[backend_pid]]} = Repo.query!("SELECT pg_backend_pid()")
          send(parent, {:save_connection, self(), backend_pid})

          receive do
            :go -> save(workspace, admin, course)
          end
        end)
      end)

    try do
      deleter_pid = deleter.pid
      saver_pid = saver.pid
      assert_receive {:deleted_uncommitted, ^deleter_pid, delete_backend}, 5_000
      assert_receive {:save_connection, ^saver_pid, save_backend}, 5_000
      refute delete_backend == save_backend
      send(saver.pid, :go)

      witness =
        await_save_witness(
          saver,
          deleter_monitor,
          delete_backend,
          save_backend,
          System.monotonic_time(:millisecond) + 5_000
        )

      send(deleter.pid, {:release, release})
      assert_receive {:release_received, ^deleter_pid}, 5_000
      assert {:ok, :deleted} = Task.await(deleter, 5_000)
      assert_receive {:DOWN, ^deleter_monitor, :process, ^deleter_pid, :normal}, 5_000

      result =
        case witness do
          {:blocked, _query} ->
            case Task.yield(saver, 10_000) do
              {:ok, result} ->
                result

              {:exit, reason} ->
                flunk("save task crashed after delete committed: #{inspect(reason)}")

              nil ->
                flunk(
                  "save remained blocked after delete committed: #{inspect(activity(save_backend))}"
                )
            end

          {:completed, result} ->
            result
        end

      assert match?({:blocked, _}, witness),
             "save completed before delete committed (missing host lock): #{inspect(result)}"

      assert {:error, error} = result
      assert Cgc2046.Mcp.Errors.message(error, "fallback") == "course not found"
      unboxed(fn -> assert_no_output(workspace, course) end)
    after
      # 所有失败路径都终止双方；owner 退出由 DBConnection 监控触发回滚/归还连接。
      Task.shutdown(saver, :brutal_kill)
      Task.shutdown(deleter, :brutal_kill)
      Process.demonitor(deleter_monitor, [:flush])
    end
  end

  defp await_save_witness(saver, deleter_monitor, delete_backend, save_backend, deadline) do
    receive do
      {ref, result} when ref == saver.ref ->
        Process.demonitor(saver.ref, [:flush])
        {:completed, result}

      {:DOWN, ^deleter_monitor, :process, _pid, reason} ->
        flunk(
          "delete task failed before release: #{inspect(reason)}; save SQL: #{inspect(activity(save_backend))}"
        )

      {:DOWN, ref, :process, _pid, reason} when ref == saver.ref ->
        flunk("save task crashed before delete committed: #{inspect(reason)}")
    after
      0 ->
        case activity(save_backend) do
          {blockers, query} ->
            cond do
              delete_backend in blockers ->
                {:blocked, query}

              System.monotonic_time(:millisecond) >= deadline ->
                flunk(
                  "save neither completed nor waited on delete: #{inspect({blockers, query})}"
                )

              true ->
                await_save_witness(saver, deleter_monitor, delete_backend, save_backend, deadline)
            end
        end
    end
  end

  defp activity(backend_pid) do
    unboxed(fn ->
      case Repo.query!(
             "SELECT pg_blocking_pids(pid), query FROM pg_stat_activity WHERE pid = $1",
             [backend_pid]
           ).rows do
        [[blockers, query]] -> {blockers, query}
        [] -> {[], "connection exited"}
      end
    end)
  end

  defp draft_course(workspace, admin) do
    Course
    |> Ash.Changeset.for_create(:create, %{title: "待删教研草稿"}, tenant: workspace.id)
    |> Ash.create!(tenant: workspace.id, actor: admin)
  end

  defp save(workspace, admin, course) do
    Output
    |> Ash.Changeset.for_create(
      :upsert_content,
      %{
        key: Output.course_key(course.id),
        kind: :issues,
        submitted_by: admin.id,
        base_version: 0,
        data: %{
          "goals" => ["写一个问候程序"],
          "issues" => [
            %{
              "id" => "hello",
              "kind" => "handwork",
              "title" => "问候程序",
              "story" => %{
                "as_a" => "学员",
                "given" => [],
                "goal" => "独立输出问候",
                "materials" => [],
                "checklist" => [%{"id" => "run", "text" => "程序输出问候"}]
              },
              "objectives" => [
                %{
                  "id" => "write",
                  "title" => "编写程序",
                  "rubric" => [%{"id" => "r1", "text" => "可独立编写"}]
                }
              ]
            }
          ]
        }
      },
      tenant: workspace.id,
      actor: admin
    )
    |> Ash.create(tenant: workspace.id, actor: admin)
  end

  defp assert_no_output(workspace, course) do
    assert [] ==
             Output
             |> Ash.Query.filter(key == ^Output.course_key(course.id))
             |> Ash.read!(authorize?: false, tenant: workspace.id)
  end

  defp unboxed(fun), do: Ecto.Adapters.SQL.Sandbox.unboxed_run(Repo, fun)

  defp cleanup_on_exit(admin, workspace, course) do
    on_exit(fn ->
      unboxed(fn ->
        Repo.query!("DELETE FROM oban_jobs WHERE args->'data'->>'course_id' = $1", [course.id])

        Repo.query!("DELETE FROM curriculum_outputs WHERE workspace_id = $1", [
          Repo.uuid!(workspace.id)
        ])

        Repo.query!("DELETE FROM courses WHERE workspace_id = $1", [Repo.uuid!(workspace.id)])

        Repo.query!(
          "DELETE FROM admin_action_logs WHERE target_type = 'workspace' AND target_id = $1",
          [Repo.uuid!(workspace.id)]
        )

        Repo.query!(
          "DELETE FROM membership_roles WHERE membership_id IN " <>
            "(SELECT id FROM workspace_memberships WHERE workspace_id = $1)",
          [Repo.uuid!(workspace.id)]
        )

        Repo.query!("DELETE FROM workspace_memberships WHERE workspace_id = $1", [
          Repo.uuid!(workspace.id)
        ])

        Repo.query!("DELETE FROM workflow_definitions WHERE workspace_id = $1", [
          Repo.uuid!(workspace.id)
        ])

        Repo.query!("DELETE FROM workspaces WHERE id = $1", [Repo.uuid!(workspace.id)])
        Repo.query!("DELETE FROM users WHERE id = $1", [Repo.uuid!(admin.id)])
      end)
    end)
  end
end
