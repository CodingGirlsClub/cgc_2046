defmodule Cgc2046.Workflows.WorkflowRunTest do
  use Cgc2046Web.ConnCase, async: true

  alias Cgc2046.AccountsFixtures, as: Fixtures

  alias Cgc2046.Workflows.WorkflowDefinition
  alias Cgc2046.Workflows.WorkflowRun
  alias Cgc2046.Workflows.Engine
  alias Cgc2046.MiniprogramFixtures.Barrier

  require Ash.Query

  defp create_definition(workspace, actor, attrs \\ %{}) do
    defaults = %{
      name: "教研 workflow（测试布景）",
      type: :curriculum,
      input_schema: %{"topic" => "string"},
      node_def: %{steps: ["outline_design", "content_review"]},
      approval_timeout: 604_800
    }

    WorkflowDefinition
    |> Ash.Changeset.for_create(:create, Map.merge(defaults, attrs),
      tenant: workspace.id,
      actor: actor
    )
    |> Ash.create(tenant: workspace.id, actor: actor)
  end

  defp publish_definition(defn, workspace, actor) do
    defn
    |> Ash.Changeset.for_update(:publish, %{}, actor: actor)
    |> Ash.update(tenant: workspace.id, actor: actor)
  end

  defp create_run(workspace, actor, defn, attrs \\ %{}) do
    defaults = %{
      definition_id: defn.id,
      definition_version: defn.version,
      input_snapshot: %{"topic" => "t1"}
    }

    WorkflowRun
    |> Ash.Changeset.for_create(:create, Map.merge(defaults, attrs),
      tenant: workspace.id,
      actor: actor
    )
    |> Ash.create(tenant: workspace.id, actor: actor)
  end

  # 单步人工门控
  defp manual_node_def do
    %{
      "steps" => [
        %{"id" => "approval", "type" => "manual"}
      ]
    }
  end

  # 双步人工门控：a1 → a2
  defp gated_node_def do
    %{
      "steps" => [
        %{"id" => "a1", "type" => "manual"},
        %{"id" => "a2", "type" => "manual"}
      ]
    }
  end

  describe "state machine" do
    test "create defaults to status=pending, version=1, facts=%{}" do
      admin = Fixtures.platform_admin("wfrun-admin")
      workspace = Fixtures.create_workspace(admin)
      {:ok, defn} = create_definition(workspace, admin)
      {:ok, published} = publish_definition(defn, workspace, admin)

      {:ok, run} = create_run(workspace, admin, published)

      assert run.status == :pending
      assert run.version == 1
      assert run.facts == %{}
      assert run.definition_id == published.id
      assert run.definition_version == published.version
      assert run.partition_id == workspace.id
      assert run.input_snapshot == %{"topic" => "t1"}
      assert is_nil(run.started_at)
      assert is_nil(run.finished_at)
    end

    test "partition_id forced to workspace_id (ADR-0002 决策 6)" do
      admin = Fixtures.platform_admin("wfrun-admin")
      workspace = Fixtures.create_workspace(admin)
      {:ok, defn} = create_definition(workspace, admin)
      {:ok, published} = publish_definition(defn, workspace, admin)

      # partition_id 不接受调用方传入（不在 accept 列表），由 tenant 强制
      assert {:error, %Ash.Error.Invalid{}} =
               WorkflowRun
               |> Ash.Changeset.for_create(:create, %{
                 definition_id: published.id,
                 definition_version: published.version,
                 input_snapshot: %{"topic" => "t1"},
                 partition_id: Ecto.UUID.generate()
               })
               |> Ash.create(tenant: workspace.id, actor: admin)

      {:ok, run} = create_run(workspace, admin, published)
      assert run.partition_id == workspace.id
    end

    # /check SC2-004：跨租户 definition_id 必须被拒（对照 new_version 的归属守卫）
    test "create rejects cross-tenant definition_id (SC2-004)" do
      admin = Fixtures.platform_admin("wfrun-admin")
      ws_a = Fixtures.create_workspace(admin)
      ws_b = Fixtures.create_workspace(admin)

      {:ok, defn_a} = create_definition(ws_a, admin)
      {:ok, published_a} = publish_definition(defn_a, ws_a, admin)

      assert {:error, %Ash.Error.Invalid{errors: errors}} =
               WorkflowRun
               |> Ash.Changeset.for_create(
                 :create,
                 %{
                   definition_id: published_a.id,
                   definition_version: published_a.version,
                   input_snapshot: %{"topic" => "t1"}
                 },
                 tenant: ws_b.id
               )
               |> Ash.create(tenant: ws_b.id, actor: admin)

      # 跨租户读被 tenant 作用域拒绝 → not found；若作用域失效则 workspace 归属守卫兜底
      assert Enum.any?(errors, fn e ->
               msg = Exception.message(e)
               msg =~ "not found" or msg =~ "belongs to a different workspace"
             end)
    end

    # /check SC2-004：definition_version 必须与 definition_id 行的 version 一致（防矛盾/伪造）
    test "create rejects mismatched definition_version (SC2-004)" do
      admin = Fixtures.platform_admin("wfrun-admin")
      workspace = Fixtures.create_workspace(admin)
      {:ok, defn} = create_definition(workspace, admin)
      {:ok, published} = publish_definition(defn, workspace, admin)

      assert {:error, %Ash.Error.Invalid{errors: errors}} =
               WorkflowRun
               |> Ash.Changeset.for_create(
                 :create,
                 %{
                   definition_id: published.id,
                   definition_version: 999,
                   input_snapshot: %{"topic" => "t1"}
                 },
                 tenant: workspace.id
               )
               |> Ash.create(tenant: workspace.id, actor: admin)

      assert Enum.any?(errors, &(Exception.message(&1) =~ "got definition_version"))
    end

    # /check SC2-005：状态流转 action 不接受 input_snapshot/definition_version（D-A2 快照）
    test "start rejects input_snapshot/definition_version rebinding (SC2-005)" do
      admin = Fixtures.platform_admin("wfrun-admin")
      workspace = Fixtures.create_workspace(admin)
      {:ok, defn} = create_definition(workspace, admin)
      {:ok, published} = publish_definition(defn, workspace, admin)
      {:ok, run} = create_run(workspace, admin, published)

      assert {:error, %Ash.Error.Invalid{}} =
               run
               |> Ash.Changeset.for_update(:start, %{
                 input_snapshot: %{"evil" => true},
                 definition_version: 999
               })
               |> Ash.update(tenant: workspace.id, actor: admin)
    end

    test "pending → running → waiting → running → succeeded" do
      admin = Fixtures.platform_admin("wfrun-admin")
      workspace = Fixtures.create_workspace(admin)
      {:ok, defn} = create_definition(workspace, admin)
      {:ok, published} = publish_definition(defn, workspace, admin)
      {:ok, run} = create_run(workspace, admin, published)

      {:ok, running} =
        run
        |> Ash.Changeset.for_update(:start, %{}, actor: admin)
        |> Ash.update(tenant: workspace.id, actor: admin)

      assert running.status == :running
      assert running.version == 2
      refute is_nil(running.started_at)

      {:ok, waiting} =
        running
        |> Ash.Changeset.for_update(:wait, %{}, actor: admin)
        |> Ash.update(tenant: workspace.id, actor: admin)

      assert waiting.status == :waiting

      {:ok, resumed} =
        waiting
        |> Ash.Changeset.for_update(:resume, %{}, actor: admin)
        |> Ash.update(tenant: workspace.id, actor: admin)

      assert resumed.status == :running

      {:ok, succeeded} =
        resumed
        |> Ash.Changeset.for_update(:complete, %{facts: %{"uppercase" => %{text: "T1"}}},
          actor: admin
        )
        |> Ash.update(tenant: workspace.id, actor: admin)

      assert succeeded.status == :succeeded
      assert succeeded.facts == %{"uppercase" => %{"text" => "T1"}}
      refute is_nil(succeeded.finished_at)
    end

    test "running → failed" do
      admin = Fixtures.platform_admin("wfrun-admin")
      workspace = Fixtures.create_workspace(admin)
      {:ok, defn} = create_definition(workspace, admin)
      {:ok, published} = publish_definition(defn, workspace, admin)
      {:ok, run} = create_run(workspace, admin, published)

      {:ok, running} =
        run
        |> Ash.Changeset.for_update(:start, %{}, actor: admin)
        |> Ash.update(tenant: workspace.id, actor: admin)

      {:ok, failed} =
        running
        |> Ash.Changeset.for_update(:fail, %{}, actor: admin)
        |> Ash.update(tenant: workspace.id, actor: admin)

      assert failed.status == :failed
      refute is_nil(failed.finished_at)
    end

    test "pending → cancelled" do
      admin = Fixtures.platform_admin("wfrun-admin")
      workspace = Fixtures.create_workspace(admin)
      {:ok, defn} = create_definition(workspace, admin)
      {:ok, published} = publish_definition(defn, workspace, admin)
      {:ok, run} = create_run(workspace, admin, published)

      {:ok, cancelled} =
        run
        |> Ash.Changeset.for_update(:cancel, %{}, actor: admin)
        |> Ash.update(tenant: workspace.id, actor: admin)

      assert cancelled.status == :cancelled
    end

    test "waiting → expired" do
      admin = Fixtures.platform_admin("wfrun-admin")
      workspace = Fixtures.create_workspace(admin)
      {:ok, defn} = create_definition(workspace, admin)
      {:ok, published} = publish_definition(defn, workspace, admin)
      {:ok, run} = create_run(workspace, admin, published)

      {:ok, running} =
        run
        |> Ash.Changeset.for_update(:start, %{}, actor: admin)
        |> Ash.update(tenant: workspace.id, actor: admin)

      {:ok, waiting} =
        running
        |> Ash.Changeset.for_update(:wait, %{}, actor: admin)
        |> Ash.update(tenant: workspace.id, actor: admin)

      {:ok, expired} =
        waiting
        |> Ash.Changeset.for_update(:expire, %{}, actor: admin)
        |> Ash.update(tenant: workspace.id, actor: admin)

      assert expired.status == :expired
    end

    test "invalid transitions rejected" do
      admin = Fixtures.platform_admin("wfrun-admin")
      workspace = Fixtures.create_workspace(admin)
      {:ok, defn} = create_definition(workspace, admin)
      {:ok, published} = publish_definition(defn, workspace, admin)
      {:ok, run} = create_run(workspace, admin, published)

      # pending 不能 complete / fail / wait
      assert {:error, _} =
               run
               |> Ash.Changeset.for_update(:complete, %{}, actor: admin)
               |> Ash.update(tenant: workspace.id, actor: admin)

      assert {:error, _} =
               run
               |> Ash.Changeset.for_update(:fail, %{}, actor: admin)
               |> Ash.update(tenant: workspace.id, actor: admin)

      assert {:error, _} =
               run
               |> Ash.Changeset.for_update(:wait, %{}, actor: admin)
               |> Ash.update(tenant: workspace.id, actor: admin)

      # 终态不可再流转
      {:ok, cancelled} =
        run
        |> Ash.Changeset.for_update(:cancel, %{}, actor: admin)
        |> Ash.update(tenant: workspace.id, actor: admin)

      assert {:error, _} =
               cancelled
               |> Ash.Changeset.for_update(:start, %{}, actor: admin)
               |> Ash.update(tenant: workspace.id, actor: admin)

      assert {:error, _} =
               cancelled
               |> Ash.Changeset.for_update(:expire, %{}, actor: admin)
               |> Ash.update(tenant: workspace.id, actor: admin)
    end
  end

  describe "engine execution" do
    test "manual definition runs via Engine.run/2 + Engine.resume/3 and completes via start_run/resume_signal" do
      admin = Fixtures.platform_admin("wfrun-admin")
      workspace = Fixtures.create_workspace(admin)
      {:ok, defn} = create_definition(workspace, admin, %{node_def: manual_node_def()})
      {:ok, published} = publish_definition(defn, workspace, admin)
      {:ok, run} = create_run(workspace, admin, published, %{input_snapshot: %{"text" => "hi"}})

      # 纯函数验证：Engine.run 进入 waiting，Engine.resume 放行完成
      assert {:waiting, %{}} = Engine.run(published.node_def, run.input_snapshot)

      assert {:ok, %{}} =
               Engine.resume(published.node_def, [], %{"signal_type" => "workflow.approval"})

      # 壳资源全链路：start_run → waiting → resume_signal → succeeded
      {:ok, waiting} =
        run
        |> Ash.Changeset.for_update(:start_run, %{}, actor: admin)
        |> Ash.update(tenant: workspace.id, actor: admin)

      assert waiting.status == :waiting

      {:ok, succeeded} =
        waiting
        |> Ash.Changeset.for_update(
          :resume_signal,
          %{signal_type: "workflow.approval", payload: %{"approved_by" => "u1"}},
          actor: admin
        )
        |> Ash.update(tenant: workspace.id, actor: admin)

      assert succeeded.status == :succeeded
      refute is_nil(succeeded.finished_at)
    end

    test "manual step gates downstream until signals (waiting → resume_signal → succeeded)" do
      admin = Fixtures.platform_admin("wfrun-admin")
      workspace = Fixtures.create_workspace(admin)
      {:ok, defn} = create_definition(workspace, admin, %{node_def: gated_node_def()})
      {:ok, published} = publish_definition(defn, workspace, admin)
      {:ok, run} = create_run(workspace, admin, published, %{input_snapshot: %{"text" => "hi"}})

      assert {:waiting, %{}} = Engine.run(published.node_def, run.input_snapshot)
      assert {:waiting, %{}} = Engine.resume(published.node_def, [], "workflow.a1")
      assert {:ok, %{}} = Engine.resume(published.node_def, ["workflow.a1"], "workflow.a2")

      {:ok, waiting} =
        run
        |> Ash.Changeset.for_update(:start_run, %{}, actor: admin)
        |> Ash.update(tenant: workspace.id, actor: admin)

      assert waiting.status == :waiting

      {:ok, waiting2} =
        waiting
        |> Ash.Changeset.for_update(:resume_signal, %{signal_type: "workflow.a1"}, actor: admin)
        |> Ash.update(tenant: workspace.id, actor: admin)

      assert waiting2.status == :waiting

      {:ok, succeeded} =
        waiting2
        |> Ash.Changeset.for_update(:resume_signal, %{signal_type: "workflow.a2"}, actor: admin)
        |> Ash.update(tenant: workspace.id, actor: admin)

      assert succeeded.status == :succeeded
    end

    test "invalid or corrupted node_def returns {:error, reason} and marks run failed" do
      admin = Fixtures.platform_admin("wfrun-admin")
      workspace = Fixtures.create_workspace(admin)

      bad_node_def = %{
        "steps" => [
          %{"id" => "legacy_auto", "type" => "auto"}
        ]
      }

      {:ok, defn} = create_definition(workspace, admin, %{node_def: bad_node_def})
      {:ok, published} = publish_definition(defn, workspace, admin)
      {:ok, run} = create_run(workspace, admin, published)

      assert {:error, {:unsupported_step_type, "auto"}} =
               Engine.run(published.node_def, run.input_snapshot)

      assert {:error, {:unsupported_step_type, "auto"}} =
               Engine.resume(published.node_def, [], "workflow.legacy_auto")

      {:ok, failed} =
        run
        |> Ash.Changeset.for_update(:start_run, %{}, actor: admin)
        |> Ash.update(tenant: workspace.id, actor: admin)

      assert failed.status == :failed
      refute is_nil(failed.finished_at)
    end
  end

  describe "learning run subject anchor (M1)" do
    defp create_learning_run(workspace, actor, learner) do
      {:ok, defn} =
        create_definition(workspace, actor, %{
          name: "学习 workflow（测试布景）",
          type: :learning,
          input_schema: %{},
          node_def: %{"steps" => [%{"id" => "s1", "type" => "manual"}]}
        })

      {:ok, published} = publish_definition(defn, workspace, actor)

      create_run(workspace, actor, published, %{
        input_snapshot: %{"user_id" => learner.id, "title" => "t"}
      })
    end

    # 布置而非被测对象：摘掉 snapshot 的 user_id 键，subject_* 列保持不动。
    defp strip_snapshot_user_id(run) do
      {:ok, _} =
        Ecto.Adapters.SQL.query(
          Cgc2046.Repo,
          "UPDATE workflow_runs SET input_snapshot = input_snapshot - 'user_id' WHERE id = $1",
          [Ecto.UUID.dump!(run.id)]
        )

      :ok
    end

    test "同工作台普通成员读他人 learning run = 空" do
      admin = Fixtures.platform_admin("wfrun-m1")
      workspace = Fixtures.create_workspace(admin)
      learner = Fixtures.register_user("wfrun-m1-learner")
      Fixtures.add_member(workspace, learner, [:learner])
      {:ok, _run} = create_learning_run(workspace, admin, learner)

      member = Fixtures.register_user("wfrun-m1-member")
      Fixtures.add_member(workspace, member, [:learner])

      assert [] =
               WorkflowRun
               |> Ash.Query.for_read(:read)
               |> Ash.read!(tenant: workspace.id, actor: member)
    end

    test "Owner/Admin/Tutor 读他人 learning run = 空" do
      admin = Fixtures.platform_admin("wfrun-m1")
      workspace = Fixtures.create_workspace(admin)
      learner = Fixtures.register_user("wfrun-m1-learner")
      Fixtures.add_member(workspace, learner, [:learner])
      {:ok, _run} = create_learning_run(workspace, admin, learner)

      # 工作台角色成员（非 platform admin——平台管理员另有独立审计 policy 分支，
      # 不在本用例范围）：owner/admin/tutor 角色均不得读他人 learning run
      staff_users =
        for {prefix, roles} <- [
              {"wfrun-m1-owner", [:owner]},
              {"wfrun-m1-admin", [:admin]},
              {"wfrun-m1-tutor", [:tutor]}
            ] do
          user = Fixtures.register_user(prefix)
          Fixtures.add_member(workspace, user, roles)
          user
        end

      for staff <- staff_users do
        assert [] =
                 WorkflowRun
                 |> Ash.Query.for_read(:read)
                 |> Ash.read!(tenant: workspace.id, actor: staff)
      end
    end

    test "本人可读；snapshot 摘掉 user_id 键后仍可读（subject 列是唯一授权锚）" do
      admin = Fixtures.platform_admin("wfrun-m1")
      workspace = Fixtures.create_workspace(admin)
      learner = Fixtures.register_user("wfrun-m1-learner")
      Fixtures.add_member(workspace, learner, [:learner])
      {:ok, run} = create_learning_run(workspace, admin, learner)

      strip_snapshot_user_id(run)

      assert [%WorkflowRun{id: id}] =
               WorkflowRun
               |> Ash.Query.for_read(:read)
               |> Ash.read!(tenant: workspace.id, actor: learner)

      assert id == run.id
    end

    test "成员可读非 learning run（正向对照）" do
      admin = Fixtures.platform_admin("wfrun-m1")
      workspace = Fixtures.create_workspace(admin)
      {:ok, defn} = create_definition(workspace, admin)
      {:ok, published} = publish_definition(defn, workspace, admin)
      {:ok, run} = create_run(workspace, admin, published)

      member = Fixtures.register_user("wfrun-m1-member")
      Fixtures.add_member(workspace, member, [:learner])

      assert [%WorkflowRun{id: id}] =
               WorkflowRun
               |> Ash.Query.for_read(:read)
               |> Ash.read!(tenant: workspace.id, actor: member)

      assert id == run.id
    end

    test "create learning run 缺 user_id → 报错" do
      admin = Fixtures.platform_admin("wfrun-m1")
      workspace = Fixtures.create_workspace(admin)

      {:ok, defn} =
        create_definition(workspace, admin, %{
          name: "学习 workflow（测试布景）",
          type: :learning,
          input_schema: %{},
          node_def: %{"steps" => [%{"id" => "s1", "type" => "manual"}]}
        })

      {:ok, published} = publish_definition(defn, workspace, admin)

      assert {:error, %Ash.Error.Invalid{errors: errors}} =
               create_run(workspace, admin, published, %{input_snapshot: %{"title" => "t"}})

      assert Enum.any?(errors, fn
               %{message: message} when is_binary(message) ->
                 message =~ "learning run requires input_snapshot user_id"

               _ ->
                 false
             end)
    end
  end

  describe "tenant isolation" do
    test "cross-workspace run not visible" do
      admin = Fixtures.platform_admin("wfrun-admin")
      ws_a = Fixtures.create_workspace(admin)
      ws_b = Fixtures.create_workspace(admin)

      {:ok, defn_a} = create_definition(ws_a, admin)
      {:ok, published_a} = publish_definition(defn_a, ws_a, admin)
      {:ok, _run_a} = create_run(ws_a, admin, published_a)

      results =
        WorkflowRun
        |> Ash.Query.for_read(:read)
        |> Ash.Query.filter(definition_id == ^published_a.id)
        |> Ash.read!(tenant: ws_b.id, actor: admin)

      assert results == []
    end

    test "non-member non-platform-admin cannot read run (H3)" do
      admin = Fixtures.platform_admin("wfrun-admin")
      workspace = Fixtures.create_workspace(admin)
      {:ok, defn} = create_definition(workspace, admin)
      {:ok, published} = publish_definition(defn, workspace, admin)
      {:ok, run} = create_run(workspace, admin, published)
      outsider = Fixtures.register_user("wfrun-outsider")

      assert {:error, _} =
               Ash.get(WorkflowRun, run.id, tenant: workspace.id, actor: outsider)
    end
  end

  describe "optimistic lock" do
    test "concurrent whole-facts writes from one snapshot have one winner" do
      admin = Fixtures.platform_admin("wfrun-facts-race-admin")
      workspace = Fixtures.create_workspace(admin)
      {:ok, defn} = create_definition(workspace, admin)
      {:ok, published} = publish_definition(defn, workspace, admin)
      {:ok, run} = create_run(workspace, admin, published)
      barrier = start_supervised!({Barrier, 2})

      results =
        ["first_step", "second_step"]
        |> Enum.map(fn step_key ->
          Task.async(fn ->
            changeset =
              Ash.Changeset.for_update(
                run,
                :update_facts_for_mcp,
                %{facts: %{step_key => %{"ok" => true}}},
                authorize?: false
              )

            Barrier.arrive(barrier)
            Ash.update(changeset, tenant: workspace.id, authorize?: false)
          end)
        end)
        |> Task.await_many(15_000)

      assert Enum.count(results, &match?({:ok, _}, &1)) == 1
      assert Enum.count(results, &match?({:error, %Ash.Error.Invalid{}}, &1)) == 1

      assert {:ok, final_run} =
               Ash.get(WorkflowRun, run.id, authorize?: false, tenant: workspace.id)

      assert map_size(final_run.facts) == 1
      assert final_run.version == run.version + 1

      assert Enum.any?(results, fn
               {:error, %Ash.Error.Invalid{errors: errors}} ->
                 Enum.any?(errors, &match?(%Ash.Error.Changes.StaleRecord{}, &1))

               _ ->
                 false
             end)
    end

    test "concurrent update on stale version rejected" do
      admin = Fixtures.platform_admin("wfrun-admin")
      workspace = Fixtures.create_workspace(admin)
      {:ok, defn} = create_definition(workspace, admin)
      {:ok, published} = publish_definition(defn, workspace, admin)
      {:ok, run} = create_run(workspace, admin, published)

      # 两个并发方都基于 version=1 的 run 做 start
      {:ok, _} =
        run
        |> Ash.Changeset.for_update(:start, %{}, actor: admin)
        |> Ash.update(tenant: workspace.id, actor: admin)

      # 第二个 start 基于过期版本 → StaleRecord
      assert {:error, %Ash.Error.Invalid{errors: errors}} =
               run
               |> Ash.Changeset.for_update(:start, %{}, actor: admin)
               |> Ash.update(tenant: workspace.id, actor: admin)

      assert Enum.any?(errors, &match?(%Ash.Error.Changes.StaleRecord{}, &1))
    end
  end
end
