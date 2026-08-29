defmodule Cgc2046.Workflows.SignalSubscriberTest do
  @moduledoc """
  SignalSubscriber 骨架单测（异步链路深化 PR-B；plan 2026-08-14-003 验收项）。

  覆盖：四策略 claim 时机（claim_first / claim_in_handle / claim_after_effects /
  state_based）、deliver/2 同步入口、缺幂等键契约、rescue 壳、订阅失败即停
  （Q3）、forwarder DOWN 自动重订阅（D3）。

  策略类测试只走 deliver/2（纯同步，不触总线）；生命周期测试用真实总线
  （JidoAdapter.publish → forwarder → run/3——与生产同码）。测试订阅方为
  `Cgc2046.Workflows.SignalSubscriberFixtures` 下独立模块（单文件单模块纪律）。
  """

  use Cgc2046.DataCase, async: false

  alias Cgc2046.Workflows.{JidoAdapter, SignalIdempotency, SignalSubscriber}

  alias Cgc2046.Workflows.SignalSubscriberFixtures.{
    BadPattern,
    BusProbe,
    BusRestart,
    ClaimAfter,
    ClaimFirst,
    ClaimInHandle,
    ClaimInHandleIncomplete,
    Crash,
    DrainClaim,
    ExplicitKey,
    Resubscribe,
    StateBased
  }

  require Ash.Query

  describe "claim_first：副作用前 claim（NS/SS 语义）" do
    test "首投 claim 成功 → 执行 handle；重复投递 → :duplicate 不再执行" do
      assert :ok =
               SignalSubscriber.deliver(ClaimFirst, %{
                 type: "fixture.claim_first",
                 data: %{"test_pid" => self(), "n" => 1, "idempotency_key" => "fixture:cf-1"}
               })

      assert_receive {:handled, 1}
      assert claim_keys("fixture.claim_first") == ["fixture:cf-1:claim_first"]

      assert :duplicate =
               SignalSubscriber.deliver(ClaimFirst, %{
                 type: "fixture.claim_first",
                 data: %{"test_pid" => self(), "n" => 2, "idempotency_key" => "fixture:cf-1"}
               })

      refute_receive {:handled, 2}
      # 唯一索引兜底：重复投递不新增 claim 行
      assert claim_keys("fixture.claim_first") == ["fixture:cf-1:claim_first"]
    end
  end

  describe "claim_in_handle：双回调结构化（before_claim 校验 + 骨架 claim + effects；G 方向②）" do
    test "校验不过不烧 claim；校验通过才 claim + effects；重复投递不重复执行 effects" do
      # 校验跳过（类比无已发布学习定义 / 瞬时读失败）：不写 claim 行
      assert :ok =
               SignalSubscriber.deliver(ClaimInHandle, %{
                 type: "fixture.claim_in_handle",
                 data: %{
                   "test_pid" => self(),
                   "n" => 1,
                   "skip" => true,
                   "idempotency_key" => "fixture:cih-1"
                 }
               })

      assert_receive {:skipped, 1}
      assert claim_keys("fixture.claim_in_handle") == []

      # 校验通过：骨架 claim + effects 执行
      assert :ok =
               SignalSubscriber.deliver(ClaimInHandle, %{
                 type: "fixture.claim_in_handle",
                 data: %{"test_pid" => self(), "n" => 2, "idempotency_key" => "fixture:cih-1"}
               })

      assert_receive {:claimed, 2}
      assert_receive {:effects, 2}
      assert claim_keys("fixture.claim_in_handle") == ["fixture:cih-1:claim_in_handle"]

      # 重复投递：骨架 claim 拦截、不重复执行 effects，归一化为 :ok（LI 旧语义）
      assert :ok =
               SignalSubscriber.deliver(ClaimInHandle, %{
                 type: "fixture.claim_in_handle",
                 data: %{"test_pid" => self(), "n" => 3, "idempotency_key" => "fixture:cih-1"}
               })

      assert_receive {:claimed, 3}
      refute_receive {:effects, 3}
      assert claim_keys("fixture.claim_in_handle") == ["fixture:cih-1:claim_in_handle"]
    end

    test "声明 claim_in_handle 但未实现双回调 → raise ArgumentError（编程错误不静默降级）" do
      assert_raise ArgumentError, ~r/before_claim\/2 and effects\/3/, fn ->
        SignalSubscriber.deliver(ClaimInHandleIncomplete, %{
          type: "fixture.claim_in_handle_incomplete",
          data: %{"test_pid" => self(), "n" => 1, "idempotency_key" => "fixture:cihi-1"}
        })
      end

      refute_receive {:handled, _}
      assert claim_keys("fixture.claim_in_handle_incomplete") == []
    end
  end

  describe "claim_after_effects：全部副作用成功才 claim（SES/RRR 语义）" do
    test "handle 返回 {:error} → 不落 claim（等重投）；{:ok} → 落 claim" do
      assert {:error, :boom} =
               SignalSubscriber.deliver(ClaimAfter, %{
                 type: "fixture.claim_after",
                 data: %{
                   "test_pid" => self(),
                   "n" => 1,
                   "fail" => true,
                   "idempotency_key" => "fixture:ca-1"
                 }
               })

      assert_receive {:failed_effect, 1}
      assert claim_keys("fixture.claim_after") == []

      assert :ok =
               SignalSubscriber.deliver(ClaimAfter, %{
                 type: "fixture.claim_after",
                 data: %{"test_pid" => self(), "n" => 2, "idempotency_key" => "fixture:ca-1"}
               })

      assert_receive {:handled, 2}
      assert claim_keys("fixture.claim_after") == ["fixture:ca-1:claim_after"]
    end

    test "claim 已存在时副作用照常执行（重放无害，state 守卫是业务侧职责）" do
      for n <- 1..2 do
        assert :ok =
                 SignalSubscriber.deliver(ClaimAfter, %{
                   type: "fixture.claim_after",
                   data: %{"test_pid" => self(), "n" => n, "idempotency_key" => "fixture:ca-2"}
                 })
      end

      assert_receive {:handled, 1}
      assert_receive {:handled, 2}
      assert claim_keys("fixture.claim_after") == ["fixture:ca-2:claim_after"]
    end
  end

  describe "state_based：不写 claim（RI 语义）" do
    test "每次投递都执行，signal_idempotency 无行" do
      for n <- 1..2 do
        assert :ok =
                 SignalSubscriber.deliver(StateBased, %{
                   type: "fixture.state_based",
                   data: %{"test_pid" => self(), "n" => n}
                 })
      end

      assert_receive {:handled, 1}
      assert_receive {:handled, 2}
      assert claim_keys("fixture.state_based") == []
    end
  end

  describe "消费键契约（Q12）" do
    test "缺 idempotency_key = 生产者契约违约 → 丢弃不执行副作用" do
      assert {:error, :missing_idempotency_key} =
               SignalSubscriber.deliver(ClaimFirst, %{
                 type: "fixture.claim_first",
                 data: %{"test_pid" => self(), "n" => 1}
               })

      assert {:error, :missing_idempotency_key} =
               SignalSubscriber.deliver(ClaimAfter, %{
                 type: "fixture.claim_after",
                 data: %{"test_pid" => self(), "n" => 1}
               })

      refute_receive {:handled, _}
      refute_receive {:failed_effect, _}
    end
  end

  describe "consumer_key 显式声明（Fable 5 M3）" do
    test "显式 consumer_key 优先于 leaf 派生：claim 键用钉死值" do
      # ExplicitKey 的 leaf 派生值为 "explicit_key"，显式声明 "pinned_consumer"——
      # 键落 pinned_consumer 即证显式优先（派生回落由其余 fixture 全覆盖）。
      assert :ok =
               SignalSubscriber.deliver(ExplicitKey, %{
                 type: "fixture.explicit_key",
                 data: %{"test_pid" => self(), "n" => 1, "idempotency_key" => "fixture:ek-1"}
               })

      assert_receive {:handled, 1}
      assert claim_keys("fixture.explicit_key") == ["fixture:ek-1:pinned_consumer"]
    end

    # 注册订阅方（Application 监督树）显式 consumer_key 锚定：键值 = 当前 leaf
    # 派生值——钉死持久化幂等键。模块 leaf 改名 → 派生值变化 → 本断言红灯，
    # 强制人工核对存量 claim 键（改名静默换键已发生两次：
    # notification_subscriber→subscriber、research_run_reaper→reaper）。
    # 新增订阅方须在此登记。
    @registered_subscribers [
      Cgc2046.Admission.CapacityLedgerSubscriber,
      Cgc2046.Courses.CapacityProjectionSubscriber,
      Cgc2046.Curriculum.Instantiator,
      Cgc2046.Curriculum.Reaper,
      Cgc2046.Events.CapacityProjectionSubscriber,
      Cgc2046.Notifications.Subscriber,
      Cgc2046.Events.SpeakerSubscriber,
      Cgc2046.Sponsorship.SponsorshipEndedSubscriber,
      Cgc2046.Admission.Workers.OfferingCancelRefundWorker,
      Cgc2046.Learning.LearningInstantiator,
      Cgc2046.Workflows.ShareSchemeInstantiator
    ]

    test "契约：注册订阅方显式 consumer_key == 当前 leaf 派生值" do
      for module <- @registered_subscribers do
        derived = module |> Module.split() |> List.last() |> Macro.underscore()

        assert module.__signal_subscriber_config__().consumer_key == derived,
               "#{inspect(module)} 未显式声明 consumer_key 或键值已漂移"
      end
    end
  end

  describe "rescue 壳" do
    test "handle 抛异常被骨架捕获：返回 {:error, :crashed}，不外泄" do
      assert {:error, {:crashed, _reason}} =
               SignalSubscriber.deliver(Crash, %{
                 type: "fixture.crash",
                 data: %{"raise" => true}
               })

      # 同一模块后续投递不受影响（forwarder 存活）
      assert :ok =
               SignalSubscriber.deliver(Crash, %{
                 type: "fixture.crash",
                 data: %{"test_pid" => self(), "n" => 1}
               })

      assert_receive {:handled, 1}
    end
  end

  describe "订阅生命周期（Q3 / D3）" do
    test "订阅失败即停：start_link 返回 {:error, _}（监督树重试，不聋着活）" do
      # 直调 start_link 的调用方须 trap exits（生产调用方 supervisor 天然 trap）：
      # init {:stop, reason} 会向 link 方传递退出信号
      Process.flag(:trap_exit, true)

      # trap 下 proc_lib 握手消费 EXIT 消息后返回错误——{:error, _} 即完整证明
      assert {:error, {:subscribe_failed, "fixture..bad", _reason}} = BadPattern.start_link(nil)
    end

    test "forwarder 崩溃 → 骨架收 DOWN 自动重订阅 → 信号再次可达" do
      start_supervised!(Resubscribe)

      assert :ok =
               JidoAdapter.publish("fixture.resubscribe", %{"test_pid" => self(), "n" => 1})

      assert_receive {:handled, 1}, 1_000

      # 首个 forwarder 已在 handle 内自杀；重订阅是异步的——短窗内 publish
      # 可能丢失，按至少一次语义重发直至送达（与 SignalPublishWorker 重试同构）。
      publish_until_handled("fixture.resubscribe", 2)
    end
  end

  # --- 助手 -----------------------------------------------------------------

  # claim 键 = 生产者键 <> ":" <> 消费者短名（plan Q12），直接断言完整键
  defp claim_keys(signal_type) do
    SignalIdempotency
    |> Ash.Query.filter(signal_type == ^signal_type)
    |> Ash.read!(authorize?: false)
    |> Enum.map(& &1.idempotency_key)
  end

  describe "bus 重启重订阅（#120）" do
    test "杂散 :bus_resubscribe（健康状态）→ 守卫 no-op：订阅 ref 集不变、publish 一次恰好一投（M1）" do
      start_supervised!(BusRestart)

      subscriber_pid = Process.whereis(BusRestart)
      before_refs = Map.keys(:sys.get_state(subscriber_pid).subscriptions)
      assert length(before_refs) == 2

      # 杂散重订阅消息（运维 console 误发 / 竞态残留定时器）：健康订阅方须
      # no-op——map 模式 %{subscriptions: %{}} 是子集匹配不构成空守卫（M1 实锤）
      send(subscriber_pid, :bus_resubscribe)
      Process.sleep(100)

      after_refs = :sys.get_state(subscriber_pid).subscriptions |> Map.keys()
      assert MapSet.new(after_refs) == MapSet.new(before_refs)

      assert :ok =
               JidoAdapter.publish("fixture.bus_restart", %{"test_pid" => self(), "n" => 1})

      assert_receive {:handled, "fixture.bus_restart", 1}, 1_000
      refute_receive {:handled, "fixture.bus_restart", 1}
    end

    test "bus :kill → permanent 自动重启 → 全量重订阅恢复投递 + 旧 forwarder 回收" do
      start_supervised!(BusRestart)

      subscriber_pid = Process.whereis(BusRestart)
      %{forwarders: old_forwarders} = :sys.get_state(subscriber_pid)

      assert :ok =
               JidoAdapter.publish("fixture.bus_restart", %{"test_pid" => self(), "n" => 1})

      assert_receive {:handled, "fixture.bus_restart", 1}, 1_000

      # 真实 permanent 重启（#120 场景）：粗暴 kill → supervisor 自动拉起。
      # 区别于 terminate_child（移除监督不自动重启，构不成「重启」）。
      {:ok, bus_pid} = JidoAdapter.whereis_bus()
      Process.exit(bus_pid, :kill)

      # 重订阅是 DOWN → 回收 → 退避后异步完成：轮询 publish 直至送达
      publish_bus_restart_until_handled(2)

      # 订阅方存活；全部 patterns 重订阅；旧 forwarder 已被显式回收（不泄漏）
      assert Process.alive?(subscriber_pid)
      state = :sys.get_state(subscriber_pid)
      assert length(Map.keys(state.subscriptions)) == 2
      assert state.bus_monitor != nil

      assert Enum.all?(Map.values(old_forwarders), fn forwarder ->
               not Process.alive?(forwarder)
             end)
    end

    test "bus 不回归窗口（terminate_child）→ 订阅方退避存活不 stop；回归后自动恢复" do
      start_supervised!(BusRestart)

      bus_id = JidoAdapter.bus_name()
      assert :ok = Supervisor.terminate_child(Cgc2046.Supervisor, bus_id)

      # DOWN 处理 + 首轮退避（100ms）走完后：订阅方存活、订阅表清空、bus 无 monitor
      Process.sleep(300)

      subscriber_pid = Process.whereis(BusRestart)
      assert subscriber_pid != nil and Process.alive?(subscriber_pid)
      state = :sys.get_state(subscriber_pid)
      assert state.subscriptions == %{}
      assert state.bus_monitor == nil
      assert state.bus_retries > 0

      # bus 回归 → 退避到期后自动恢复订阅与投递
      assert {:ok, _pid} = Supervisor.restart_child(Cgc2046.Supervisor, bus_id)
      publish_bus_restart_until_handled(1)
      assert Process.alive?(subscriber_pid)
    after
      # 防御恢复（正常路径已恢复时返回 {:error, :running}，不视为失败）
      _ = Supervisor.restart_child(Cgc2046.Supervisor, JidoAdapter.bus_name())
    end

    test "真实订阅方（Notifications.Subscriber）：bus :kill 重启后投递恢复（真实双证）" do
      # enrollment.submitted 非 request 策略 → handle 落 :ok 无副作用分支：
      # 只经 claim（SignalIdempotency 写，shared sandbox 覆盖）+ telemetry 可观察
      test_pid = self()

      :telemetry.attach(
        "bus-restart-ns",
        [:cgc2046, :signal, :deliver],
        fn _event, _measurements, meta, _config ->
          if meta[:subscriber] == "Subscriber" do
            send(test_pid, {:ns_delivered, meta.type})
          end
        end,
        nil
      )

      {:ok, bus_pid} = JidoAdapter.whereis_bus()
      Process.exit(bus_pid, :kill)

      payload = %{
        "enrollment_id" => Ecto.UUID.generate(),
        "workspace_id" => Ecto.UUID.generate(),
        "idempotency_key" => "bus-restart-ns:" <> Ecto.UUID.generate()
      }

      wait_until(fn ->
        case JidoAdapter.publish("enrollment.submitted", payload) do
          :ok ->
            receive do
              {:ns_delivered, "enrollment.submitted"} -> true
            after
              100 -> false
            end

          {:error, _reason} ->
            false
        end
      end)
    after
      :telemetry.detach("bus-restart-ns")
    end
  end

  describe "bus 重启 drain：在途投递不被 kill 截断（#245）" do
    test "claim 已烧、effects sleep 中 kill bus → drain 等完成，effects 恰一次落账" do
      start_supervised!(DrainClaim)

      assert :ok =
               JidoAdapter.publish("fixture.drain_claim", %{
                 "test_pid" => self(),
                 "n" => 1,
                 "idempotency_key" => "fixture:dc-1"
               })

      # 100ms 时点：claim_first 已落 claim、handle 处于 300ms sleep 中——
      # 旧裸 kill 行为在此截断（effects 零落账 + claim 永久拦重投 = #245）
      Process.sleep(100)

      {:ok, bus_pid} = JidoAdapter.whereis_bus()
      Process.exit(bus_pid, :kill)

      # drain 等 sleep 完成（预算 2s 压 CI 慢机）：effects 恰一次落账
      assert_receive {:handled, 1}, 2_000
      refute_receive {:handled, 1}

      # claim 行真实存在（修复非「kill 落在 claim 前」侥幸）且重投被幂等拦截
      assert claim_keys("fixture.drain_claim") == ["fixture:dc-1:drain_claim"]

      assert :duplicate =
               SignalSubscriber.deliver(DrainClaim, %{
                 type: "fixture.drain_claim",
                 data: %{"test_pid" => self(), "n" => 2, "idempotency_key" => "fixture:dc-1"}
               })

      refute_receive {:handled, 2}
      assert Process.alive?(Process.whereis(DrainClaim))
    after
      # kill bus 触发全部 app 订阅方走 bus DOWN 退避重订阅，等完成后才返回
      wait_until(&app_subscribers_resubscribed?/0)
    end
  end

  describe "bus 退避 give-up → 低频探测 → 恢复（#244）" do
    # 注入小参数（BusProbe fixture：max_retries 3 / probe_interval 200ms）使
    # give-up→探测→恢复全链秒级完成。telemetry handler 对齐 fanout 惯例：
    # attach_many + unique handler_id + on_exit detach。
    test "退避耗尽 give-up → 探测模式；bus 回归 → 自动恢复订阅与投递" do
      test_pid = self()
      handler_id = "bus-probe-#{System.unique_integer([:positive])}"

      :ok =
        :telemetry.attach_many(
          handler_id,
          [
            [:cgc2046, :signal_subscriber, :give_up],
            [:cgc2046, :signal_subscriber, :recovered]
          ],
          fn event, measurements, metadata, _config ->
            send(test_pid, {:probe_telemetry, event, measurements, metadata})
          end,
          nil
        )

      on_exit(fn -> :telemetry.detach(handler_id) end)

      start_supervised!(BusProbe)

      assert :ok = JidoAdapter.publish("fixture.bus_probe", %{"test_pid" => test_pid, "n" => 1})
      assert_receive {:handled, 1}, 1_000

      bus_id = JidoAdapter.bus_name()
      assert :ok = Supervisor.terminate_child(Cgc2046.Supervisor, bus_id)

      # 退避链 100+200+400ms 耗尽 → 一次性 give_up（retries == max == 3）
      assert_receive(
        {:probe_telemetry, [:cgc2046, :signal_subscriber, :give_up], %{retries: 3},
         %{subscriber: "BusProbe"}},
        2_000
      )

      # 探测往返（bus 仍缺）不重复 give_up
      refute_receive {:probe_telemetry, [:cgc2046, :signal_subscriber, :give_up], _, _}, 300

      subscriber_pid = Process.whereis(BusProbe)
      state = :sys.get_state(subscriber_pid)
      assert state.bus_probing == true
      assert state.bus_retries == 3
      assert state.subscriptions == %{}

      # bus 回归 → 探测周期内自动恢复（recovered 恰一次）
      assert {:ok, _pid} = Supervisor.restart_child(Cgc2046.Supervisor, bus_id)

      assert_receive(
        {:probe_telemetry, [:cgc2046, :signal_subscriber, :recovered], %{count: 1},
         %{subscriber: "BusProbe", was_probe: true}},
        2_000
      )

      state = :sys.get_state(subscriber_pid)
      assert state.bus_probing == false
      assert state.bus_retries == 0
      assert length(Map.keys(state.subscriptions)) == 1

      # 投递恢复
      publish_until_handled("fixture.bus_probe", 2)
    after
      _ = Supervisor.restart_child(Cgc2046.Supervisor, JidoAdapter.bus_name())
      wait_until(&app_subscribers_resubscribed?/0)
    end

    test "bus 持续缺席：多次探测往返无重复 give_up、bus_retries 不递增" do
      test_pid = self()
      handler_id = "bus-probe-nostorm-#{System.unique_integer([:positive])}"

      :ok =
        :telemetry.attach_many(
          handler_id,
          [[:cgc2046, :signal_subscriber, :give_up]],
          fn event, measurements, metadata, _config ->
            send(test_pid, {:probe_telemetry, event, measurements, metadata})
          end,
          nil
        )

      on_exit(fn -> :telemetry.detach(handler_id) end)

      start_supervised!(BusProbe)
      bus_id = JidoAdapter.bus_name()
      assert :ok = Supervisor.terminate_child(Cgc2046.Supervisor, bus_id)

      # 进入探测模式：恰一次 give_up
      assert_receive {:probe_telemetry, [:cgc2046, :signal_subscriber, :give_up], %{retries: 3},
                      _},
                     2_000

      subscriber_pid = Process.whereis(BusProbe)

      # 跨多次探测往返（~5 × 200ms），bus 持续缺席：无重复 give_up 事件
      Process.sleep(1_000)
      refute_receive {:probe_telemetry, [:cgc2046, :signal_subscriber, :give_up], _, _}, 100

      state = :sys.get_state(subscriber_pid)
      assert state.bus_probing == true
      assert state.bus_retries == 3
    after
      _ = Supervisor.restart_child(Cgc2046.Supervisor, JidoAdapter.bus_name())
      wait_until(&app_subscribers_resubscribed?/0)
    end
  end

  # #244 B2：探测测试 after 恢复 bus 后须等待 8 个 app 级订阅方全部重订阅完成
  # 再返回——terminate_child 期间它们与 fixture 一同进入退避链，restart_child
  # 后订阅窗口（subscriptions == %{}）最长可达退避 cap 级；smoke 无重试断言
  # map_size > 0（async: false 串行），seed 排到紧随即 flake。列表与 smoke
  # @subscribers 同源，同步维护。超时（wait_until 5s 预算）flunk 暴露真问题。
  defp app_subscribers_resubscribed? do
    Enum.all?(
      [
        Cgc2046.Notifications.Subscriber,
        Cgc2046.Events.SpeakerSubscriber,
        Cgc2046.Sponsorship.SponsorshipEndedSubscriber,
        Cgc2046.Learning.LearningInstantiator,
        Cgc2046.Curriculum.Instantiator,
        Cgc2046.Curriculum.Reaper,
        Cgc2046.Workflows.ShareSchemeInstantiator,
        Cgc2046.Admission.Workers.OfferingCancelRefundWorker
      ],
      fn module ->
        case Process.whereis(module) do
          nil ->
            false

          pid ->
            # 重订阅进程在监督树 restart 竞态窗口可能瞬时不存活，rescue 归一化 false
            try do
              :sys.get_state(pid).subscriptions |> map_size() > 0
            rescue
              _ -> false
            end
        end
      end
    )
  end

  defp publish_until_handled(type, n, attempts \\ 20)

  defp publish_until_handled(_type, _n, 0),
    do: flunk("resubscribed forwarder never received signal")

  defp publish_until_handled(type, n, attempts) do
    assert :ok = JidoAdapter.publish(type, %{"test_pid" => self(), "n" => n})

    receive do
      {:handled, ^n} -> :ok
    after
      200 -> publish_until_handled(type, n, attempts - 1)
    end
  end

  defp publish_bus_restart_until_handled(n, attempts \\ 30)

  defp publish_bus_restart_until_handled(_n, 0),
    do: flunk("bus restart resubscribe never recovered delivery")

  # bus 重启窗口内 publish 可能 {:error, :not_found}（supervisor 尚未拉起 bus）：
  # 与 SignalPublishWorker Oban 重试同构，不视为失败，继续轮询。

  defp publish_bus_restart_until_handled(n, attempts) do
    case JidoAdapter.publish("fixture.bus_restart", %{"test_pid" => self(), "n" => n}) do
      :ok ->
        receive do
          {:handled, "fixture.bus_restart", ^n} -> :ok
        after
          200 -> publish_bus_restart_until_handled(n, attempts - 1)
        end

      {:error, _reason} ->
        Process.sleep(200)
        publish_bus_restart_until_handled(n, attempts - 1)
    end
  end

  defp wait_until(fun, attempts \\ 50)

  defp wait_until(_fun, 0), do: flunk("condition never met within wait_until budget")

  defp wait_until(fun, attempts) do
    if fun.() do
      :ok
    else
      Process.sleep(100)
      wait_until(fun, attempts - 1)
    end
  end
end
