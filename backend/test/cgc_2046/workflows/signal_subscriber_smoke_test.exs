defmodule Cgc2046.Workflows.SignalSubscriberSmokeTest do
  @moduledoc """
  #134-① 应用级订阅方冒烟测试（随 E-10 #125 落地，D6）。

  八应用级订阅方（监督树启动）的 init → subscribe 组合断言：
  - 进程存活（`Process.alive?`——订阅失败即停会暴露为进程不存在/死亡）；
  - `:sys.get_state/1` 的 `subscriptions` 非空；
  - 实际订阅 pattern 集与 `patterns/0`（use 骨架注入的声明集）一致。

  不投真信号、不触 DB：纯进程级断言，无副作用（async: false 防与其它
  应用级状态测试并发互扰）。
  """

  use ExUnit.Case, async: false

  @subscribers [
    Cgc2046.NotificationSubscriber,
    Cgc2046.SpeakerSubscriber,
    Cgc2046.Events.SponsorshipEndedSubscriber,
    Cgc2046.Workflows.LearningInstantiator,
    Cgc2046.Workflows.ResearchInstantiator,
    Cgc2046.Workflows.ResearchRunReaper,
    Cgc2046.Workflows.ShareSchemeInstantiator,
    Cgc2046.Workers.EventCancelRefundWorker
  ]

  describe "应用级订阅方 init → subscribe 冒烟（#134-①）" do
    test "八订阅方进程存活且订阅集与 patterns/0 一致" do
      Enum.each(@subscribers, fn module ->
        pid = Process.whereis(module)
        assert pid != nil, "#{inspect(module)} 未启动（订阅失败即停会被监督树暴露）"
        assert Process.alive?(pid), "#{inspect(module)} 进程已死"

        state = :sys.get_state(pid)
        subscriptions = Map.get(state, :subscriptions, %{})
        assert map_size(subscriptions) > 0, "#{inspect(module)} 订阅为空"

        assert map_size(subscriptions) == length(module.patterns()),
               "#{inspect(module)} 订阅数与声明 pattern 数不一致"

        assert Enum.sort(Map.values(subscriptions)) == Enum.sort(module.patterns()),
               "#{inspect(module)} 订阅 pattern 集与 patterns/0 不一致"
      end)
    end
  end
end
