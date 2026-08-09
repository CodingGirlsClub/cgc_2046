defmodule Cgc2046.Mcp.PendingOperation.EffectiveStatus do
  @moduledoc """
  读时派生过期状态：pending 且 expires_at < now 视为 "expired"（不落库）。
  显式终结状态（confirmed/cancelled）保持原样。
  """
  use Ash.Resource.Calculation

  @impl true
  def calculate(records, _opts, _context) do
    now = DateTime.utc_now()

    Enum.map(records, fn op ->
      if op.status == :pending && DateTime.compare(op.expires_at, now) == :lt do
        "expired"
      else
        to_string(op.status)
      end
    end)
  end
end
