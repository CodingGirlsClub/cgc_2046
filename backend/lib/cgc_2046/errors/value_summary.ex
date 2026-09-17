defmodule Cgc2046.Errors.ValueSummary do
  @moduledoc """
  `InvalidAttribute` 的 `Value:` 摘要单源（#677 / #680）。

  Ash 的 keyword 错误转换（自定义校验返回 `{:error, field: ..., message: ...}`）
  会无条件带上 `value: nil` + `has_value?: true`，渲染成 `Value: nil`——MCP 出口
  逐叶 `Exception.message/1` 折叠后，agent/用户会误判「服务端把数据读成了 nil」
  （#677 两个 tutor agent 由此盲试数十次的事故源；#680 同族收敛为 0）。

  需要显式 `Ash.Error.Changes.InvalidAttribute.exception(value: ...)`，本模块提供
  摘要口径：**只回显类型与长度，绝不回显内容**（错误体积与用户数据泄露面有界，
  如 `avatar_url` data URL 可达 ~3MB）。

  唯一例外是时间戳：`Offering.ScheduleValidation` 直接回显起止时间 ISO8601
  （错误主体就是这两个值本身、~70B 有界），不塞进 `describe/1`（那只会得到
  `"struct"`，丢失可操作信息）。
  """

  @spec describe(term()) :: String.t()
  def describe(value) when is_list(value), do: "list(#{length(value)})"
  def describe(value) when is_map(value), do: "map"
  def describe(value) when is_binary(value), do: "string(#{byte_size(value)})"
  def describe(nil), do: "nil"
  def describe(value) when is_boolean(value), do: "boolean"
  def describe(value) when is_integer(value), do: "integer"
  def describe(value) when is_float(value), do: "float"
  def describe(value) when is_atom(value), do: "atom"
  def describe(_value), do: "其他类型"
end
