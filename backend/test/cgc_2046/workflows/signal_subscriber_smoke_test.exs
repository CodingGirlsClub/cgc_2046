defmodule Cgc2046.Workflows.SignalSubscriberSmokeTest do
  @moduledoc """
  #134-① 应用级订阅方冒烟测试（随 E-10 #125 落地，D6）。

  八应用级订阅方（监督树启动）的 init → subscribe 组合断言：
  - 进程存活（`Process.alive?`——订阅失败即停会暴露为进程不存在/死亡）；
  - `:sys.get_state/1` 的 `subscriptions` 非空；
  - 实际订阅 pattern 集与 `patterns/0`（use 骨架注入的声明集）一致。

  不投真信号、不触 DB：纯进程级断言，无副作用（async: false 防与其它
  应用级状态测试并发互扰）。

  Flaky 说明（#270）：async: false 管不住别的并发测试 kill 信号总线——
  bus down 后订阅方进入重订阅窗口，subscriptions 短暂清空，窗口内断言
  必败。故断言经 await_stable/2 轮询等待窗口闭合，超时才判失败。
  """

  use ExUnit.Case, async: false

  @subscribers [
    Cgc2046.Notifications.Subscriber,
    Cgc2046.SpeakerSubscriber,
    Cgc2046.Sponsorship.SponsorshipEndedSubscriber,
    Cgc2046.Workflows.LearningInstantiator,
    Cgc2046.Curriculum.Instantiator,
    Cgc2046.Curriculum.Reaper,
    Cgc2046.Workflows.ShareSchemeInstantiator,
    Cgc2046.Workers.OfferingCancelRefundWorker
  ]

  describe "应用级订阅方 init → subscribe 冒烟（#134-①）" do
    test "八订阅方进程存活且订阅集与 patterns/0 一致" do
      Enum.each(@subscribers, fn module ->
        case await_stable(module) do
          :ok -> :ok
          {:error, reason} -> flunk(reason)
        end
      end)
    end
  end

  # 25 × 200ms = 5s 窗口：resubscribe backoff 实测百毫秒级闭合，余量充足
  defp await_stable(module, attempts \\ 25)

  defp await_stable(module, 0),
    do: {:error, "#{inspect(module)} 等待 5s 后仍不稳定：#{last_error(module)}"}

  defp await_stable(module, attempts) do
    case check_subscriber(module) do
      :ok ->
        :ok

      {:error, _} ->
        Process.sleep(200)
        await_stable(module, attempts - 1)
    end
  end

  defp last_error(module) do
    case check_subscriber(module) do
      :ok -> "状态已恢复（超时瞬间通过，疑似临界竞态）"
      {:error, reason} -> reason
    end
  end

  defp check_subscriber(module) do
    with {:ok, pid} <- fetch_alive_pid(module),
         {:ok, subscriptions} <- fetch_subscriptions(pid, module) do
      check_patterns(subscriptions, module)
    end
  end

  defp fetch_alive_pid(module) do
    case Process.whereis(module) do
      nil ->
        {:error, "#{inspect(module)} 未启动（订阅失败即停会被监督树暴露）"}

      pid when is_pid(pid) ->
        if Process.alive?(pid), do: {:ok, pid}, else: {:error, "#{inspect(module)} 进程已死"}
    end
  end

  defp fetch_subscriptions(pid, module) do
    subscriptions = pid |> :sys.get_state() |> Map.get(:subscriptions, %{})

    if map_size(subscriptions) > 0,
      do: {:ok, subscriptions},
      else: {:error, "#{inspect(module)} 订阅为空"}
  end

  defp check_patterns(subscriptions, module) do
    expected = module.patterns()

    cond do
      map_size(subscriptions) != length(expected) ->
        {:error, "#{inspect(module)} 订阅数与声明 pattern 数不一致"}

      Enum.sort(Map.values(subscriptions)) != Enum.sort(expected) ->
        {:error, "#{inspect(module)} 订阅 pattern 集与 patterns/0 不一致"}

      true ->
        :ok
    end
  end
end
