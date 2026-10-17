defmodule Cgc2046.Notifications.TemplateAllowlistTest do
  @moduledoc """
  微信订阅消息模板 env 名单一致性守卫（#606 根因）。

  #606 的失败形态：`runtime.exs` 声明了 17 个 `WECHAT_MP_TEMPLATE_*` 键，而
  `.github/workflows/deploy.yml` 的 fail-closed 循环与 kamal `config/deploy.yml`
  的 env.secret 只登记 10 个、`backend/.env.example` 又是另一套 10 个 —— 新模板
  加了渲染子句也拿不到模板 ID，发送侧 `template_not_configured` 重试耗尽后
  discarded（#606 生产 480 条的成因；#664 起改为终态 discard + Logger.warning，
  不再白重试 3 次，可见性不变）。

  本测试把四处名单钉成同一集合（键名集合，非顺序）：workflow（循环 + env 映射，
  同键出现两次由 uniq 收敛）/ kamal env.secret / .env.example / runtime.exs。
  任一处漏登记或键名拼错即红，不需要部署到生产才发现。
  """

  use ExUnit.Case, async: true

  # 四处名单的真源文件；backend/ 为 mix test 的工作目录
  @workflow "../.github/workflows/deploy.yml"
  @kamal "config/deploy.yml"
  @env_example ".env.example"
  @runtime "config/runtime.exs"

  # #546 核销码通知：17 → 18；#585 管理侧成班结果：18 → 19；#538 主理人移除：19 → 20；
  # U4 志愿者段位通知六模板：20 → 26；wish2 U3 附议 Echo：26 → 27
  @expected_size 27

  test "wechat 模板 env 四处名单集合完全一致（27 键）" do
    sets =
      for path <- [@workflow, @kamal, @env_example, @runtime], into: %{} do
        {path, keys_in(path)}
      end

    # 集合大小先钉死：防「四处一起被删空」也能通过相等断言
    for {path, keys} <- sets do
      assert length(keys) == @expected_size,
             "#{path} 的 WECHAT_MP_TEMPLATE_* 键数为 #{length(keys)}，期望 #{@expected_size}"
    end

    reference = sets[@runtime]

    for path <- [@workflow, @kamal, @env_example] do
      assert sets[path] == reference,
             "#{path} 与 #{@runtime} 的 wechat 模板键集合不一致\n" <>
               "  仅 #{path} 有：#{inspect(sets[path] -- reference)}\n" <>
               "  仅 #{@runtime} 有：#{inspect(reference -- sets[path])}"
    end
  end

  # #371：tt 已接入渲染子句的模板键（当前两个，控制台 2026-10-15 过审）必须在
  # 部署链路三处登记：workflow 注入循环（写 .kamal/secrets）、kamal
  # config/deploy.yml 的 env.secret 名单（决定容器 env）、runtime.exs（消费侧）。
  # tt 侧此前部署链路完全没登记——workflow 把变量写进 .kamal/secrets，但 kamal
  # 只注入 env.secret 名单，容器 env 缺键即静默取不到模板 ID（#974 小红书登录
  # authentication_failed 的同型根因：登记漏一处，事故到真机才现形）。
  # .env.example 不在断言内：它是本地开发文档、非部署面，且受仓库策略保护
  # （agent 不可读写）。新增 tt 模板接入渲染子句时，把键名补进本名单即可。
  @tt_wired ~w(DOUYIN_MP_TEMPLATE_APPROVAL_RESULT DOUYIN_MP_TEMPLATE_EVENT_REMINDER)

  test "tt 已接入的模板键在部署链路三处登记（#371）" do
    for path <- [@workflow, @kamal, @runtime], key <- @tt_wired do
      assert key in keys_in(path, ~r/DOUYIN_MP_TEMPLATE_[A-Z0-9_]+/),
             "#{path} 缺 #{key}——tt 模板 ID 到不了容器（#371，同 #974 形态）"
    end
  end

  # 名单里的键名（去重 + 排序）；同文件多处出现（workflow 循环 + env）自动收敛
  defp keys_in(path, pattern \\ ~r/WECHAT_MP_TEMPLATE_[A-Z0-9_]+/) do
    path
    |> File.read!()
    |> then(&Regex.scan(pattern, &1))
    |> List.flatten()
    |> Enum.uniq()
    |> Enum.sort()
  end
end
