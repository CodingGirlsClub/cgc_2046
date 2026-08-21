defmodule Cgc2046.NoEagerDslTimestampTest do
  @moduledoc """
  源码门禁：禁止 Ash DSL `set_attribute` 参数里 eager 调用当前时间函数。

  DSL 宏参数在模块编译期求值——`set_attribute(:x, DateTime.utc_now())` 会把
  时间冻结成编译期常量（= release 构建时刻）。approval_deadline 曾因此埋雷：
  构建 7 天后所有新申请「创建即过期」，审批闭环静默死亡（2026-08-21 实证：
  beam 编译时刻与测试失败值反推时刻分秒吻合）。

  行为测试抓不住这类回归——CI 每次新鲜编译，deadline ≈ now + 7d 恒绿；
  只有陈旧 beam 才显形。故以源码扫描在提交时拦下。

  合法形态：捕获 `&DateTime.utc_now/0`；需要计算的值提取命名函数
  （如 `&Cgc2046.ApprovalDeadline.default_deadline_from_now/0`）。内联
  `fn -> DateTime.utc_now() end` 也会被本门禁命中——统一用捕获，宁严勿漏。
  """
  use ExUnit.Case, async: true

  # set_attribute( 到时间函数调用之间无右括号 = 该调用位于其参数表达式内
  # （跨行有效：[^)] 含换行；捕获形态 &DateTime.utc_now/0 无 () 不命中）
  @eager ~r/set_attribute\([^)]*\b(?:NaiveDateTime\.utc_now|DateTime\.utc_now|Date\.utc_today)\(\)/

  test "lib 下无 set_attribute eager 当前时间调用（编译期冻结坑）" do
    offenders =
      Path.expand("../../lib", __DIR__)
      |> Path.join("**/*.ex")
      |> Path.wildcard()
      |> Enum.filter(&(File.read!(&1) =~ @eager))

    assert offenders == [],
           "以下文件在 set_attribute 参数里 eager 调用当前时间（会被冻结为编译期常量，" <>
             "改用 & 捕获形态）：\n" <> Enum.map_join(offenders, "\n", &Path.relative_to_cwd/1)
  end
end
