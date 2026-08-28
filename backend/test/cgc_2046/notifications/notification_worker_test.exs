defmodule Cgc2046.Notifications.NotificationWorkerTest do
  @moduledoc """
  通知类型契约 registry 的表驱动契约测试（2026-08-18 架构深化候选 D；plan
  docs/plans/2026-08-18-005-notification-type-registry.md D7）。

  1. config `:miniprogram_templates` 键集 ↔ `@notification_types` 双射；
  2. 表驱动 stale 重查语义（逐条目与收敛前三子句等价）：
     - approval_reminder × enrollment_id：pending+未来 deadline → 投递；
       已过期 → 跳过且 consent 不消耗；非 pending → 跳过；
     - approval_reminder × sponsorship_id：同上三态；
     - learning_stagnation：running → 投递；终态 → 跳过；
     - 非提醒类型（stale = nil）→ 不重查直接投递。

  执行形状参考 approval_reminder_worker_test :359-398（真实 DB +
  perform_job 实际执行 + 授权剩余断言）。
  """

  use Cgc2046.DataCase, async: false
  use Oban.Testing, repo: Cgc2046.Repo

  alias Cgc2046.AccountsFixtures, as: Fixtures
  alias Cgc2046.Admission.Enrollment
  alias Cgc2046.Sponsorship.Sponsorship
  alias Cgc2046.EventsFixtures, as: EventFixtures
  alias Cgc2046.Notifications.Consent
  alias Cgc2046.Notifications.NotificationWorker
  alias Cgc2046.Workflows.WorkflowDefinition
  alias Cgc2046.Workflows.WorkflowRun

  # 投递路径 stub wechat 平台（SDK client + Tesla.Mock；token 由 SDK ETS 管理）。
  # 跳过路径不触达 HTTP（stale 重查拦在 deliver 之前），mock 仅兜底防误发真实请求。
  setup do
    test_pid = self()

    Tesla.Mock.mock(fn
      %{method: :post, url: "https://api.weixin.qq.com/cgi-bin/message/subscribe/send" <> _} = env ->
        send(test_pid, {:notification, :wechat, Jason.decode!(env.body)})
        Tesla.Mock.json(%{"errcode" => 0})
    end)

    Req.Test.stub(Cgc2046.MiniprogramClientStub, fn conn ->
      conn = Plug.Conn.fetch_query_params(conn)

      case {conn.method, conn.host, conn.request_path} do
        other ->
          raise "unexpected notification request: #{inspect(other)}"
      end
    end)
  end

  describe "通知类型 registry 契约" do
    test "config :miniprogram_templates 键集 ↔ @notification_types 双射" do
      config_keys =
        :cgc_2046
        |> Application.get_env(:miniprogram_templates, %{})
        |> Map.values()
        |> Enum.flat_map(&Map.keys/1)
        |> MapSet.new()
        |> MapSet.to_list()
        |> Enum.sort()

      registry_keys =
        NotificationWorker.types()
        |> Enum.map(& &1.template_key)
        |> MapSet.new()
        |> MapSet.to_list()
        |> Enum.sort()

      # 三平台键集一致（config 不变量：同键集 × 3 平台；map 迭代序无关，排序后比较）
      platform_key_sets =
        :cgc_2046
        |> Application.get_env(:miniprogram_templates, %{})
        |> Map.values()
        |> Enum.map(&(&1 |> Map.keys() |> Enum.sort()))

      assert length(Enum.uniq(platform_key_sets)) == 1

      assert config_keys == registry_keys

      # 每个 registry 条目都能经 type/1 查到（type/1 与 types/0 同源）
      for %{template_key: key} <- NotificationWorker.types() do
        assert %{template_key: ^key} = NotificationWorker.type(key)
      end
    end

    test "未知 template_key → type/1 返回 nil" do
      assert NotificationWorker.type("no_such_template") == nil
    end

    test "runtime.exs prod 键集 ↔ config/registry 键集一致（D7 锚定扩展）" do
      # test env 不执行 runtime.exs 的 :prod 块（config_env() == :prod 分支），无法读
      # runtime config 值；静态解析源码提取 *_MP_TEMPLATE_* env 键名做三面锚定，
      # 防 runtime 漏配（#231 learning_stagnation prod 静默失败回归锚）。
      runtime_keys =
        "config/runtime.exs"
        |> Path.expand(Path.join([__DIR__, "..", "..", ".."]))
        |> File.read!()
        |> then(&Regex.scan(~r/System\.get_env\("(?:WECHAT|TT|XHS)_MP_TEMPLATE_([A-Z_]+)"\)/, &1))
        |> Enum.map(fn [_, suffix] -> Macro.underscore(suffix) end)
        |> MapSet.new()
        |> MapSet.to_list()
        |> Enum.sort()

      config_keys =
        :cgc_2046
        |> Application.get_env(:miniprogram_templates, %{})
        |> Map.values()
        |> Enum.flat_map(&Map.keys/1)
        |> MapSet.new()
        |> MapSet.to_list()
        |> Enum.sort()

      registry_keys =
        NotificationWorker.types()
        |> Enum.map(& &1.template_key)
        |> MapSet.new()
        |> MapSet.to_list()
        |> Enum.sort()

      assert runtime_keys == config_keys
      assert runtime_keys == registry_keys
    end
  end

  describe "stale 重查：approval_reminder × enrollment_id（表条目 {Enrollment, :pending, :not_expired}）" do
    test "报名 pending 且 deadline 未来 → 投递" do
      %{owner: owner, enrollment: enrollment} = enrollment_setup()

      assert :ok =
               perform_job(NotificationWorker, reminder_args(owner, enrollment))

      assert_receive {:notification, :wechat, _}
      assert {:ok, 0} = Consent.remaining(owner.id, :wechat, "approval_reminder")
    end

    test "报名已过期 → 跳过且不消耗授权" do
      %{owner: owner, enrollment: enrollment} = enrollment_setup()

      {:ok, _} =
        Ecto.Adapters.SQL.query(
          Cgc2046.Repo,
          "UPDATE enrollments SET status = 'expired' WHERE id = $1",
          [Ecto.UUID.dump!(enrollment.id)]
        )

      assert :ok = perform_job(NotificationWorker, reminder_args(owner, enrollment))

      refute_receive {:notification, :wechat, _}
      assert {:ok, 1} = Consent.remaining(owner.id, :wechat, "approval_reminder")
    end

    test "报名非 pending（confirmed）→ 跳过" do
      %{owner: owner, enrollment: enrollment} = enrollment_setup()

      {:ok, _} =
        Ecto.Adapters.SQL.query(
          Cgc2046.Repo,
          "UPDATE enrollments SET status = 'confirmed' WHERE id = $1",
          [Ecto.UUID.dump!(enrollment.id)]
        )

      assert :ok = perform_job(NotificationWorker, reminder_args(owner, enrollment))

      refute_receive {:notification, :wechat, _}
      assert {:ok, 1} = Consent.remaining(owner.id, :wechat, "approval_reminder")
    end
  end

  describe "stale 重查：approval_reminder × sponsorship_id（表条目 {Sponsorship, :pending, :not_expired}）" do
    test "赞助 pending 且 deadline 未来 → 投递" do
      %{owner: owner, sponsorship: sponsorship} = sponsorship_setup()

      assert :ok =
               perform_job(NotificationWorker, sponsorship_reminder_args(owner, sponsorship))

      assert_receive {:notification, :wechat, _}
      assert {:ok, 0} = Consent.remaining(owner.id, :wechat, "approval_reminder")
    end

    test "赞助已过期 → 跳过且不消耗授权" do
      %{owner: owner, sponsorship: sponsorship} = sponsorship_setup()

      {:ok, _} =
        Ecto.Adapters.SQL.query(
          Cgc2046.Repo,
          "UPDATE sponsorships SET status = 'expired' WHERE id = $1",
          [Ecto.UUID.dump!(sponsorship.id)]
        )

      assert :ok = perform_job(NotificationWorker, sponsorship_reminder_args(owner, sponsorship))

      refute_receive {:notification, :wechat, _}
      assert {:ok, 1} = Consent.remaining(owner.id, :wechat, "approval_reminder")
    end

    test "赞助非 pending（active）→ 跳过" do
      %{owner: owner, sponsorship: sponsorship} = sponsorship_setup()

      {:ok, _} =
        Ecto.Adapters.SQL.query(
          Cgc2046.Repo,
          "UPDATE sponsorships SET status = 'active' WHERE id = $1",
          [Ecto.UUID.dump!(sponsorship.id)]
        )

      assert :ok = perform_job(NotificationWorker, sponsorship_reminder_args(owner, sponsorship))

      refute_receive {:notification, :wechat, _}
      assert {:ok, 1} = Consent.remaining(owner.id, :wechat, "approval_reminder")
    end
  end

  describe "stale 重查：learning_stagnation（表条目 {WorkflowRun, :running, :running}）" do
    test "learning run 仍 running → 投递" do
      %{owner: owner, run: run} = running_run_setup()

      assert :ok = perform_job(NotificationWorker, stagnation_args(owner, run))

      assert_receive {:notification, :wechat, _}
      assert {:ok, 0} = Consent.remaining(owner.id, :wechat, "learning_stagnation")
    end

    test "learning run 终态（succeeded）→ 跳过" do
      %{owner: owner, run: run} = running_run_setup()

      {:ok, _} =
        Ecto.Adapters.SQL.query(
          Cgc2046.Repo,
          "UPDATE workflow_runs SET status = 'succeeded', finished_at = NOW() WHERE id = $1",
          [Ecto.UUID.dump!(run.id)]
        )

      assert :ok = perform_job(NotificationWorker, stagnation_args(owner, run))

      refute_receive {:notification, :wechat, _}
      assert {:ok, 1} = Consent.remaining(owner.id, :wechat, "learning_stagnation")
    end
  end

  describe "非提醒类型（stale = nil）" do
    test "不重查直接投递（data 引用的业务实体不存在也照发）" do
      owner = Fixtures.platform_admin("nw-nostale")

      insert_identity(owner.id, "nw-nostale-openid")
      {:ok, _} = Consent.grant(owner.id, :wechat, "approval_result")

      assert :ok =
               perform_job(NotificationWorker, %{
                 "user_id" => owner.id,
                 "identity_uid" => "nw-nostale-openid",
                 "platform" => "wechat",
                 "template_key" => "approval_result",
                 "data" => %{"status" => "confirmed", "enrollment_id" => "no-such-id"}
               })

      assert_receive {:notification, :wechat, _}
      assert {:ok, 0} = Consent.remaining(owner.id, :wechat, "approval_result")
    end
  end

  # --- fixtures ---------------------------------------------------------------

  # approval_reminder × enrollment_id 面：pending 报名 + 未来 deadline + owner 身份 + 授权。
  defp enrollment_setup do
    owner = Fixtures.platform_admin("nw-enroll-admin")
    workspace = Fixtures.create_workspace(owner)
    learner = Fixtures.register_user("nw-enroll-learner")

    event = EventFixtures.create_event(workspace, owner, %{enrollment_policy: :request})

    enrollment =
      Enrollment
      |> Ash.Changeset.for_create(
        :create_enrollment,
        %{
          event_id: event.id,
          user_id: learner.id,
          approval_deadline: DateTime.add(DateTime.utc_now(), 24, :hour)
        },
        tenant: workspace.id,
        actor: learner
      )
      |> Ash.create!(tenant: workspace.id, actor: learner)

    insert_identity(owner.id, "nw-enroll-owner-openid")
    {:ok, _} = Consent.grant(owner.id, :wechat, "approval_reminder")
    %{owner: owner, enrollment: enrollment}
  end

  # approval_reminder × sponsorship_id 面：pending 赞助 + 未来 deadline（服务端生成，
  # SQL 注入 48h 窗口）+ owner 身份 + 授权。
  defp sponsorship_setup do
    owner = Fixtures.platform_admin("nw-sponsor-admin")
    workspace = Fixtures.create_workspace(owner)
    sponsor = Fixtures.register_user("nw-sponsor-sponsor")
    event = EventFixtures.create_event(workspace, owner)

    {:ok, sponsorship} =
      Sponsorship
      |> Ash.Changeset.for_create(:create_sponsorship, %{
        level: :event,
        event_id: event.id,
        sponsor_user_id: sponsor.id,
        company_name: "Acme",
        contact_email: sponsor.email
      })
      |> Ash.create(tenant: workspace.id, actor: sponsor)

    {:ok, _} =
      Ecto.Adapters.SQL.query(
        Cgc2046.Repo,
        "UPDATE sponsorships SET approval_deadline = $1 WHERE id = $2",
        [DateTime.add(DateTime.utc_now(), 24, :hour), Ecto.UUID.dump!(sponsorship.id)]
      )

    insert_identity(owner.id, "nw-sponsor-owner-openid")
    {:ok, _} = Consent.grant(owner.id, :wechat, "approval_reminder")
    %{owner: owner, sponsorship: sponsorship}
  end

  # learning_stagnation 面：learning run 走 :start（pending → running，纯状态流转
  # 不经 Engine）+ owner 身份 + 授权。
  defp running_run_setup do
    owner = Fixtures.platform_admin("nw-stag-admin")
    workspace = Fixtures.create_workspace(owner)

    {:ok, defn} =
      WorkflowDefinition
      |> Ash.Changeset.for_create(
        :create,
        %{
          name: "学习 workflow",
          type: :learning,
          input_schema: %{},
          node_def: %{"steps" => [%{"id" => "s1", "type" => "manual"}]}
        },
        tenant: workspace.id,
        actor: owner
      )
      |> Ash.create(tenant: workspace.id, actor: owner)

    {:ok, published} =
      defn
      |> Ash.Changeset.for_update(:publish, %{}, actor: owner)
      |> Ash.update(tenant: workspace.id, actor: owner)

    {:ok, run} =
      WorkflowRun
      |> Ash.Changeset.for_create(
        :create,
        %{
          definition_id: published.id,
          definition_version: published.version,
          input_snapshot: %{"title" => "t"}
        },
        tenant: workspace.id,
        actor: owner
      )
      |> Ash.create(tenant: workspace.id, actor: owner)

    {:ok, running} =
      run
      |> Ash.Changeset.for_update(:start, %{}, actor: owner)
      |> Ash.update(tenant: workspace.id, actor: owner)

    assert running.status == :running

    insert_identity(owner.id, "nw-stag-owner-openid")
    {:ok, _} = Consent.grant(owner.id, :wechat, "learning_stagnation")
    %{owner: owner, run: running}
  end

  defp reminder_args(owner, enrollment) do
    %{
      "user_id" => owner.id,
      "identity_uid" => "nw-enroll-owner-openid",
      "platform" => "wechat",
      "template_key" => "approval_reminder",
      "data" => %{
        "enrollment_id" => enrollment.id,
        "approval_deadline" => DateTime.to_iso8601(enrollment.approval_deadline)
      }
    }
  end

  defp sponsorship_reminder_args(owner, sponsorship) do
    %{
      "user_id" => owner.id,
      "identity_uid" => "nw-sponsor-owner-openid",
      "platform" => "wechat",
      "template_key" => "approval_reminder",
      "data" => %{
        "sponsorship_id" => sponsorship.id,
        "approval_deadline" => DateTime.to_iso8601(sponsorship.approval_deadline)
      }
    }
  end

  defp stagnation_args(owner, run) do
    %{
      "user_id" => owner.id,
      "identity_uid" => "nw-stag-owner-openid",
      "platform" => "wechat",
      "template_key" => "learning_stagnation",
      "data" => %{"enrollment_id" => "e1", "run_id" => run.id, "title" => "t"}
    }
  end

  # 平台身份布置（speaker_flow_test / ARW test 同款：register_user 只建账号
  # 不建平台身份；通知入队按 UserIdentity 精确投递）
  defp insert_identity(user_id, uid) do
    Cgc2046.Repo.query!(
      """
      INSERT INTO user_identities (id, provider, uid, user_id, inserted_at, updated_at)
      VALUES (gen_random_uuid(), 'wechat', $1, $2, NOW(), NOW())
      """,
      [uid, Ecto.UUID.dump!(user_id)]
    )
  end

  defp body!(conn) do
    {:ok, raw, _conn} = Plug.Conn.read_body(conn)
    Jason.decode!(raw)
  end
end
