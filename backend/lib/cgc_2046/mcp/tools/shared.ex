defmodule Cgc2046.Mcp.Tools.Shared do
  @moduledoc false

  def attrs(params, fields) do
    Enum.reduce(fields, %{}, fn field, acc ->
      value = Map.get(params, Atom.to_string(field), Map.get(params, field))
      if is_nil(value), do: acc, else: Map.put(acc, field, value)
    end)
  end

  def parse_datetime(nil), do: nil
  def parse_datetime(%DateTime{} = value), do: value

  def parse_datetime(value) when is_binary(value) do
    case DateTime.from_iso8601(value) do
      {:ok, date_time, _offset} -> date_time
      _ -> value
    end
  end

  def parse_datetime(value), do: value
end
