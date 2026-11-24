defmodule Cgc2046.Workflows.JidoAdapterTest do
  use Cgc2046Web.ConnCase, async: false

  alias Cgc2046.Workflows.JidoAdapter

  describe "bus_name / whereis_bus" do
    test "whereis_bus returns running signal bus pid" do
      assert JidoAdapter.bus_name() == :cgc_workflow_bus
      assert {:ok, pid} = JidoAdapter.whereis_bus()
      assert is_pid(pid)
      assert Process.alive?(pid)
    end
  end

  describe "publish/subscribe" do
    test "subscriber receives published signal (unpacked type + data, no struct leak)" do
      parent = self()

      assert {:ok, _sub_id, _monitor_ref, _forwarder_pid} =
               JidoAdapter.subscribe("workflow.run.*", fn type, data ->
                 send(parent, {:signal, type, data})
               end)

      assert :ok = JidoAdapter.publish("workflow.run.completed", %{"run_id" => "r1"})

      assert_receive {:signal, "workflow.run.completed", %{"run_id" => "r1"}}, 1_000
    end
  end

  describe "drain_forwarders（#245）" do
    test "空闲 forwarder：收 :reclaim 自退（:normal），waiter 快速收工不泄漏" do
      {:ok, _sub_id, _monitor_ref, forwarder} =
        JidoAdapter.subscribe("fixture.drain_idle", fn _type, _data -> :ok end)

      forwarder_ref = Process.monitor(forwarder)
      waiter = JidoAdapter.drain_forwarders([forwarder])
      waiter_ref = Process.monitor(waiter)

      assert_receive {:DOWN, ^forwarder_ref, :process, ^forwarder, :normal}, 2_000
      assert_receive {:DOWN, ^waiter_ref, :process, ^waiter, _reason}, 2_000
    end

    test "fun 永久挂起（:reclaim 不匹配留在邮箱）：超时强杀 forwarder，waiter 必退" do
      # 注入 200ms 超时压时序；fun 的 receive 只匹配永不到来的消息——forwarder
      # 卡在 fun 里收不到 :reclaim，drain 只能强杀兜底（残余窗口行为取证）
      {:ok, _sub_id, _monitor_ref, forwarder} =
        JidoAdapter.subscribe("fixture.drain_timeout", fn _type, _data ->
          receive(do: ({:never_coming, _} -> :ok))
        end)

      assert :ok = JidoAdapter.publish("fixture.drain_timeout", %{"n" => 1})

      forwarder_ref = Process.monitor(forwarder)
      waiter = JidoAdapter.drain_forwarders([forwarder], 200)
      waiter_ref = Process.monitor(waiter)

      assert_receive {:DOWN, ^forwarder_ref, :process, ^forwarder, :killed}, 2_000
      assert_receive {:DOWN, ^waiter_ref, :process, ^waiter, _reason}, 2_000
    end

    test "空 pid 列表：waiter 立即收工，不空躺 timeout" do
      waiter = JidoAdapter.drain_forwarders([])
      ref = Process.monitor(waiter)

      # 无 forwarder 可等：快路立即退出（2s 预算 < 默认 5s timeout——空躺即红）
      assert_receive {:DOWN, ^ref, :process, ^waiter, _reason}, 2_000
    end
  end
end
