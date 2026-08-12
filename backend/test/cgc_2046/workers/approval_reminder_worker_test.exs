defmodule Cgc2046.Workers.ApprovalReminderWorkerTest do
  @moduledoc """
  48h 审批提醒 job 测试。

  F7 方案 A「deadline 前 48h 提醒审批人」的两条独立扫描：
  1. Enrollment 扫描（run-less 报名的单属主提醒路径）：status=pending 且
     approval_deadline 落在 (now, now+48h] 的报名，为工作台 Owner/Admin 逐人
     入队 approval_reminder 提醒（NotificationWorker 7 天 args-unique 去重）；
  2. WorkflowRun 扫描：waiting 且 deadline 落在 48h 窗口内的 run，每 run 落一条
     SignalLog（signal_type="workflow.approval_reminder"）作为提醒事实记录。
  """

  use Cgc2046Web.ConnCase, async: false
  use Oban.Testing, repo: Cgc2046.Repo

  alias Cgc2046.AccountsFixtures, as: Fixtures
  alias Cgc2046.Events.Enrollment
  alias Cgc2046.EventsFixtures, as: EventFixtures
  alias Cgc2046.Workers.ApprovalExpiryWorker
  alias Cgc2046.Workers.ApprovalReminderWorker
  alias Cgc2046.Workflows.SignalLog
  alias Cgc2046.Workflows.StepHandlerRegistry
  alias Cgc2046.Workflows.TestActions
  alias Cgc2046.Workflows.WorkflowDefinition
  alias Cgc2046.Workflows.WorkflowRun

  require Ash.Query

  setup do
    StepHandlerRegistry.register(TestActions.Uppercase)
    StepHandlerRegistry.register(TestActions.AppendExclamation)
    :ok
  end

  defp gated_node_def do
    %{
      "steps" => [
        %{
          "id" => "uppercase",
          "type" => "auto",
          "action" => "Elixir.Cgc2046.Workflows.TestActions.Uppercase"
        },
        %{"id" => "approval", "type" => "manual"},
        %{
          "id" => "append_exclamation",
          "type" => "auto",
          "action" => "Elixir.Cgc2046.Workflows.TestActions.AppendExclamation"
        }
      ]
    }
  end

  # 建 waiting run：definition 带指定 approval_timeout（秒），start_run 推进到 waiting
  defp create_waiting_run(workspace, admin, approval_timeout) do
    assert {:ok, defn} =
             WorkflowDefinition
             |> Ash.Changeset.for_create(
               :create,
               %{
                 name: "审批 workflow",
                 type: :research,
                 input_schema: %{"text" => "string"},
                 node_def: gated_node_def(),
                 approval_timeout: approval_timeout
               },
               tenant: workspace.id,
               actor: admin
             )
             |> Ash.create(tenant: workspace.id, actor: admin)

    assert {:ok, published} =
             defn
             |> Ash.Changeset.for_update(:publish, %{}, actor: admin)
             |> Ash.update(tenant: workspace.id, actor: admin)

    assert {:ok, run} =
             WorkflowRun
             |> Ash.Changeset.for_create(
               :create,
               %{
                 definition_id: published.id,
                 definition_version: published.version,
                 input_snapshot: %{"text" => "hi"}
               },
               tenant: workspace.id,
               actor: admin
             )
             |> Ash.create(tenant: workspace.id, actor: admin)

    assert {:ok, waiting} =
             run
             |> Ash.Changeset.for_update(:start_run, %{}, actor: admin)
             |> Ash.update(tenant: workspace.id, actor: admin)

    assert waiting.status == :waiting
    waiting
  end

  # 建 pending Enrollment：request 策略活动 + 指定 approval_deadline（默认创建后 7 天，
  # 测试显式放入 48h 窗口）
  defp create_pending_enrollment(event, workspace, learner, attrs) do
    Enrollment
    |> Ash.Changeset.for_create(
      :create_enrollment,
      Map.merge(%{event_id: event.id, user_id: learner.id}, attrs),
      tenant: workspace.id,
      actor: learner
    )
    |> Ash.create!(tenant: workspace.id, actor: learner)
  end

  defp reminder_logs_for(run) do
    SignalLog
    |> Ash.Query.filter(run_id == ^run.id and signal_type == "workflow.approval_reminder")
    |> Ash.read!(authorize?: false)
  end

  describe "48h 提醒窗口" do
    test "waiting 且 deadline 在未来 48h 内 → 落 SignalLog 提醒" do
      admin = Fixtures.platform_admin("reminder-admin")
      workspace = Fixtures.create_workspace(admin)
      # 审批超时 24h：deadline ≈ now+24h，落在 48h 窗口内
      waiting = create_waiting_run(workspace, admin, 86_400)

      assert :ok = perform_job(ApprovalReminderWorker, %{})

      assert [log] = reminder_logs_for(waiting)
      assert log.run_id == waiting.id
      assert log.signal_type == "workflow.approval_reminder"
      assert log.payload["kind"] == "approval_reminder_48h"
      assert is_binary(log.payload["approval_deadline"])
      refute is_nil(log.received_at)
    end

    test "多审批人：进入窗口的 pending Enrollment 给 Owner 与 Admin 各入队一条，不提醒申请人" do
      owner = Fixtures.platform_admin("reminder-admin")
      workspace = Fixtures.create_workspace(owner)

      admin =
        Fixtures.register_user("reminder-workspace-admin-#{System.unique_integer([:positive])}")

      Fixtures.add_member(workspace, admin, [:admin])

      learner =
        Fixtures.register_user("reminder-learner-#{System.unique_integer([:positive])}")

      event = EventFixtures.create_event(workspace, owner, %{enrollment_policy: :request})

      create_pending_enrollment(event, workspace, learner, %{
        approval_deadline: DateTime.add(DateTime.utc_now(), 24, :hour)
      })

      insert_identity(owner.id, "reminder-owner-openid")
      insert_identity(admin.id, "reminder-admin-openid")
      insert_identity(learner.id, "reminder-learner-openid")

      assert :ok = perform_job(ApprovalReminderWorker, %{})

      refute_enqueued(
        worker: Cgc2046.Workers.NotificationWorker,
        args: %{
          "user_id" => learner.id,
          "platform" => "wechat",
          "template_key" => "approval_reminder"
        }
      )

      for approver <- [owner, admin] do
        assert_enqueued(
          worker: Cgc2046.Workers.NotificationWorker,
          args: %{
            "user_id" => approver.id,
            "platform" => "wechat",
            "template_key" => "approval_reminder"
          }
        )
      end
    end

    test "deadline 超 48h → 不落" do
      admin = Fixtures.platform_admin("reminder-admin")
      workspace = Fixtures.create_workspace(admin)
      # 审批超时 72h：deadline ≈ now+72h，超出 48h 窗口
      waiting = create_waiting_run(workspace, admin, 259_200)

      assert :ok = perform_job(ApprovalReminderWorker, %{})

      assert reminder_logs_for(waiting) == []
    end

    test "approval_timeout = nil（无超时）→ 不落" do
      admin = Fixtures.platform_admin("reminder-admin")
      workspace = Fixtures.create_workspace(admin)
      waiting = create_waiting_run(workspace, admin, nil)

      assert :ok = perform_job(ApprovalReminderWorker, %{})

      assert reminder_logs_for(waiting) == []
    end

    test "幂等：同 run 重复执行只落一条（Oban 唯一任务之外的落库查重兜底）" do
      admin = Fixtures.platform_admin("reminder-admin")
      workspace = Fixtures.create_workspace(admin)
      waiting = create_waiting_run(workspace, admin, 86_400)

      assert :ok = perform_job(ApprovalReminderWorker, %{})
      assert :ok = perform_job(ApprovalReminderWorker, %{})

      assert [_one] = reminder_logs_for(waiting)
    end
  end

  describe "48h 提醒窗口（Enrollment 扫描单属主，run-less 覆盖）" do
    test "无 run 的 pending Enrollment 进入 48h 窗口 → 提醒审批人" do
      owner = Fixtures.platform_admin("reminder-admin")
      workspace = Fixtures.create_workspace(owner)

      learner =
        Fixtures.register_user("reminder-learner-#{System.unique_integer([:positive])}")

      event = EventFixtures.create_event(workspace, owner, %{enrollment_policy: :request})

      enrollment =
        create_pending_enrollment(event, workspace, learner, %{
          approval_deadline: DateTime.add(DateTime.utc_now(), 24, :hour)
        })

      assert is_nil(enrollment.workflow_run_id)

      insert_identity(owner.id, "reminder-owner-openid")

      assert :ok = perform_job(ApprovalReminderWorker, %{})

      assert_enqueued(
        worker: Cgc2046.Workers.NotificationWorker,
        args: %{
          "user_id" => owner.id,
          "platform" => "wechat",
          "template_key" => "approval_reminder",
          "data" => %{"enrollment_id" => enrollment.id}
        }
      )
    end

    test "deadline 超 48h 或已过期 → 不提醒" do
      owner = Fixtures.platform_admin("reminder-admin")
      workspace = Fixtures.create_workspace(owner)

      event = EventFixtures.create_event(workspace, owner, %{enrollment_policy: :request})

      learner_future =
        Fixtures.register_user("reminder-learner-future-#{System.unique_integer([:positive])}")

      learner_expired =
        Fixtures.register_user("reminder-learner-expired-#{System.unique_integer([:positive])}")

      create_pending_enrollment(event, workspace, learner_future, %{
        approval_deadline: DateTime.add(DateTime.utc_now(), 72, :hour)
      })

      create_pending_enrollment(event, workspace, learner_expired, %{
        approval_deadline: DateTime.add(DateTime.utc_now(), -1, :hour)
      })

      insert_identity(owner.id, "reminder-owner-openid")

      assert :ok = perform_job(ApprovalReminderWorker, %{})

      refute_enqueued(
        worker: Cgc2046.Workers.NotificationWorker,
        args: %{
          "user_id" => owner.id,
          "platform" => "wechat",
          "template_key" => "approval_reminder"
        }
      )
    end

    test "连续两次 perform_job → 同一报名同一收件人不重复入队" do
      owner = Fixtures.platform_admin("reminder-admin")
      workspace = Fixtures.create_workspace(owner)

      learner =
        Fixtures.register_user("reminder-learner-#{System.unique_integer([:positive])}")

      event = EventFixtures.create_event(workspace, owner, %{enrollment_policy: :request})

      create_pending_enrollment(event, workspace, learner, %{
        approval_deadline: DateTime.add(DateTime.utc_now(), 24, :hour)
      })

      insert_identity(owner.id, "reminder-owner-openid")

      assert :ok = perform_job(ApprovalReminderWorker, %{})
      assert :ok = perform_job(ApprovalReminderWorker, %{})

      assert [_one] =
               all_enqueued(
                 worker: Cgc2046.Workers.NotificationWorker,
                 args: %{
                   "user_id" => owner.id,
                   "template_key" => "approval_reminder"
                 }
               )
    end

    test "被丢弃的提醒任务释放去重名额，下一拍可重建（#7）" do
      owner = Fixtures.platform_admin("reminder-admin")
      workspace = Fixtures.create_workspace(owner)

      learner =
        Fixtures.register_user("reminder-learner-#{System.unique_integer([:positive])}")

      event = EventFixtures.create_event(workspace, owner, %{enrollment_policy: :request})

      create_pending_enrollment(event, workspace, learner, %{
        approval_deadline: DateTime.add(DateTime.utc_now(), 24, :hour)
      })

      insert_identity(owner.id, "reminder-owner-openid")

      assert :ok = perform_job(ApprovalReminderWorker, %{})

      assert [job] =
               all_enqueued(
                 worker: Cgc2046.Workers.NotificationWorker,
                 args: %{"user_id" => owner.id, "template_key" => "approval_reminder"}
               )

      # 模拟三次尝试耗尽的 discarded 终态
      {:ok, _} =
        Ecto.Adapters.SQL.query(
          Cgc2046.Repo,
          "UPDATE oban_jobs SET state = 'discarded' WHERE id = $1",
          [job.id]
        )

      assert :ok = perform_job(ApprovalReminderWorker, %{})

      # discarded 释放名额 → 重拍插入新行（all_enqueued 只见 available/scheduled/suspended，
      # 故用全表计数证明新插入发生）
      {:ok, %{rows: [[count]]}} =
        Ecto.Adapters.SQL.query(
          Cgc2046.Repo,
          "SELECT COUNT(*) FROM oban_jobs WHERE worker = 'Cgc2046.Workers.NotificationWorker' AND args->>'user_id' = $1 AND args->>'template_key' = 'approval_reminder'",
          [owner.id]
        )

      assert count == 2

      assert [_new] =
               all_enqueued(
                 worker: Cgc2046.Workers.NotificationWorker,
                 args: %{"user_id" => owner.id, "template_key" => "approval_reminder"}
               )
    end

    test "提醒发送时重查：报名已过期 → 不投递不消耗授权（#4）" do
      owner = Fixtures.platform_admin("reminder-admin")
      workspace = Fixtures.create_workspace(owner)

      learner =
        Fixtures.register_user("reminder-learner-#{System.unique_integer([:positive])}")

      event = EventFixtures.create_event(workspace, owner, %{enrollment_policy: :request})

      enrollment =
        create_pending_enrollment(event, workspace, learner, %{
          approval_deadline: DateTime.add(DateTime.utc_now(), 24, :hour)
        })

      insert_identity(owner.id, "reminder-owner-openid")
      {:ok, _} = Cgc2046.NotificationConsent.grant(owner.id, :wechat, "approval_reminder")

      # 入队后、执行前，报名被过期扫描转 expired
      {:ok, _} =
        Ecto.Adapters.SQL.query(
          Cgc2046.Repo,
          "UPDATE enrollments SET status = 'expired' WHERE id = $1",
          [Ecto.UUID.dump!(enrollment.id)]
        )

      assert :ok =
               perform_job(Cgc2046.Workers.NotificationWorker, %{
                 "user_id" => owner.id,
                 "identity_uid" => "reminder-owner-openid",
                 "platform" => "wechat",
                 "template_key" => "approval_reminder",
                 "data" => %{
                   "enrollment_id" => enrollment.id,
                   "approval_deadline" => DateTime.to_iso8601(enrollment.approval_deadline)
                 }
               })

      # 未投递 → 授权未被消费
      assert {:ok, 1} =
               Cgc2046.NotificationConsent.remaining(owner.id, :wechat, "approval_reminder")
    end

    test "带非空 workflow_run_id 的 pending Enrollment 处于窗口内 → 仅由 Enrollment 扫描产生每收件人一条提醒" do
      owner = Fixtures.platform_admin("reminder-admin")
      workspace = Fixtures.create_workspace(owner)

      learner =
        Fixtures.register_user("reminder-learner-#{System.unique_integer([:positive])}")

      event = EventFixtures.create_event(workspace, owner, %{enrollment_policy: :request})

      # run 的 deadline 在窗口外（approval_timeout 7 天），Enrollment 的 deadline 在窗口内
      waiting = create_waiting_run(workspace, owner, 7 * 86_400)

      enrollment =
        create_pending_enrollment(event, workspace, learner, %{
          workflow_run_id: waiting.id,
          approval_deadline: DateTime.add(DateTime.utc_now(), 24, :hour)
        })

      insert_identity(owner.id, "reminder-owner-openid")

      assert :ok = perform_job(ApprovalReminderWorker, %{})

      assert [_one] =
               all_enqueued(
                 worker: Cgc2046.Workers.NotificationWorker,
                 args: %{
                   "user_id" => owner.id,
                   "template_key" => "approval_reminder",
                   "data" => %{"enrollment_id" => enrollment.id}
                 }
               )
    end

    test "同一报名在两条扫描窗口内也只由 Enrollment 路径提醒一次（单属主）" do
      owner = Fixtures.platform_admin("reminder-admin")
      workspace = Fixtures.create_workspace(owner)

      learner =
        Fixtures.register_user("reminder-learner-#{System.unique_integer([:positive])}")

      event = EventFixtures.create_event(workspace, owner, %{enrollment_policy: :request})

      # run 的 deadline（approval_timeout 24h）与 Enrollment 的 deadline 都在 48h 窗口内
      waiting = create_waiting_run(workspace, owner, 86_400)

      enrollment =
        create_pending_enrollment(event, workspace, learner, %{
          workflow_run_id: waiting.id,
          approval_deadline: DateTime.add(DateTime.utc_now(), 24, :hour)
        })

      insert_identity(owner.id, "reminder-owner-openid")

      assert :ok = perform_job(ApprovalReminderWorker, %{})

      assert [_one] =
               all_enqueued(
                 worker: Cgc2046.Workers.NotificationWorker,
                 args: %{
                   "user_id" => owner.id,
                   "template_key" => "approval_reminder",
                   "data" => %{"enrollment_id" => enrollment.id}
                 }
               )
    end
  end

  describe "Oban 接线" do
    test "cron 配置注册 expiry（*/5 分钟）与 reminder（每小时）" do
      plugins = Application.get_env(:cgc_2046, Oban)[:plugins]
      assert {Oban.Plugins.Cron, cron_opts} = List.keyfind(plugins, Oban.Plugins.Cron, 0)
      crontab = Keyword.fetch!(cron_opts, :crontab)

      assert {"*/5 * * * *", ApprovalExpiryWorker} in crontab
      assert Enum.any?(crontab, fn {_schedule, worker} -> worker == ApprovalReminderWorker end)
    end

    test "manual 模式：insert 入队但不自动执行" do
      {:ok, job} = ApprovalReminderWorker.new(%{}) |> Oban.insert()

      # manual 模式：insert 落库（立即可执行 → available）但不消费，留队待断言
      assert job.state == "available"
      assert_enqueued(worker: ApprovalReminderWorker, queue: :maintenance)
    end

    test "唯一任务防重：同 args 窗口内重复 insert 标记 conflict" do
      {:ok, job1} = ApprovalReminderWorker.new(%{}) |> Oban.insert()
      refute job1.conflict?

      {:ok, job2} = ApprovalReminderWorker.new(%{}) |> Oban.insert()
      assert job2.conflict?
      assert job2.id == job1.id
    end
  end

  defp insert_identity(user_id, uid) do
    Cgc2046.Repo.query!(
      """
      INSERT INTO user_identities (id, provider, uid, user_id, inserted_at, updated_at)
      VALUES (gen_random_uuid(), 'wechat', $1, $2, NOW(), NOW())
      """,
      [uid, Ecto.UUID.dump!(user_id)]
    )
  end
end
