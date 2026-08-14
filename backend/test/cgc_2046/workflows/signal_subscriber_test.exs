defmodule Cgc2046.Workflows.SignalSubscriberTest do
  @moduledoc """
  SignalSubscriber 骨架单测（异步链路深化 PR-B；plan 2026-08-14-003 验收项）。

  覆盖：三策略 claim 时机（claim_first / claim_after_effects / state_based）、
  deliver/2 同步入口、缺幂等键契约、rescue 壳、订阅失败即崩（Q3）、
  forwarder DOWN 自动重订阅（D3）。

  策略类测试只走 deliver/2（纯同步，不触总线）；生命周期测试用真实总线
  （JidoAdapter.publish → forwarder → run/3——与生产同码）。
  """

  use Cgc2046.DataCase, async: false

  alias Cgc2046.Workflows.{JidoAdapter, SignalIdempotency, SignalSubscriber}

  require Ash.Query

  # --- 测试订阅方（唯一职责：向测试进程报告被调用；signal type 独占不与生产冲突） ---

  defmodule ClaimFirstFixture do
    use Cgc2046.Workflows.SignalSubscriber,
      patterns: ["fixture.claim_first"],
      idempotency: :claim_first

    @impl Cgc2046.Workflows.SignalSubscriber
    def handle(_type, data) do
      send(data["test_pid"], {:handled, data["n"]})
      :ok
    end
  end

  defmodule ClaimAfterFixture do
    use Cgc2046.Workflows.SignalSubscriber,
      patterns: ["fixture.claim_after"],
      idempotency: :claim_after_effects

    @impl Cgc2046.Workflows.SignalSubscriber
    def handle(_type, %{"fail" => true} = data) do
      send(data["test_pid"], {:failed_effect, data["n"]})
      {:error, :boom}
    end

    def handle(_type, data) do
      send(data["test_pid"], {:handled, data["n"]})
      :ok
    end
  end

  defmodule StateBasedFixture do
    use Cgc2046.Workflows.SignalSubscriber,
      patterns: ["fixture.state_based"],
      idempotency: :state_based

    @impl Cgc2046.Workflows.SignalSubscriber
    def handle(_type, data) do
      send(data["test_pid"], {:handled, data["n"]})
      :ok
    end
  end

  defmodule CrashFixture do
    use Cgc2046.Workflows.SignalSubscriber,
      patterns: ["fixture.crash"],
      idempotency: :state_based

    @impl Cgc2046.Workflows.SignalSubscriber
    def handle(_type, %{"raise" => true}), do: raise("boom")

    def handle(_type, data) do
      send(data["test_pid"], {:handled, data["n"]})
      :ok
    end
  end

  defmodule ResubscribeFixture do
    use Cgc2046.Workflows.SignalSubscriber,
      patterns: ["fixture.resubscribe"],
      idempotency: :state_based

    @impl Cgc2046.Workflows.SignalSubscriber
    def handle(_type, data) do
      send(data["test_pid"], {:handled, data["n"]})
      # handle 运行在 forwarder 进程内：自杀模拟 forwarder 崩溃（D3 场景）
      Process.exit(self(), :kill)
    end
  end

  # 路由校验拒绝（连续点）→ JidoAdapter.subscribe 返回 {:error, _} → init 即崩
  defmodule BadPatternFixture do
    use Cgc2046.Workflows.SignalSubscriber,
      patterns: ["fixture..bad"],
      idempotency: :state_based

    @impl Cgc2046.Workflows.SignalSubscriber
    def handle(_type, _data), do: :ok
  end

  describe "claim_first：副作用前 claim（NS/SS/LI 语义）" do
    test "首投 claim 成功 → 执行 handle；重复投递 → :duplicate 不再执行" do
      assert :ok =
               SignalSubscriber.deliver(ClaimFirstFixture, %{
                 type: "fixture.claim_first",
                 data: %{"test_pid" => self(), "n" => 1, "idempotency_key" => "fixture:cf-1"}
               })

      assert_receive {:handled, 1}
      assert claim_keys("fixture.claim_first") == ["fixture:cf-1:claim_first_fixture"]

      assert :duplicate =
               SignalSubscriber.deliver(ClaimFirstFixture, %{
                 type: "fixture.claim_first",
                 data: %{"test_pid" => self(), "n" => 2, "idempotency_key" => "fixture:cf-1"}
               })

      refute_receive {:handled, 2}
      # 唯一索引兜底：重复投递不新增 claim 行
      assert claim_keys("fixture.claim_first") == ["fixture:cf-1:claim_first_fixture"]
    end
  end

  describe "claim_after_effects：全部副作用成功才 claim（SES/RRR 语义）" do
    test "handle 返回 {:error} → 不落 claim（等重投）；{:ok} → 落 claim" do
      assert {:error, :boom} =
               SignalSubscriber.deliver(ClaimAfterFixture, %{
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
               SignalSubscriber.deliver(ClaimAfterFixture, %{
                 type: "fixture.claim_after",
                 data: %{"test_pid" => self(), "n" => 2, "idempotency_key" => "fixture:ca-1"}
               })

      assert_receive {:handled, 2}
      assert claim_keys("fixture.claim_after") == ["fixture:ca-1:claim_after_fixture"]
    end

    test "claim 已存在时副作用照常执行（重放无害，state 守卫是业务侧职责）" do
      for n <- 1..2 do
        assert :ok =
                 SignalSubscriber.deliver(ClaimAfterFixture, %{
                   type: "fixture.claim_after",
                   data: %{"test_pid" => self(), "n" => n, "idempotency_key" => "fixture:ca-2"}
                 })
      end

      assert_receive {:handled, 1}
      assert_receive {:handled, 2}
      assert claim_keys("fixture.claim_after") == ["fixture:ca-2:claim_after_fixture"]
    end
  end

  describe "state_based：不写 claim（RI 语义）" do
    test "每次投递都执行，signal_idempotency 无行" do
      for n <- 1..2 do
        assert :ok =
                 SignalSubscriber.deliver(StateBasedFixture, %{
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
               SignalSubscriber.deliver(ClaimFirstFixture, %{
                 type: "fixture.claim_first",
                 data: %{"test_pid" => self(), "n" => 1}
               })

      assert {:error, :missing_idempotency_key} =
               SignalSubscriber.deliver(ClaimAfterFixture, %{
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
               SignalSubscriber.deliver(CrashFixture, %{
                 type: "fixture.crash",
                 data: %{"raise" => true}
               })

      # 同一模块后续投递不受影响（forwarder 存活）
      assert :ok =
               SignalSubscriber.deliver(CrashFixture, %{
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
      assert {:error, {:subscribe_failed, "fixture..bad", _reason}} =
               BadPatternFixture.start_link(nil)
    end

    test "forwarder 崩溃 → 骨架收 DOWN 自动重订阅 → 信号再次可达" do
      start_supervised!(ResubscribeFixture)

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
end
