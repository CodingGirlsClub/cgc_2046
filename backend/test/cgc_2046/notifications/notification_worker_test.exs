defmodule Cgc2046.Notifications.NotificationWorkerTest do
  @moduledoc """
  通知类型契约 registry 的表驱动契约测试（2026-08-18 架构深化候选 D；plan
  ）。

  1. config `:miniprogram_templates` 键集 ↔ `@notification_types` 双射；
  2. registry 键集 ⊆ 前端订阅场景 ∪ 显式缺口表（#664：无入口的模板生产恒
     discarded，逐个登记在 @scenario_gaps，漏登记即红）；
  3. 表驱动 stale 重查语义（逐条目与收敛前三子句等价）：
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

  # #664 审计开出的 6 键缺口已由 #683 全部补齐前端入口（enrollment_submitted +
  # payment_received → 工作台第二按钮；payment_succeeded → 支付页双态；退款三键
  # → 「我的报名」付费卡）；U4 的 6 个志愿者段位场景为过渡态登记（见下），前端
  # 场景落地后即回 0。本表**结构保留**：registry 未来新增无前端场景的键必须在
  # 此登记（守卫第 4 条 uncovered 会红），登记数在下方断言写死——改本表/本数必须
  # 是有意识的决定。前端侧镜像清单 =
  # `miniprogram/tests/subscription-domain.test.ts` 的 UNCOVERED_SCENARIOS。
  @scenario_gaps [
    # 残余缺口（不占本表，记录于 subscription.ts moduledoc「覆盖缺口」节）：
    # - refund_succeeded / refund_failed / payment_expired 的**管理者腿**：小程序
    #   无退款操作面（refundOrder 仅 web），最佳授权时刻不可达，先例 =
    #   speaker_completed 分享者腿；
    # - enrollment_completed 的 web 报名腿：微信一次性订阅只能在小程序内发起。
    #
    # U4 志愿者段位通知六模板：后端已落地（R14 六订阅场景），小程序侧订阅触点与
    # 场景映射由 U10（招募流）落地——U10 把这 6 个场景加进 subscription.ts 的
    # ALL_SCENARIOS 后，**必须清空本表并把下方断言数改回 0**（本表是过渡态登记，
    # 不是永久豁免）。
    "volunteer_application_submitted",
    "volunteer_application_interview",
    "volunteer_application_training",
    "volunteer_application_assigned",
    "volunteer_application_rejected",
    "volunteer_application_canceled"
  ]

  # U4 过渡态缺口数（U10 落地后回 0）——改本数必须是有意识的决定
  @scenario_gap_count 6

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

    test "registry 键集 ⊆ 前端订阅场景 ∪ 显式缺口（#664 漏网守卫）" do
      registry = registry_keys()
      scenarios = frontend_scenarios()
      gaps = MapSet.new(@scenario_gaps)

      # 缺口数先钉死（#683 补齐 6 键后为 0；U4 过渡态为 6——见 @scenario_gaps）：
      # 防「新键被随手塞进缺口表」蒙混过关（改这个数 = 有意识承认一个新缺口，
      # 与 #606 allowlist / 前端场景计数同款纪律）
      assert MapSet.size(gaps) == @scenario_gap_count,
             "缺口数变为 #{MapSet.size(gaps)}：#{inspect(Enum.sort(gaps))}——改本表/本数必须是有意识的决定"

      # 缺口表不得腐烂：键被删/改名后必须同步删行，否则守卫会为幽灵键放行
      assert MapSet.subset?(gaps, registry),
             "缺口表有 registry 不存在的键：" <>
               inspect(MapSet.difference(gaps, registry) |> Enum.sort())

      # 已补入口的键必须移出缺口表——否则「补了入口」不会被本守卫要求清理
      assert MapSet.disjoint?(gaps, scenarios),
             "这些键已有前端场景，必须从 @scenario_gaps 移除：" <>
               inspect(MapSet.intersection(gaps, scenarios) |> Enum.sort())

      # 本 #664 的失败形态：registry 加了键、前端没加场景 → 生产恒 discarded
      uncovered = MapSet.difference(registry, MapSet.union(scenarios, gaps))

      assert MapSet.size(uncovered) == 0,
             "registry 有键既无前端订阅场景、也不在显式缺口表（生产恒 discarded）：" <>
               inspect(Enum.sort(uncovered))

      # 反向：前端场景必须在 registry 里有条目——否则用户授权的是一个后端永远
      # 不会发送的模板（死配额 + 误导文案）。两个方向合起来才是「键集对齐」；
      # 前端加场景却忘记加 registry/config 时，由本条钉死。
      assert MapSet.subset?(scenarios, registry),
             "这些前端场景在 registry 里没有条目（授权即死配额）：" <>
               inspect(MapSet.difference(scenarios, registry) |> Enum.sort())
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

    # #664 正向可达（对照：修前前端从无 enrollment_completed 场景 ⇒ 本用例的
    # grant 在生产永远不会发生、作业落 consent_exhausted discarded）。断言到落页
    # ——「送得到」包含「点开有权威内容」：我的报名是报名结果的权威展示面
    # （client.ex @learner_templates）。
    test "enrollment_completed：授权 → 投递成功 + 落页 + 配额消费（#664）" do
      owner = Fixtures.platform_admin("nw-completed")

      insert_identity(owner.id, "nw-completed-openid")
      {:ok, _} = Consent.grant(owner.id, :wechat, "enrollment_completed")

      assert :ok =
               perform_job(NotificationWorker, %{
                 "user_id" => owner.id,
                 "identity_uid" => "nw-completed-openid",
                 "platform" => "wechat",
                 "template_key" => "enrollment_completed",
                 "data" => %{
                   "enrollment_id" => "6f0c9a1e-2b3d-4c5f-8a9b-0c1d2e3f4a5b",
                   "title" => "AI 入门工作坊"
                 }
               })

      assert_receive {:notification, :wechat, %{"page" => page, "data" => data}}
      assert page == "pages/my-enrollments/index", "报名成功通知必须落我的报名（报名结果权威面）"
      assert data["thing1"] == %{"value" => "AI 入门工作坊"}
      assert {:ok, 0} = Consent.remaining(owner.id, :wechat, "enrollment_completed")
    end
  end

  describe "consent_exhausted 可观测性（#635：此前与「已送达」同桶静默吞成 :ok）" do
    test "未授权 → {:discard, _} + Logger.warning，且一条都不发" do
      owner = Fixtures.platform_admin("nw-no-consent")

      insert_identity(owner.id, "nw-no-consent-openid")

      # 不调 Consent.grant ⇒ take/3 命中 remaining_uses > 0 零行 → :consent_exhausted
      log =
        ExUnit.CaptureLog.capture_log(fn ->
          assert {:discard, "consent_exhausted"} =
                   perform_job(NotificationWorker, %{
                     "user_id" => owner.id,
                     "identity_uid" => "nw-no-consent-openid",
                     "platform" => "wechat",
                     "template_key" => "approval_result",
                     "data" => %{"status" => "confirmed", "enrollment_id" => "no-such-id"}
                   })
        end)

      # 没授权 ⇒ 零发送（未送达是事实，不是推论）
      refute_received {:notification, :wechat, _}

      # 与「已送达」（:ok / completed）明确可区分：作业落 :discard，且日志指名道姓
      assert log =~ "notification not delivered: consent exhausted"
      assert log =~ "template_key=approval_result"
      assert log =~ "user_id=#{owner.id}"
    end

    test "平台身份缺失仍静默跳过（非缺陷，不落 :discard 也不刷日志）" do
      owner = Fixtures.platform_admin("nw-no-identity")

      log =
        ExUnit.CaptureLog.capture_log(fn ->
          assert :ok =
                   perform_job(NotificationWorker, %{
                     "user_id" => owner.id,
                     "platform" => "wechat",
                     "template_key" => "approval_result",
                     "data" => %{"status" => "confirmed", "enrollment_id" => "no-such-id"}
                   })
        end)

      refute log =~ "consent exhausted"
    end
  end

  describe "template_not_configured 终态（#664 F3：此前白重试 3 次后 discarded，且注释谎报「静默跳过」）" do
    test "模板未配置 → {:discard, \"template_not_configured\"} + Logger.warning（不重试、不静默）" do
      original = Application.get_env(:cgc_2046, :miniprogram_templates)
      on_exit(fn -> Application.put_env(:cgc_2046, :miniprogram_templates, original) end)

      # 抽掉 wechat 的模板 ID（= 生产上 env 未注入/改名，即 #606 的 480 条场景）。
      # template_id 门禁在 Consent.take 之前 ⇒ 本用例不触达 DB/HTTP。
      Application.put_env(
        :cgc_2046,
        :miniprogram_templates,
        Map.update!(original, :wechat, &Map.delete(&1, "enrollment_completed"))
      )

      log =
        ExUnit.CaptureLog.capture_log(fn ->
          assert {:discard, "template_not_configured"} =
                   perform_job(NotificationWorker, %{
                     "user_id" => "any-user",
                     "identity_uid" => "any-openid",
                     "platform" => "wechat",
                     "template_key" => "enrollment_completed",
                     "data" => %{}
                   })
        end)

      # 一条都不发；作业以明确 reason 终态化（区别于 catch-all 的 {:error, _} 重试）
      refute_received {:notification, :wechat, _}
      assert log =~ "notification not delivered: template not configured"
      assert log =~ "template_key=enrollment_completed"
      assert log =~ "platform=wechat"
    end
  end

  # --- fixtures ---------------------------------------------------------------

  defp registry_keys do
    NotificationWorker.types()
    |> Enum.map(& &1.template_key)
    |> MapSet.new()
  end

  # 前端订阅场景集合（#664 守卫的另一半真源）= ALL_SCENARIOS。
  # **只扫键名，不读任何 env 值**：模板 ID 只在构建期注入，仓内零 ID 红线由
  # miniprogram/tests/subscription-build.test.mjs 继续守；四方键集双射
  # （config/index.ts ↔ models.ts 联合 ↔ ALL_SCENARIOS ↔ .env*.example）也由该
  # 前端测试钉住，本守卫只消费 ALL_SCENARIOS 这一份。
  defp frontend_scenarios do
    path = Path.expand("../../../../miniprogram/src/domain/subscription.ts", __DIR__)
    source = File.read!(path)

    # 联合声明式列表：`export const ALL_SCENARIOS = [ ... ] as const`
    [_, block] = Regex.run(~r/export const ALL_SCENARIOS = \[(.*?)\] as const/s, source)

    # 去行注释后再取键：注释里出现的示例字面量不得计入场景集（否则会被当成
    # 「registry 不存在的场景」误报，或反向当成「已覆盖」漏判）。
    block = String.replace(block, ~r{//[^\n]*}, "")

    ~r/'([a-z0-9_]+)'/
    |> Regex.scan(block)
    |> Enum.map(fn [_, key] -> key end)
    |> MapSet.new()
  end

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
          name: "学习 workflow（测试布景）",
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
          input_snapshot: %{"title" => "t", "user_id" => owner.id}
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
