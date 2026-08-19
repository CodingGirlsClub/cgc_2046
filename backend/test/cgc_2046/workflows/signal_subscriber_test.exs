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
    BusRestart,
    ClaimAfter,
    ClaimFirst,
    ClaimInHandle,
    ClaimInHandleIncomplete,
    Crash,
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

    test "真实订阅方（NotificationSubscriber）：bus :kill 重启后投递恢复（真实双证）" do
      # enrollment.submitted 非 request 策略 → handle 落 :ok 无副作用分支：
      # 只经 claim（SignalIdempotency 写，shared sandbox 覆盖）+ telemetry 可观察
      test_pid = self()

      :telemetry.attach(
        "bus-restart-ns",
        [:cgc2046, :signal, :deliver],
        fn _event, _measurements, meta, _config ->
          if meta[:subscriber] == "NotificationSubscriber" do
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
