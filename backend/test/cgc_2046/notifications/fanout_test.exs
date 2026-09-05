defmodule Cgc2046.Notifications.FanoutTest do
  use Cgc2046.DataCase, async: false
  use Oban.Testing, repo: Cgc2046.Repo

  alias Cgc2046.AccountsFixtures, as: Fixtures
  alias Cgc2046.Notifications.Fanout
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

  describe "deliver/5" do
    test "map 与 {user_id, [identity]} 两种 recipients 形状归一，逐身份入队" do
      user = Fixtures.register_user("fanout-deliver-shape")
      insert_identity(user.id, :wechat, "fanout-deliver-shape-wx")
      insert_identity(user.id, :tt, "fanout-deliver-shape-tt")
      identities = Fanout.identities(user.id)

      assert :ok =
               Fanout.deliver(
                 {user.id, identities},
                 "approval_result",
                 %{"status" => "confirmed"},
                 %{"enrollment_id" => "e1"}
               )

      assert length(all_enqueued(worker: NotificationWorker)) == 2

      assert :ok =
               Fanout.deliver(
                 %{user.id => identities},
                 "approval_result",
                 %{"status" => "confirmed"},
                 %{"enrollment_id" => "e2"}
               )

      jobs = all_enqueued(worker: NotificationWorker)
      assert length(jobs) == 4

      assert jobs |> Enum.map(& &1.args["enrollment_id"]) |> Enum.sort() ==
               ["e1", "e1", "e2", "e2"]
    end

    test "args 形状：job_meta 与 identity_uid/platform/template_key/data 合并" do
      user = Fixtures.register_user("fanout-deliver-args")
      insert_identity(user.id, :wechat, "fanout-deliver-args-openid")
      enrollment_id = Ecto.UUID.generate()
      deadline = "2026-08-15T00:00:00Z"

      assert :ok =
               Fanout.deliver(
                 {user.id, Fanout.identities(user.id)},
                 "approval_reminder",
                 %{"enrollment_id" => enrollment_id, "approval_deadline" => deadline},
                 %{
                   "enrollment_id" => enrollment_id,
                   "idempotency_key" => "enrollment.submitted:abc"
                 }
               )

      assert [%{args: args}] = all_enqueued(worker: NotificationWorker)

      assert args["user_id"] == user.id
      assert args["identity_uid"] == "fanout-deliver-args-openid"
      assert args["platform"] == "wechat"
      assert args["template_key"] == "approval_reminder"
      assert args["enrollment_id"] == enrollment_id
      assert args["idempotency_key"] == "enrollment.submitted:abc"
      assert args["data"] == %{"enrollment_id" => enrollment_id, "approval_deadline" => deadline}
    end

    test "空 recipients（无身份）→ 不入队，warning 日志 + telemetry status :skipped（#406）" do
      attach_telemetry()
      user = Fixtures.register_user("fanout-deliver-empty")

      log =
        ExUnit.CaptureLog.capture_log(fn ->
          assert :ok =
                   Fanout.deliver(
                     {user.id, []},
                     "approval_result",
                     %{},
                     %{"enrollment_id" => "e-empty"}
                   )

          assert :ok = Fanout.deliver(%{}, "approval_result", %{}, %{})
        end)

      assert all_enqueued(worker: NotificationWorker) == []

      assert log =~ "notification deliver skipped: no identities"
      assert log =~ "template_key=approval_result"
      assert log =~ inspect([user.id])

      assert_receive {:fanout_telemetry, _, %{count: 0},
                      %{status: :skipped, template_key: "approval_result", error: nil}}
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

    test "unique 预设：:default 含 discarded 阻塞重拍；:reminder_7d 释放 discarded 名额（#7）" do
      user = Fixtures.register_user("fanout-unique")
      insert_identity(user.id, :wechat, "fanout-unique-openid")
      identities = Fanout.identities(user.id)
      data = %{"enrollment_id" => Ecto.UUID.generate()}

      # :default —— 同 args 重入队折叠为既有 job
      assert :ok = Fanout.deliver({user.id, identities}, "approval_result", data, %{})

      assert [job] =
               all_enqueued(
                 worker: NotificationWorker,
                 args: %{"template_key" => "approval_result"}
               )

      assert :ok = Fanout.deliver({user.id, identities}, "approval_result", data, %{})

      assert [same] =
               all_enqueued(
                 worker: NotificationWorker,
                 args: %{"template_key" => "approval_result"}
               )

      assert same.id == job.id

      # :default（NotificationWorker states: :all）—— discarded 仍阻塞，不插新行
      {:ok, _} =
        Ecto.Adapters.SQL.query(
          Cgc2046.Repo,
          "UPDATE oban_jobs SET state = 'discarded' WHERE id = $1",
          [job.id]
        )

      assert :ok = Fanout.deliver({user.id, identities}, "approval_result", data, %{})
      assert count_rows("approval_result", user.id) == 1

      # :reminder_7d —— discarded 释放名额，重拍插入新行
      assert :ok =
               Fanout.deliver(
                 {user.id, identities},
                 "approval_reminder",
                 data,
                 %{},
                 :reminder_7d
               )

      assert [reminder_job] =
               all_enqueued(
                 worker: NotificationWorker,
                 args: %{"template_key" => "approval_reminder"}
               )

      {:ok, _} =
        Ecto.Adapters.SQL.query(
          Cgc2046.Repo,
          "UPDATE oban_jobs SET state = 'discarded' WHERE id = $1",
          [reminder_job.id]
        )

      assert :ok =
               Fanout.deliver(
                 {user.id, identities},
                 "approval_reminder",
                 data,
                 %{},
                 :reminder_7d
               )

      assert count_rows("approval_reminder", user.id) == 2
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
