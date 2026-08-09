defmodule Cgc2046.Mcp.RedactTest do
  @moduledoc "参数脱敏（D-D8）：snake_case / camelCase / 嵌套 / 边界不误伤"
  use ExUnit.Case, async: true

  alias Cgc2046.Mcp.Redact

  test "snake_case 后缀与精确键命中" do
    assert Redact.call(%{
             "api_key" => "k1",
             "user_token" => "t",
             "password" => "p",
             "nested" => %{"refresh_token" => "r", "name" => "ok"}
           }) == %{
             "api_key" => "[REDACTED]",
             "user_token" => "[REDACTED]",
             "password" => "[REDACTED]",
             "nested" => %{"refresh_token" => "[REDACTED]", "name" => "ok"}
           }
  end

  test "camelCase 后缀命中（apiToken / userPassword / authToken）" do
    assert Redact.call(%{
             "apiToken" => "t",
             "userPassword" => "p",
             "authToken" => "a"
           }) == %{
             "apiToken" => "[REDACTED]",
             "userPassword" => "[REDACTED]",
             "authToken" => "[REDACTED]"
           }
  end

  test "不误伤：纯小写非敏感词、仅前缀含敏感词、原子键" do
    assert Redact.call(%{
             "monkey" => "ok",
             "tokenizer" => "ok",
             "name" => "ok",
             email: "a@b.com"
           }) == %{
             "monkey" => "ok",
             "tokenizer" => "ok",
             "name" => "ok",
             email: "a@b.com"
           }
  end

  test "list 递归与非 map 原样" do
    assert Redact.call([%{"secret" => "s"}, %{"x" => 1}]) == [
             %{"secret" => "[REDACTED]"},
             %{"x" => 1}
           ]

    assert Redact.call("plain") == "plain"
    assert Redact.call(nil) == nil
  end
end
