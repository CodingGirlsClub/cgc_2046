defmodule Cgc2046.MiniprogramFixtures.Barrier do
  @moduledoc """
  并发栅栏：N 个并发调用在 stub 内对齐后才各自返回，制造 find-or-create 真实竞态窗口。

  GenServer 延迟应答实现——第 N 个到达者一次性放行全部等待者（无轮询、无 sleep）。
  若某参与者未到达，`Task.await_many` 超时使测试失败（不会静默放行弱化竞态）。

  使用：`start_supervised!({Cgc2046.MiniprogramFixtures.Barrier, n})`，
  配合 `Cgc2046.MiniprogramFixtures.barrier_wrap/1` 包装 Req.Test 响应构造器。
  """
  use GenServer

  def start_link(n), do: GenServer.start_link(__MODULE__, n)

  @doc "到达栅栏；阻塞至全部 N 个参与者到达后返回 :ok。"
  def arrive(pid), do: GenServer.call(pid, :arrive, :infinity)

  @impl true
  def init(n), do: {:ok, {0, n, []}}

  @impl true
  def handle_call(:arrive, from, {count, n, waiting}) do
    count = count + 1

    if count >= n do
      Enum.each([from | waiting], &GenServer.reply(&1, :ok))
      {:noreply, {count, n, []}}
    else
      {:noreply, {count, n, [from | waiting]}}
    end
  end
end
