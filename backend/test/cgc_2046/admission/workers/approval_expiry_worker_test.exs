defmodule Cgc2046.Admission.Workers.ApprovalExpiryWorkerTest do
  @moduledoc """
  0C 审批超时扫描 worker 测试。

  覆盖两类既有审批实体（Enrollment 尚未建模，Phase 2 接入后复用同一 worker）：
  - JoinRequest（accounts）：approval_deadline 过点的 pending 申请 → 既有 `:expire` action
  - WorkflowRun（workflows）：F7 方案 A 审批超时（definition.approval_timeout）过点的
    waiting run → 既有 `:expire` action（含 checkpoint 清理）

  「POC-2 G1 补测」describe 补测 POC 报告遗留缺口（报告已归档，git 历史可溯）：

  > 报名截止 deadline 的 Schedule Directive 唤醒 → cancel 路径（G1 方案第 4 条建议项）
  > 未验证，建议 v1 用"恢复时检查 deadline → 超时则 Emit cancel"实现并补集成测试

  （另见 POC 报告 §8 G1 方案建议 4（已归档）：「deadline 触发：验证 Schedule Directive 或"恢复时检查
  deadline → 超时则 Emit cancel"路径（覆盖开放问题 5）」。开放问题 5：「hibernate 期间
  deadline 到点如何唤醒并 cancel 未验证」。）

  v1 落地形态：唤醒由 Oban cron 周期扫描承担（替代 Schedule Directive），cancel 走
  WorkflowRun 既有 `:expire` 领域 action（不发明第二条状态转换路径，D-A6）。
  """

  use Cgc2046Web.ConnCase, async: true
  use Oban.Testing, repo: Cgc2046.Repo

  alias Cgc2046.Accounts.JoinRequest
  alias Cgc2046.Accounts.WorkspaceApplication
  alias Cgc2046.AccountsFixtures, as: Fixtures
  alias Cgc2046.Admission.Workers.ApprovalExpiryWorker
  alias Cgc2046.Workflows.JidoAdapter
  alias Cgc2046.Workflows.StepHandlerRegistry
  alias Cgc2046.Workflows.TestActions
  alias Cgc2046.Workflows.WorkflowDefinition
  alias Cgc2046.Workflows.WorkflowRun

  setup do
    StepHandlerRegistry.register(TestActions.Uppercase)
    StepHandlerRegistry.register(TestActions.AppendExclamation)
    :ok
  end

  defp create_join_request(workspace, user) do
    assert {:ok, join_request} =
             JoinRequest
             |> Ash.Changeset.for_create(:create, %{
               workspace_id: workspace.id,
               user_id: user.id
             })
             |> Ash.create(actor: user)

    join_request
  end

  defp create_workspace_application(user) do
    assert {:ok, application} =
             WorkspaceApplication
             |> Ash.Changeset.for_create(:create, %{
               applicant_id: user.id,
               name: "Expiry App WS",
               slug: "expiry-wapp-#{System.unique_integer([:positive])}",
               purpose: "过期扫描测试"
             })
             |> Ash.create(actor: user)

    application
  end

  # interval 为测试内硬编码字面量（同 backdate_join_request_deadline 惯例），
  # Postgrex 无法把字符串参数编码为 interval，故内联进 SQL
  defp backdate_workspace_application_deadline(application, interval) do
    {:ok, _} =
      Ecto.Adapters.SQL.query(
        Cgc2046.Repo,
        "UPDATE workspace_applications SET approval_deadline = NOW() - INTERVAL '#{interval}' WHERE id = $1",
        [Ecto.UUID.dump!(application.id)]
      )
  end

  # interval 为测试内硬编码字面量（同 join_request_test.exs 既有惯例），Postgrex
  # 无法把字符串参数编码为 interval，故内联进 SQL
  defp backdate_join_request_deadline(join_request, interval) do
    {:ok, _} =
      Ecto.Adapters.SQL.query(
        Cgc2046.Repo,
        "UPDATE join_requests SET approval_deadline = NOW() - INTERVAL '#{interval}' WHERE id = $1",
        [Ecto.UUID.dump!(join_request.id)]
      )
  end

  # 自动步骤 + 人工步骤门控：uppercase → (manual approval) → append_exclamation
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

  defp create_published_definition(workspace, admin, approval_timeout) do
    assert {:ok, defn} =
             WorkflowDefinition
             |> Ash.Changeset.for_create(
               :create,
               %{
                 name: "审批 workflow",
                 type: :curriculum,
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

    published
  end

  # 建 run 并 start_run 推进到 waiting（hibernate，checkpoint 落 Postgres）
  defp create_waiting_run(workspace, admin, published) do
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

  defp backdate_run_updated_at(run, interval) do
    {:ok, _} =
      Ecto.Adapters.SQL.query(
        Cgc2046.Repo,
        "UPDATE workflow_runs SET updated_at = NOW() - INTERVAL '#{interval}' WHERE id = $1",
        [Ecto.UUID.dump!(run.id)]
      )
  end

  describe "JoinRequest 过期扫描" do
    test "approval_deadline 过点的 pending 申请转 expired（既有 :expire action，落 expired_at）" do
      admin = Fixtures.platform_admin("expiry-admin")
      workspace = Fixtures.create_workspace(admin)
      applicant = Fixtures.register_user("expiry-jr-#{System.unique_integer([:positive])}")
      jr = create_join_request(workspace, applicant)
      backdate_join_request_deadline(jr, "1 day")

      assert :ok = perform_job(ApprovalExpiryWorker, %{})

      reloaded = Ash.get!(JoinRequest, jr.id, authorize?: false)
      assert reloaded.status == :expired
      refute is_nil(reloaded.expired_at)
    end

    test "未到期的 pending 申请不动" do
      admin = Fixtures.platform_admin("expiry-admin")
      workspace = Fixtures.create_workspace(admin)
      applicant = Fixtures.register_user("expiry-jr-#{System.unique_integer([:positive])}")
      jr = create_join_request(workspace, applicant)

      assert :ok = perform_job(ApprovalExpiryWorker, %{})

      reloaded = Ash.get!(JoinRequest, jr.id, authorize?: false)
      assert reloaded.status == :pending
      assert is_nil(reloaded.expired_at)
    end

    test "已终态申请即使 deadline 过点也不动（status 过滤语义）" do
      admin = Fixtures.platform_admin("expiry-admin")
      workspace = Fixtures.create_workspace(admin)
      applicant = Fixtures.register_user("expiry-jr-#{System.unique_integer([:positive])}")
      jr = create_join_request(workspace, applicant)

      assert {:ok, rejected} =
               jr
               |> Ash.Changeset.for_update(:reject, %{}, actor: admin)
               |> Ash.update(tenant: workspace.id, actor: admin)

      backdate_join_request_deadline(rejected, "1 day")

      assert :ok = perform_job(ApprovalExpiryWorker, %{})

      reloaded = Ash.get!(JoinRequest, jr.id, authorize?: false)
      assert reloaded.status == :rejected
      assert is_nil(reloaded.expired_at)
    end

    test "重复执行幂等：第二拍无新转换、不报错" do
      admin = Fixtures.platform_admin("expiry-admin")
      workspace = Fixtures.create_workspace(admin)
      applicant = Fixtures.register_user("expiry-jr-#{System.unique_integer([:positive])}")
      jr = create_join_request(workspace, applicant)
      backdate_join_request_deadline(jr, "1 day")

      assert :ok = perform_job(ApprovalExpiryWorker, %{})
      assert :ok = perform_job(ApprovalExpiryWorker, %{})

      reloaded = Ash.get!(JoinRequest, jr.id, authorize?: false)
      assert reloaded.status == :expired
    end
  end

  describe "WorkflowRun 过期扫描（F7 审批超时）" do
    test "waiting 且 approval_timeout 过点 → 走 :expire 转 expired" do
      admin = Fixtures.platform_admin("expiry-admin")
      workspace = Fixtures.create_workspace(admin)
      published = create_published_definition(workspace, admin, 3_600)
      waiting = create_waiting_run(workspace, admin, published)
      backdate_run_updated_at(waiting, "2 hours")

      assert :ok = perform_job(ApprovalExpiryWorker, %{})

      reloaded = Ash.get!(WorkflowRun, waiting.id, authorize?: false)
      assert reloaded.status == :expired
      refute is_nil(reloaded.finished_at)
    end

    test "waiting 但未过点 → 不动" do
      admin = Fixtures.platform_admin("expiry-admin")
      workspace = Fixtures.create_workspace(admin)
      published = create_published_definition(workspace, admin, 604_800)
      waiting = create_waiting_run(workspace, admin, published)

      assert :ok = perform_job(ApprovalExpiryWorker, %{})

      reloaded = Ash.get!(WorkflowRun, waiting.id, authorize?: false)
      assert reloaded.status == :waiting
    end

    test "approval_timeout = nil（无超时，F7 方案 A）→ 不动" do
      admin = Fixtures.platform_admin("expiry-admin")
      workspace = Fixtures.create_workspace(admin)
      published = create_published_definition(workspace, admin, nil)
      waiting = create_waiting_run(workspace, admin, published)
      backdate_run_updated_at(waiting, "30 days")

      assert :ok = perform_job(ApprovalExpiryWorker, %{})

      reloaded = Ash.get!(WorkflowRun, waiting.id, authorize?: false)
      assert reloaded.status == :waiting
    end

    test "pending（未进入审批等待）→ 不动" do
      admin = Fixtures.platform_admin("expiry-admin")
      workspace = Fixtures.create_workspace(admin)
      published = create_published_definition(workspace, admin, 3_600)

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

      backdate_run_updated_at(run, "2 hours")

      assert :ok = perform_job(ApprovalExpiryWorker, %{})

      reloaded = Ash.get!(WorkflowRun, run.id, authorize?: false)
      assert reloaded.status == :pending
    end
  end

  describe "WorkspaceApplication 过期扫描" do
    test "approval_deadline 过点的 pending 申请转 expired（既有 :expire action，落 expired_at）" do
      applicant = Fixtures.register_user("expiry-wapp-#{System.unique_integer([:positive])}")
      application = create_workspace_application(applicant)
      backdate_workspace_application_deadline(application, "1 day")

      assert :ok = perform_job(ApprovalExpiryWorker, %{})

      reloaded = Ash.get!(WorkspaceApplication, application.id, authorize?: false)
      assert reloaded.status == :expired
      refute is_nil(reloaded.expired_at)
    end

    test "未到期的 pending 申请不动" do
      applicant = Fixtures.register_user("expiry-wapp-#{System.unique_integer([:positive])}")
      application = create_workspace_application(applicant)

      assert :ok = perform_job(ApprovalExpiryWorker, %{})

      reloaded = Ash.get!(WorkspaceApplication, application.id, authorize?: false)
      assert reloaded.status == :pending
      assert is_nil(reloaded.expired_at)
    end

    test "已终态申请即使 deadline 过点也不动（status 过滤语义）" do
      admin = Fixtures.platform_admin("expiry-admin")
      applicant = Fixtures.register_user("expiry-wapp-#{System.unique_integer([:positive])}")
      application = create_workspace_application(applicant)

      assert {:ok, rejected} =
               application
               |> Ash.Changeset.for_update(:reject, %{}, actor: admin)
               |> Ash.update(actor: admin)

      backdate_workspace_application_deadline(rejected, "1 day")

      assert :ok = perform_job(ApprovalExpiryWorker, %{})

      reloaded = Ash.get!(WorkspaceApplication, application.id, authorize?: false)
      assert reloaded.status == :rejected
      assert is_nil(reloaded.expired_at)
    end

    test "重复执行幂等：第二拍无新转换、不报错" do
      applicant = Fixtures.register_user("expiry-wapp-#{System.unique_integer([:positive])}")
      application = create_workspace_application(applicant)
      backdate_workspace_application_deadline(application, "1 day")

      assert :ok = perform_job(ApprovalExpiryWorker, %{})
      assert :ok = perform_job(ApprovalExpiryWorker, %{})

      reloaded = Ash.get!(WorkspaceApplication, application.id, authorize?: false)
      assert reloaded.status == :expired
    end
  end

  # 补测 POC-2 G1 缺口（原文见模块 moduledoc）：hibernate 期间 deadline 到点 →
  # 唤醒 → cancel 的完整链路。唤醒 = Oban worker 扫描；cancel = WorkflowRun :expire。
  describe "POC-2 G1 补测：hibernate→thaw→cancel 链路" do
    test "waiting hibernate（checkpoint 可 thaw 恢复）→ deadline 过点 → worker 唤醒转 expired → checkpoint 清理 → 信号放行被拒" do
      admin = Fixtures.platform_admin("expiry-admin")
      workspace = Fixtures.create_workspace(admin)
      published = create_published_definition(workspace, admin, 3_600)
      waiting = create_waiting_run(workspace, admin, published)

      # hibernate 实证：checkpoint 已持久化，thaw 可恢复 workflow（G1 A2 语义：
      # status=waiting、上游 facts 保留）
      assert {:ok, restored} = JidoAdapter.thaw(waiting.id, waiting.partition_id)
      assert JidoAdapter.run_status(restored) == :waiting
      assert JidoAdapter.list_run_facts(restored)["uppercase"] == %{text: "HI"}

      # hibernate 期间 deadline 到点（审批超时 1h，waiting 已挂起 2h）
      backdate_run_updated_at(waiting, "2 hours")

      # 唤醒路径：Oban worker 扫描到过点 waiting run → 走既有 :expire 领域 action
      # （D-A6：不发明第二条状态转换路径）
      assert :ok = perform_job(ApprovalExpiryWorker, %{})

      expired = Ash.get!(WorkflowRun, waiting.id, authorize?: false)
      assert expired.status == :expired
      refute is_nil(expired.finished_at)

      # 终态 checkpoint 清理（#16 语义）：thaw 不再可恢复
      assert {:error, _} = JidoAdapter.thaw(waiting.id, waiting.partition_id)

      # 迟到的审批信号被拒（终态不可 resume_signal）
      assert {:error, %Ash.Error.Invalid{}} =
               expired
               |> Ash.Changeset.for_update(
                 :resume_signal,
                 %{signal_type: "workflow.approval", payload: %{approved_by: "u1"}},
                 actor: admin
               )
               |> Ash.update(tenant: workspace.id, actor: admin)
    end

    test "deadline 未过点的 hibernated run 不被唤醒 cancel（thaw 后仍可正常放行）" do
      admin = Fixtures.platform_admin("expiry-admin")
      workspace = Fixtures.create_workspace(admin)
      published = create_published_definition(workspace, admin, 604_800)
      waiting = create_waiting_run(workspace, admin, published)

      assert :ok = perform_job(ApprovalExpiryWorker, %{})

      # 未过点：run 仍 waiting，checkpoint 仍在，thaw 恢复后信号放行链路完好
      # （带 tenant 重读：resume_signal 的 StepAuthorization 需从 changeset.tenant 取工作台）
      reloaded = Ash.get!(WorkflowRun, waiting.id, tenant: workspace.id, authorize?: false)
      assert reloaded.status == :waiting

      assert {:ok, restored} = JidoAdapter.thaw(waiting.id, waiting.partition_id)
      assert JidoAdapter.run_status(restored) == :waiting

      assert {:ok, succeeded} =
               reloaded
               |> Ash.Changeset.for_update(
                 :resume_signal,
                 %{signal_type: "workflow.approval", payload: %{approved_by: "u1"}},
                 actor: admin
               )
               |> Ash.update(tenant: workspace.id, actor: admin)

      assert succeeded.status == :succeeded
    end
  end

  describe "invitation expiry sweep (#114)" do
    test "active invitation with past expires_at -> swept to expired in DB" do
      admin = Fixtures.platform_admin("expiry-admin")
      workspace = Fixtures.create_workspace(admin)

      {:ok, invitation} =
        Cgc2046.Accounts.Invitation
        |> Ash.Changeset.for_create(:create, %{
          workspace_id: workspace.id,
          inviter_id: admin.id,
          target_email: "sweep-past@example.com",
          expires_at: DateTime.add(DateTime.utc_now(), -3600, :second)
        })
        |> Ash.create(actor: admin)

      assert :ok = perform_job(ApprovalExpiryWorker, %{})

      reloaded = Ash.get!(Cgc2046.Accounts.Invitation, invitation.id, authorize?: false)
      assert reloaded.status == :expired
    end

    test "future expires_at / terminal status invitations are untouched" do
      admin = Fixtures.platform_admin("expiry-admin")
      workspace = Fixtures.create_workspace(admin)

      {:ok, future} =
        Cgc2046.Accounts.Invitation
        |> Ash.Changeset.for_create(:create, %{
          workspace_id: workspace.id,
          inviter_id: admin.id,
          target_email: "sweep-future@example.com",
          expires_at: DateTime.add(DateTime.utc_now(), 3600, :second)
        })
        |> Ash.create(actor: admin)

      {:ok, revoked} =
        Cgc2046.Accounts.Invitation
        |> Ash.Changeset.for_create(:create, %{
          workspace_id: workspace.id,
          inviter_id: admin.id,
          target_email: "sweep-revoked@example.com",
          expires_at: DateTime.add(DateTime.utc_now(), -3600, :second)
        })
        |> Ash.create(actor: admin)

      assert {:ok, revoked} =
               revoked
               |> Ash.Changeset.for_update(:revoke, %{})
               |> Ash.update(actor: admin)

      assert :ok = perform_job(ApprovalExpiryWorker, %{})

      assert Ash.get!(Cgc2046.Accounts.Invitation, future.id, authorize?: false).status ==
               :active

      assert Ash.get!(Cgc2046.Accounts.Invitation, revoked.id, authorize?: false).status ==
               :revoked
    end
  end
end
