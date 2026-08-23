defmodule Cgc2046.Mcp.Tools.PublicOffering do
  @moduledoc """
  公开浏览两工具（list_public_offerings / get_public_offering，U2 #293）的共享
  参数解析。

  两工具的 `kind` 参数语义同源：event | course；缺省 nil = 不窄化（list = 两者；
  get = 按 event → course 顺序查找）。
  """

  @doc """
  解析 kind 参数：`{:ok, :event | :course | nil} | {:error, String.t()}`。
  """
  @spec parse_kind(term()) :: {:ok, :event | :course | nil} | {:error, String.t()}
  def parse_kind(nil), do: {:ok, nil}
  def parse_kind("event"), do: {:ok, :event}
  def parse_kind("course"), do: {:ok, :course}

  def parse_kind(other),
    do: {:error, "invalid kind: #{inspect(other)} (expected event | course)"}
end
