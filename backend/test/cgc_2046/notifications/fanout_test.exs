defmodule Cgc2046.Notifications.FanoutTest do
  use Cgc2046.DataCase, async: false
  use Oban.Testing, repo: Cgc2046.Repo

  require Ash.Query

  alias Cgc2046.AccountsFixtures, as: Fixtures
  alias Cgc2046.Notifications.Fanout
  alias Cgc2046.Notifications.NotificationDelivery
  alias Cgc2046.Notifications.NotificationWorker

  @telemetry_event [:cgc2046, :notification_fanout, :deliver]

  describe "managers/2 选择器语义" do
    test ":manage 默认命中 owner/admin（Role.manage_roles/0 唯一真源），member 排除" do
      %{owner: owner, admin: admin, member: member, workspace: workspace} = workspace_with_roles()

      insert_identity(owner.id, :wechat, "fanout-manage-owner-openid")
      insert_identity(admin.id, :tt, "fanout-manage-admin-openid")
      insert_identity(member.id, :xhs, "fanout-manage-member-openid")

      assert %{} = recipients = Fanout.managers(workspace.id)

      assert Map.keys(recipients) |> Enum.sort() == Enum.sort([owner.id, admin.id])
      assert [%{provider: :wechat, uid: "fanout-manage-owner-openid"}] = recipients[owner.id]
      assert [%{provider: :tt, uid: "fanout-manage-admin-openid"}] = recipients[admin.id]
      refute Map.has_key?(recipients, member.id)
    end

    test "{:roles, [:owner]} 显式窄集仅命中 owner（拍板 #4 赞助 Workspace 级语义）" do
      %{owner: owner, admin: admin, workspace: workspace} = workspace_with_roles()

      insert_identity(owner.id, :wechat, "fanout-narrow-owner-openid")
      insert_identity(admin.id, :tt, "fanout-narrow-admin-openid")

      assert %{} = recipients = Fanout.managers(workspace.id, {:roles, [:owner]})

      assert Map.keys(recipients) == [owner.id]
      refute Map.has_key?(recipients, admin.id)
    end

    test "无管理角色成员 → 空 map" do
      owner = Fixtures.platform_admin("fanout-empty")
      workspace = Fixtures.create_workspace(owner)

      member =
        Fixtures.register_user("fanout-empty-member-#{System.unique_integer([:positive])}")

      Fixtures.add_member(workspace, member)
      insert_identity(member.id, :wechat, "fanout-empty-member-openid")

      assert Fanout.managers(workspace.id) == %{}
    end

    test "管理成员无平台身份 → 空 map（调用方不区分「无人」与「有人无身份」）" do
      owner = Fixtures.platform_admin("fanout-no-identity")
      workspace = Fixtures.create_workspace(owner)

      assert Fanout.managers(workspace.id) == %{}
    end

    test "同用户多平台身份按 user_id 分组为一个列表（分组形状）" do
      owner = Fixtures.platform_admin("fanout-group")
      workspace = Fixtures.create_workspace(owner)

      insert_identity(owner.id, :wechat, "fanout-group-wx")
      insert_identity(owner.id, :tt, "fanout-group-tt")

      owner_id = owner.id
      assert %{^owner_id => identities} = Fanout.managers(workspace.id)

      assert identities |> Enum.map(& &1.uid) |> Enum.sort() ==
               ["fanout-group-tt", "fanout-group-wx"]
    end
  end

  describe "identities/1" do
    test "单用户全部平台身份" do
      user = Fixtures.register_user("fanout-identities")
      insert_identity(user.id, :wechat, "fanout-identities-wx")
      insert_identity(user.id, :tt, "fanout-identities-tt")

      assert [i1, i2] = Fanout.identities(user.id)

      assert [i1, i2] |> Enum.map(& &1.uid) |> Enum.sort() ==
               ["fanout-identities-tt", "fanout-identities-wx"]

      assert Enum.all?([i1, i2], &(&1.user_id == user.id))
    end

    test "无平台身份 → []" do
      user = Fixtures.register_user("fanout-no-identities")
      assert Fanout.identities(user.id) == []
    end
  end

  describe "identities_for_users/1" do
    test "批量解析多用户平台身份且忽略无身份用户" do
      first = Fixtures.register_user("fanout-batch-first")
      second = Fixtures.register_user("fanout-batch-second")
      without_identity = Fixtures.register_user("fanout-batch-empty")
      insert_identity(first.id, :wechat, "fanout-batch-first-wx")
      insert_identity(first.id, :tt, "fanout-batch-first-tt")
      insert_identity(second.id, :wechat, "fanout-batch-second-wx")

      identities =
        Fanout.identities_for_users([first.id, second.id, without_identity.id])

      first_identities = Map.fetch!(identities, first.id)
      second_identities = Map.fetch!(identities, second.id)
      assert map_size(identities) == 2

      assert Enum.map(first_identities, & &1.uid) |> Enum.sort() ==
               ["fanout-batch-first-tt", "fanout-batch-first-wx"]

      assert Enum.map(second_identities, & &1.uid) == ["fanout-batch-second-wx"]
    end
  end

  describe "deliver/5" do
    test "map 与 {user_id, [identity]} 两种 recipients 形状归一，逐身份落行（#847 耐久路径）" do
      user = Fixtures.register_user("fanout-deliver-shape")
      insert_identity(user.id, :wechat, "fanout-deliver-shape-wx")
      insert_identity(user.id, :tt, "fanout-deliver-shape-tt")
      identities = Fanout.identities(user.id)

      assert :ok =
               Fanout.deliver(
                 {user.id, identities},
                 "approval_result",
                 %{"status" => "confirmed", "enrollment_id" => "e1"},
                 %{"enrollment_id" => "e1"}
               )

      assert length(deliveries_for(user.id)) == 2

      assert :ok =
               Fanout.deliver(
                 %{user.id => identities},
                 "approval_result",
                 %{"status" => "confirmed", "enrollment_id" => "e2"},
                 %{"enrollment_id" => "e2"}
               )

      rows = deliveries_for(user.id)
      assert length(rows) == 4

      assert rows |> Enum.map(& &1.data["enrollment_id"]) |> Enum.sort() ==
               ["e1", "e1", "e2", "e2"]
    end

    test "args 形状：job_meta 与 identity_uid/platform/template_key/data 合并" do
      user = Fixtures.register_user("fanout-deliver-args")
      insert_identity(user.id, :wechat, "fanout-deliver-args-openid")
      enrollment_id = Ecto.UUID.generate()

      # 过渡期钉未迁键的直插 args 合并（收尾批次随直插路径删除）
      assert :ok =
               Fanout.deliver(
                 {user.id, Fanout.identities(user.id)},
                 "event_moderator_removed",
                 %{"event_id" => enrollment_id},
                 %{"event_id" => enrollment_id}
               )

      assert [%{args: args}] = all_enqueued(worker: NotificationWorker)

      assert args["user_id"] == user.id
      assert args["identity_uid"] == "fanout-deliver-args-openid"
      assert args["platform"] == "wechat"
      assert args["template_key"] == "event_moderator_removed"
      assert args["event_id"] == enrollment_id
      assert args["data"] == %{"event_id" => enrollment_id}
    end

    # 过渡期钉未迁键的 #406 语义；已迁键零身份改落哨兵行（见批 1 钉测 describe）。
    # 收尾批次删除直插路径后本测试随之删除。
    test "空 recipients（无身份）未迁键 → 不入队，warning 日志 + telemetry status :skipped（#406）" do
      attach_telemetry()
      user = Fixtures.register_user("fanout-deliver-empty")

      log =
        ExUnit.CaptureLog.capture_log(fn ->
          assert :ok =
                   Fanout.deliver(
                     {user.id, []},
                     "event_moderator_assigned",
                     %{},
                     %{"event_id" => "ev-empty"}
                   )

          assert :ok = Fanout.deliver(%{}, "event_moderator_assigned", %{}, %{})
        end)

      assert all_enqueued(worker: NotificationWorker) == []

      assert log =~ "notification deliver skipped: no identities"
      assert log =~ "template_key=event_moderator_assigned"
      assert log =~ inspect([user.id])

      assert_receive {:fanout_telemetry, _, %{count: 0},
                      %{status: :skipped, template_key: "event_moderator_assigned", error: nil}}
    end

    test "成功入队发 telemetry count = 入队条数" do
      attach_telemetry()
      user = Fixtures.register_user("fanout-telemetry")
      insert_identity(user.id, :wechat, "fanout-telemetry-wx")
      insert_identity(user.id, :tt, "fanout-telemetry-tt")

      assert :ok =
               Fanout.deliver(
                 {user.id, Fanout.identities(user.id)},
                 "approval_result",
                 %{},
                 %{}
               )

      assert_receive {:fanout_telemetry, _, %{count: 2},
                      %{status: :ok, template_key: "approval_result", error: nil}}
    end

    test "入队异常 rescue 内化：Logger + status :error telemetry，返回 :ok" do
      attach_telemetry()

      log =
        ExUnit.CaptureLog.capture_log(fn ->
          # 非法 recipients 形状 → normalize 函数子句错误被 rescue 捕获
          assert :ok = Fanout.deliver(:bogus, "approval_result", %{}, %{})
        end)

      assert log =~ "notification deliver failed (approval_result)"

      assert_receive {:fanout_telemetry, _, %{count: 0},
                      %{status: :error, template_key: "approval_result", error: error}}

      assert is_binary(error)
    end

    # 过渡期钉未迁键的 Oban unique 语义（#7）；两键迁走或收尾删除直插路径后本测试随之移除。
    test "unique 预设：:default 含 discarded 阻塞重拍；:reminder_7d 释放 discarded 名额（#7）" do
      user = Fixtures.register_user("fanout-unique")
      insert_identity(user.id, :wechat, "fanout-unique-openid")
      identities = Fanout.identities(user.id)
      data = %{"event_id" => Ecto.UUID.generate()}
      meta = %{"event_id" => data["event_id"]}

      # :default（payment_succeeded，未迁）—— 同 args 重入队折叠为既有 job
      assert :ok = Fanout.deliver({user.id, identities}, "event_moderator_assigned", data, meta)

      assert [job] =
               all_enqueued(
                 worker: NotificationWorker,
                 args: %{"template_key" => "event_moderator_assigned"}
               )

      assert :ok = Fanout.deliver({user.id, identities}, "event_moderator_assigned", data, meta)

      assert [same] =
               all_enqueued(
                 worker: NotificationWorker,
                 args: %{"template_key" => "event_moderator_assigned"}
               )

      assert same.id == job.id

      # :default（NotificationWorker states: :all）—— discarded 仍阻塞，不插新行
      {:ok, _} =
        Ecto.Adapters.SQL.query(
          Cgc2046.Repo,
          "UPDATE oban_jobs SET state = 'discarded' WHERE id = $1",
          [job.id]
        )

      assert :ok = Fanout.deliver({user.id, identities}, "event_moderator_assigned", data, meta)
      assert count_rows("event_moderator_assigned", user.id) == 1

      # #847 批 3：approval_reminder 迁耐久路径后 @reminder_unique 无 Fanout 使用方，
      # :reminder_7d 段随迁删除（收尾批次本测试整体移除）
    end
  end

  describe "deliver_with_receipt/5" do
    test "返回实际接受入队的通知任务数（#847 已迁键 count = 身份数，行为面落 Delivery 行）" do
      user = Fixtures.register_user("fanout-receipt")
      insert_identity(user.id, :wechat, "fanout-receipt-wx")
      insert_identity(user.id, :tt, "fanout-receipt-tt")

      assert {:ok, 2} =
               Fanout.deliver_with_receipt(
                 {user.id, Fanout.identities(user.id)},
                 "approval_result",
                 %{"status" => "confirmed", "enrollment_id" => "e-receipt"},
                 %{"enrollment_id" => "e-receipt"}
               )

      assert length(deliveries_for(user.id)) == 2
    end

    test "零身份（未迁键）明确返回零入队，不伪称已接受任务" do
      user = Fixtures.register_user("fanout-receipt-empty")

      assert {:ok, 0} =
               Fanout.deliver_with_receipt(
                 {user.id, []},
                 "event_moderator_assigned",
                 %{},
                 %{"event_id" => "ev-zero"}
               )

      assert all_enqueued(worker: NotificationWorker) == []
    end

    test "异常入队返回失败凭证" do
      assert {:error, :enqueue_failed} =
               Fanout.deliver_with_receipt(:invalid_recipients, "approval_result", %{}, %{})
    end
  end

  describe "#847 PR-B 批 1（报名/审批类迁耐久投递）" do
    defp deliveries_for(user_id) do
      NotificationDelivery
      |> Ash.Query.filter(user_id == ^user_id)
      |> Ash.read!(authorize?: false)
    end

    test "enrollment_submitted：同信号幂等键重复触发只发一次（一行一 job），跨报名正常重发" do
      user = Fixtures.register_user("prb1-submitted")
      insert_identity(user.id, :wechat, "prb1-submitted-wx")
      identities = Fanout.identities(user.id)
      meta = %{"enrollment_id" => "e1", "idempotency_key" => "enrollment.submitted:e1"}

      assert :ok = Fanout.deliver({user.id, identities}, "enrollment_submitted", %{}, meta)
      assert :ok = Fanout.deliver({user.id, identities}, "enrollment_submitted", %{}, meta)

      assert length(deliveries_for(user.id)) == 1
      assert length(all_enqueued(worker: Cgc2046.Notifications.Workers.DeliveryWorker)) == 1

      other = %{"enrollment_id" => "e2", "idempotency_key" => "enrollment.submitted:e2"}

      assert :ok = Fanout.deliver({user.id, identities}, "enrollment_submitted", %{}, other)

      assert length(deliveries_for(user.id)) == 2
    end

    test "enrollment_completed 与 check_in_code 共用信号键：P2 前缀防撞，两行各达" do
      user = Fixtures.register_user("prb1-completed")
      insert_identity(user.id, :wechat, "prb1-completed-wx")
      identities = Fanout.identities(user.id)
      meta = %{"enrollment_id" => "e1", "idempotency_key" => "enrollment.completed:e1"}

      assert :ok =
               Fanout.deliver(
                 {user.id, identities},
                 "enrollment_completed",
                 %{"enrollment_id" => "e1"},
                 meta
               )

      assert :ok =
               Fanout.deliver(
                 {user.id, identities},
                 "enrollment_check_in_code",
                 %{"enrollment_id" => "e1", "check_in_code" => "c1"},
                 meta
               )

      rows = deliveries_for(user.id)
      assert length(rows) == 2

      assert rows |> Enum.map(& &1.template_key) |> Enum.sort() == [
               "enrollment_check_in_code",
               "enrollment_completed"
             ]
    end

    test "approval_result：同报名同结论去重；重审换结论重发（status 入事件键）" do
      user = Fixtures.register_user("prb1-result")
      insert_identity(user.id, :wechat, "prb1-result-wx")
      identities = Fanout.identities(user.id)

      assert :ok =
               Fanout.deliver(
                 {user.id, identities},
                 "approval_result",
                 %{"status" => "approved", "enrollment_id" => "e1"},
                 %{"enrollment_id" => "e1"}
               )

      assert :ok =
               Fanout.deliver(
                 {user.id, identities},
                 "approval_result",
                 %{"status" => "approved", "enrollment_id" => "e1"},
                 %{"enrollment_id" => "e1"}
               )

      assert length(deliveries_for(user.id)) == 1

      assert :ok =
               Fanout.deliver(
                 {user.id, identities},
                 "approval_result",
                 %{"status" => "rejected", "enrollment_id" => "e1"},
                 %{"enrollment_id" => "e1"}
               )

      assert length(deliveries_for(user.id)) == 2
    end

    test "已迁键零身份 → 哨兵行（不再静默 skip）+ {:ok, 0}" do
      user = Fixtures.register_user("prb1-zero")

      assert {:ok, 0} =
               Fanout.deliver_with_receipt(
                 {user.id, []},
                 "enrollment_submitted",
                 %{},
                 %{"enrollment_id" => "e1", "idempotency_key" => "enrollment.submitted:e1"}
               )

      [row] = deliveries_for(user.id)
      assert is_nil(row.platform)
      assert is_nil(row.identity_uid)
      assert row.status == :pending
    end

    test "未迁键仍走 NotificationWorker 直插（过渡态）" do
      user = Fixtures.register_user("prb1-legacy")
      insert_identity(user.id, :wechat, "prb1-legacy-wx")

      assert :ok =
               Fanout.deliver(
                 {user.id, Fanout.identities(user.id)},
                 "event_moderator_assigned",
                 %{"event_id" => "ev1"},
                 %{"event_id" => "ev1"}
               )

      assert [%{args: args}] = all_enqueued(worker: NotificationWorker)
      assert args["template_key"] == "event_moderator_assigned"
      assert deliveries_for(user.id) == []
    end
  end

  describe "#847 PR-B 批 2（资金类迁耐久投递）" do
    defp deliveries_for_2(user_id) do
      NotificationDelivery
      |> Ash.Query.filter(user_id == ^user_id)
      |> Ash.read!(authorize?: false)
    end

    test "payment_succeeded：同订单重复结算重放只发一次，跨订单正常重发" do
      user = Fixtures.register_user("prb2-paid")
      insert_identity(user.id, :wechat, "prb2-paid-wx")
      identities = Fanout.identities(user.id)
      data = %{"order_id" => "o1", "amount" => "1.00"}

      deliver = fn order_id ->
        Fanout.deliver(
          {user.id, identities},
          "payment_succeeded",
          Map.put(data, "order_id", order_id),
          %{"idempotency_key" => "payment_succeeded:" <> order_id}
        )
      end

      assert :ok = deliver.("o1")
      assert :ok = deliver.("o1")
      assert length(deliveries_for_2(user.id)) == 1

      assert :ok = deliver.("o2")
      assert length(deliveries_for_2(user.id)) == 2
    end

    test "refund_failed 与 refund_succeeded 同订单：P2 前缀防撞，失败→重试→成功两通知各达一次" do
      user = Fixtures.register_user("prb2-refund")
      insert_identity(user.id, :wechat, "prb2-refund-wx")
      identities = Fanout.identities(user.id)
      key = "refund_failed:o1"

      assert :ok =
               Fanout.deliver(
                 {user.id, identities},
                 "refund_failed",
                 %{"order_id" => "o1"},
                 %{"idempotency_key" => key}
               )

      assert :ok =
               Fanout.deliver(
                 {user.id, identities},
                 "refund_succeeded",
                 %{"order_id" => "o1"},
                 %{"idempotency_key" => "refund_succeeded:o1"}
               )

      rows = deliveries_for_2(user.id)
      assert length(rows) == 2

      assert rows |> Enum.map(& &1.template_key) |> Enum.sort() == [
               "refund_failed",
               "refund_succeeded"
             ]
    end
  end

  describe "#847 PR-B 批 3（提醒类迁耐久投递）" do
    defp deliveries_for_3(user_id) do
      NotificationDelivery
      |> Ash.Query.filter(user_id == ^user_id)
      |> Ash.read!(authorize?: false)
    end

    test "approval_reminder（enrollment 面）：重复扫描同键去重（一行一 job），跨报名各达" do
      user = Fixtures.register_user("prb3-arw")
      insert_identity(user.id, :wechat, "prb3-arw-wx")
      identities = Fanout.identities(user.id)

      deliver = fn eid ->
        Fanout.deliver(
          {user.id, identities},
          "approval_reminder",
          %{"enrollment_id" => eid, "approval_deadline" => "2026-10-01T00:00:00Z"},
          %{"enrollment_id" => eid}
        )
      end

      assert :ok = deliver.("en-1")
      assert :ok = deliver.("en-1")
      assert length(deliveries_for_3(user.id)) == 1

      assert :ok = deliver.("en-2")
      assert length(deliveries_for_3(user.id)) == 2
    end

    test "approval_reminder（sponsorship 面）：job_meta 携带 sponsorship_id 时按赞助维度派生" do
      user = Fixtures.register_user("prb3-sponsor")
      insert_identity(user.id, :wechat, "prb3-sponsor-wx")

      assert :ok =
               Fanout.deliver(
                 {user.id, Fanout.identities(user.id)},
                 "approval_reminder",
                 %{"sponsorship_id" => "sp-1", "approval_deadline" => "2026-10-01T00:00:00Z"},
                 %{"sponsorship_id" => "sp-1"}
               )

      [row] = deliveries_for_3(user.id)
      assert row.job_meta["idempotency_key"] == "approval_reminder:approval.reminder:sp-1"
    end

    test "learning_stagnation：同 run 同桶去重，幂等键含周期桶成分（跨桶重发的公式保证）" do
      user = Fixtures.register_user("prb3-lpw")
      insert_identity(user.id, :wechat, "prb3-lpw-wx")
      identities = Fanout.identities(user.id)

      deliver = fn run_id ->
        Fanout.deliver(
          {user.id, identities},
          "learning_stagnation",
          %{"run_id" => run_id, "enrollment_id" => "e1", "title" => "t"},
          %{"run_id" => run_id}
        )
      end

      assert :ok = deliver.("run-1")
      assert :ok = deliver.("run-1")
      assert length(deliveries_for_3(user.id)) == 1

      assert :ok = deliver.("run-2")
      assert length(deliveries_for_3(user.id)) == 2

      [row1, _row2] = deliveries_for_3(user.id) |> Enum.sort_by(& &1.inserted_at)

      assert row1.job_meta["idempotency_key"] =~
               ~r/learning_stagnation:learning\.stagnation:run-\d+:w\d+$/
    end
  end

  defp workspace_with_roles do
    owner = Fixtures.platform_admin("fanout-roles")
    workspace = Fixtures.create_workspace(owner)

    admin =
      Fixtures.register_user("fanout-roles-admin-#{System.unique_integer([:positive])}")

    Fixtures.add_member(workspace, admin, [:admin])

    member =
      Fixtures.register_user("fanout-roles-member-#{System.unique_integer([:positive])}")

    Fixtures.add_member(workspace, member)

    %{owner: owner, admin: admin, member: member, workspace: workspace}
  end

  defp attach_telemetry do
    test_pid = self()
    handler_id = "fanout-test-#{System.unique_integer([:positive])}"

    :ok =
      :telemetry.attach_many(
        handler_id,
        [@telemetry_event],
        fn event, measurements, metadata, _config ->
          send(test_pid, {:fanout_telemetry, event, measurements, metadata})
        end,
        nil
      )

    on_exit(fn -> :telemetry.detach(handler_id) end)
    :ok
  end

  defp insert_identity(user_id, provider, uid) do
    Cgc2046.Repo.query!(
      """
      INSERT INTO user_identities (id, provider, uid, user_id, inserted_at, updated_at)
      VALUES (gen_random_uuid(), $1, $2, $3, NOW(), NOW())
      """,
      [to_string(provider), uid, Ecto.UUID.dump!(user_id)]
    )
  end

  defp count_rows(template_key, user_id) do
    {:ok, %{rows: [[count]]}} =
      Ecto.Adapters.SQL.query(
        Cgc2046.Repo,
        "SELECT COUNT(*) FROM oban_jobs WHERE worker = 'Cgc2046.Notifications.NotificationWorker' AND args->>'template_key' = $1 AND args->>'user_id' = $2",
        [template_key, user_id]
      )

    count
  end
end
