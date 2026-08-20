defmodule Cgc2046Web.GraphqlUserTypeContractTest do
  @moduledoc """
  type User GraphQL 暴露面契约（advisor02 M9）。

  password_phone 策略强制 phone public?: true，ash_graphql 自动生成会把
  phone 带进 type User——违反 plan 风险表「不新增 phone 查询出口」。
  此处以 SDL 文本断言锁定：type User 无 phone 字段（mutation 参数不受限）。
  """
  use Cgc2046Web.ConnCase, async: true

  test "type User 不暴露 phone 字段" do
    sdl = File.read!("priv/graphql/schema.graphql")

    start_line = sdl |> String.split("\n") |> Enum.find_index(&(&1 == "type User {"))
    assert start_line != nil, "SDL 中未找到 type User 声明"

    lines = sdl |> String.split("\n") |> Enum.drop(start_line)
    # 块到首个 "}" 行结束
    user_block = lines |> Enum.take_while(&(&1 != "}")) |> Enum.join("\n")

    refute user_block =~ "phone",
           "type User 不得暴露 phone（M9；GraphQL 无新增 phone 查询出口）"
  end
end
