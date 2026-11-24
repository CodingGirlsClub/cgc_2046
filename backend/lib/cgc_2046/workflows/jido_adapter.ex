defmodule Cgc2046.Workflows.JidoAdapter do
  @moduledoc """
  `Jido.Signal.Bus` 信号总线适配器（ADR-0002 决策 5 的异步事件通道）。

  所有 `Jido.Signal` / `Jido.Signal.Bus` 内部 API 经本模块包装，产品层只依赖本模块的
  公开函数，不直接触碰 `Jido.Signal` 内部结构：

  - `bus_name/0` / `whereis_bus/0`：总线进程名（`:cgc_workflow_bus`）与 pid 解析
  - `publish/2`：发布信号到总线
  - `subscribe/2,3`：以崩溃隔离 forwarder 订阅总线信号
  - `drain_forwarders/1,2`：在 bus 重启或订阅回收时优雅 drain forwarder 进程
  """

  @bus_name :cgc_workflow_bus

  @doc "信号总线进程名（Application 启动时挂载）"
  def bus_name, do: @bus_name

  @doc """
  发布信号到总线（异步事件通道，ADR-0002 决策 5 的 2 成异步路径）。

  `signal_type` 为字符串（如 `"workflow.run.completed"`），`payload` 为 map。
  返回 `:ok` 或 `{:error, reason}`。
  """
  @spec publish(String.t(), map()) :: :ok | {:error, term()}
  def publish(signal_type, payload) when is_binary(signal_type) and is_map(payload) do
    with {:ok, signal} <- Jido.Signal.new(signal_type, payload, source: "/cgc/workflows") do
      case Jido.Signal.Bus.publish(@bus_name, [signal]) do
        {:ok, _} -> :ok
        {:error, reason} -> {:error, reason}
      end
    end
  end

  @doc """
  订阅信号（异步消费；plan 2026-08-14-003 D1 唯一语义 = 崩溃隔离）。

  `pattern` 为路径模式（如 `"workflow.run.*"`）；`fun` 为
  `(signal_type, data) -> any`——Jido.Signal struct 在本 adapter 解包，不外泄
  （Jido 升级只影响本模块）。转发进程 `spawn` 接收总线投递并调用 `fun`，
  与调用者崩溃隔离（历史 `spawn_link` 连坐变体已删：转发进程崩溃连带调用者
  死亡，测试沙箱下连锁重启耗尽监督预算——E-7 #122 实锤）。反向收割由转发
  进程 monitor 调用者保证：调用者死亡 → 转发进程自退，不留僵尸订阅消费
  总线投递（spawn_link 变体的隐性清道夫语义，崩溃隔离后必须显式补回）。

  调用者持有返回的 monitor：转发进程死亡收 `{:DOWN, ref, :process, pid, reason}`
  后自行重建订阅（`Cgc2046.Workflows.SignalSubscriber` 骨架统一持有）。返回
  `{:ok, subscription_id, monitor_ref, forwarder_pid}`——forwarder pid 供骨架在
  bus 重启时显式回收旧转发进程（spawn 无 link，不回收则泄漏；#120），或
  `{:error, reason}`（bus 未注册时为 `:not_found`）。

  `bus_pid` 显式指定时按 pid 而非名字订阅（advisor M2）：订阅方骨架先
  `whereis_bus` → `Process.monitor(pid)` → 按 pid 订阅，保证订阅行与 monitor
  落在同一 bus incarnation——按名字订阅会在 subscribe → whereis 间隙遭遇
  incarnation 替换（订阅落 B1、monitor B2 → B1 死亡无感知，静默失聪）。
  """
  @spec subscribe(String.t(), (String.t(), map() -> any())) ::
          {:ok, term(), reference(), pid()} | {:error, term()}
  @spec subscribe(String.t(), (String.t(), map() -> any()), pid() | nil) ::
          {:ok, term(), reference(), pid()} | {:error, term()}
  def subscribe(pattern, fun, bus_pid \\ nil)
      when is_binary(pattern) and is_function(fun, 2) and (is_pid(bus_pid) or is_nil(bus_pid)) do
    caller = self()
    subscriber = spawn(fn -> forward_loop(fun, caller) end)
    monitor_ref = Process.monitor(subscriber)
    # 按名字（nil）或显式 pid 解析 bus（jido bus_call_target 对 pid 直通）
    bus = if is_pid(bus_pid), do: bus_pid, else: @bus_name

    case Jido.Signal.Bus.subscribe(bus, pattern,
           dispatch: {:pid, target: subscriber, delivery_mode: :async}
         ) do
      {:ok, subscription_id} ->
        {:ok, subscription_id, monitor_ref, subscriber}

      {:error, reason} ->
        # 订阅失败：回收无信号来源的转发进程，避免泄漏
        Process.demonitor(monitor_ref, [:flush])
        Process.exit(subscriber, :kill)
        {:error, reason}
    end
  end

  @doc """
  解析信号总线进程 pid（#120：订阅方骨架 monitor bus、bus 重启后重订阅用）。

  返回 `{:ok, pid}` 或 `{:error, :not_found}`（bus 未注册——启动间隙或已死）。
  """
  @spec whereis_bus() :: {:ok, pid()} | {:error, :not_found}
  def whereis_bus, do: Jido.Signal.Util.whereis(@bus_name)

  @drain_default_timeout_ms 5_000

  @doc """
  drain 协议优雅回收 forwarder（#245）：spawn 一次性 waiter，对每个 pid
  先 `Process.monitor` 再投递 `:reclaim`（顺序保证 pid 先死也能收 DOWN），
  等全部 forwarder 处理完在途投递后自退；超时（默认 #{@drain_default_timeout_ms}ms，
  可注入缩短供测试）仍未退者 `Process.exit(pid, :kill)` 强杀兜底。立即返回
  waiter pid 不阻塞调用方——bus DOWN 恢复路径（重订阅退避）不被在途投递拖住。

  截断窗口闭合的机制前提：claim 与 effects 在 forwarder 进程内**同步**执行
  （`SignalSubscriber.do_run` 内联 claim→handle），forwarder 在 `fun.()`
  执行中收不到消息——`:reclaim` 落邮箱仅在 fun 跑完、循环回到 `receive` 时
  被处理，「处理 :reclaim 前」=「claim/effects 要么都完成要么都没开始」。
  若未来 effects 异步化，此前提失效，drain 降级为超时强杀的旧 kill 行为
  （不劣化现状）。

  残余窗口：fun 卡死超过 `timeout` 仍被强杀截断；`:reclaim` 排在深 signal
  backlog 后（逐条执行 fun 聚合耗时超 `timeout`）同样会被强杀——概率缩小
  非零，兜底仍是 SignalIdempotency claim + E-10 对账。
  """
  @spec drain_forwarders([pid()], pos_integer()) :: pid()
  def drain_forwarders(pids, timeout \\ @drain_default_timeout_ms)
      when is_list(pids) and is_integer(timeout) and timeout > 0 do
    spawn(fn ->
      pending =
        Map.new(pids, fn pid ->
          ref = Process.monitor(pid)
          send(pid, :reclaim)
          {ref, pid}
        end)

      deadline = System.monotonic_time(:millisecond) + timeout
      await_drain(pending, deadline)
    end)
  end

  # 等全部 forwarder 退出（自退或强杀后）。入口快路：pending 空即收工
  # （drain_forwarders([]) 时 waiter 不空躺 timeout）；到 deadline 仍有
  # 未退者（fun 卡死/消息被业务 receive 吞掉/backlog 聚合超时）强杀残余——
  # kill 后 monitor 的 DOWN 必然到达，转入无 deadline 收割，waiter 必退不泄漏。
  defp await_drain(pending, _deadline) when map_size(pending) == 0, do: :ok

  defp await_drain(pending, deadline) do
    remaining = deadline - System.monotonic_time(:millisecond)

    if remaining <= 0 do
      Enum.each(pending, fn {_ref, pid} -> Process.exit(pid, :kill) end)
      await_downs(pending)
    else
      receive do
        {:DOWN, ref, :process, _pid, _reason} ->
          case Map.pop(pending, ref) do
            {nil, _} -> await_drain(pending, deadline)
            {_pid, rest} -> if map_size(rest) == 0, do: :ok, else: await_drain(rest, deadline)
          end
      after
        remaining ->
          Enum.each(pending, fn {_ref, pid} -> Process.exit(pid, :kill) end)
          await_downs(pending)
      end
    end
  end

  defp await_downs(pending) do
    if map_size(pending) == 0 do
      :ok
    else
      receive do
        {:DOWN, ref, :process, _pid, _reason} ->
          await_downs(Map.delete(pending, ref))
      end
    end
  end

  defp forward_loop(fun, caller) do
    caller_ref = Process.monitor(caller)

    forward_loop(fun, caller, caller_ref)
  end

  defp forward_loop(fun, caller, caller_ref) do
    receive do
      # 订阅方进程已死：转发进程自退（残余总线路由指向死 pid，投递为 no-op）
      {:DOWN, ^caller_ref, :process, ^caller, _reason} ->
        :ok

      # #245 drain：骨架回收时请求自退。fun 执行中本消息落邮箱，fun 跑完
      # 回到 receive 才处理——在途投递（claim+effects 同步链）不被截断。
      :reclaim ->
        :ok

      {:signal, signal} ->
        fun.(Map.get(signal, :type), Map.get(signal, :data) || %{})
        forward_loop(fun, caller, caller_ref)

      _other ->
        forward_loop(fun, caller, caller_ref)
    end
  end
end
