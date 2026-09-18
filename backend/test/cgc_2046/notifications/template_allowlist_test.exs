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

  # #546 核销码通知：17 → 18；#585 管理侧成班结果：18 → 19
  @expected_size 19

  test "wechat 模板 env 四处名单集合完全一致（19 键）" do
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

  # 名单里的键名（去重 + 排序）；同文件多处出现（workflow 循环 + env）自动收敛
  defp keys_in(path) do
    path
    |> File.read!()
    |> then(&Regex.scan(~r/WECHAT_MP_TEMPLATE_[A-Z0-9_]+/, &1))
    |> List.flatten()
    |> Enum.uniq()
    |> Enum.sort()
  end
end
