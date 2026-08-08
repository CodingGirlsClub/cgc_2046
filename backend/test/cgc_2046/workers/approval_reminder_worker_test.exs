defmodule Cgc2046.Workers.ApprovalReminderWorkerTest do
  @moduledoc """
  0C 48h 审批提醒 job 骨架测试。

  F7 方案 A「deadline 前 48h 提醒审批人」的 v1 骨架：扫描 waiting 且 deadline 落在
  未来 48h 窗口内的 WorkflowRun，每 run 落一条 SignalLog（signal_type=
  "workflow.approval_reminder"）；不接真实通知投递（Phase 2 NotificationService 接线）。
  """

  use Cgc2046Web.ConnCase, async: false
  use Oban.Testing, repo: Cgc2046.Repo

  alias Cgc2046.Accounts.User
  alias Cgc2046.Accounts.Workspace
  alias Cgc2046.Workers.ApprovalExpiryWorker
  alias Cgc2046.Workers.ApprovalReminderWorker
  alias Cgc2046.Workflows.SignalLog
  alias Cgc2046.Workflows.StepHandlerRegistry
  alias Cgc2046.Workflows.TestActions
  alias Cgc2046.Workflows.WorkflowDefinition
  alias Cgc2046.Workflows.WorkflowRun
  alias AshAuthentication.Info, as: AuthInfo

  require Ash.Query

  setup do
    StepHandlerRegistry.register(TestActions.Uppercase)
    StepHandlerRegistry.register(TestActions.AppendExclamation)
    :ok
  end

  @password "sup3r-secret-password"

  defp register_user(email) do
    strategy = AuthInfo.strategy!(User, :password)

    assert {:ok, user} =
             AshAuthentication.Strategy.action(strategy, :register, %{
               email: email,
               password: @password
             })

    user
  end

  defp platform_admin do
    user = register_user("reminder-admin-#{System.unique_integer([:positive])}@example.com")

    {:ok, _} =
      Ecto.Adapters.SQL.query(
        Cgc2046.Repo,
        "UPDATE users SET is_platform_admin = true WHERE id = $1",
        [Ecto.UUID.dump!(user.id)]
      )

    Ash.get!(User, user.id, actor: user, authorize?: false, domain: Cgc2046.GlobalApi)
  end

  defp create_workspace(admin) do
    slug = "reminder-ws-#{System.unique_integer([:positive])}"

    assert {:ok, workspace} =
             Workspace
             |> Ash.Changeset.for_create(:create, %{slug: slug, name: "Reminder WS"})
             |> Ash.create(actor: admin)

    workspace
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

  defp reminder_logs_for(run) do
    SignalLog
    |> Ash.Query.filter(run_id == ^run.id and signal_type == "workflow.approval_reminder")
    |> Ash.read!(authorize?: false)
  end

  describe "48h 提醒窗口" do
    test "waiting 且 deadline 在未来 48h 内 → 落 SignalLog 提醒" do
      admin = platform_admin()
      workspace = create_workspace(admin)
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

    test "deadline 超 48h → 不落" do
      admin = platform_admin()
      workspace = create_workspace(admin)
      # 审批超时 72h：deadline ≈ now+72h，超出 48h 窗口
      waiting = create_waiting_run(workspace, admin, 259_200)

      assert :ok = perform_job(ApprovalReminderWorker, %{})

      assert reminder_logs_for(waiting) == []
    end

    test "approval_timeout = nil（无超时）→ 不落" do
      admin = platform_admin()
      workspace = create_workspace(admin)
      waiting = create_waiting_run(workspace, admin, nil)

      assert :ok = perform_job(ApprovalReminderWorker, %{})

      assert reminder_logs_for(waiting) == []
    end

    test "幂等：同 run 重复执行只落一条（Oban 唯一任务之外的落库查重兜底）" do
      admin = platform_admin()
      workspace = create_workspace(admin)
      waiting = create_waiting_run(workspace, admin, 86_400)

      assert :ok = perform_job(ApprovalReminderWorker, %{})
      assert :ok = perform_job(ApprovalReminderWorker, %{})

      assert [_one] = reminder_logs_for(waiting)
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
end
