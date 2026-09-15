defmodule Cgc2046.Events.ReadsArchivedInitiativeEvent do
  @moduledoc "Anonymous archived access is limited to Initiative-linked detail reads."
  use Ash.Policy.FilterCheck
  def describe(_), do: "public archived Initiative event detail"

  def filter(_actor, %{query: %{action: %{name: action}}}, _opts)
      when action in [:get_by_id, :get_by_slug] do
    expr(
      visibility == :public and status in [:closed, :cancelled] and
        exists(initiative, status in [:open, :closed])
    )
  end

  def filter(_, _, _), do: false
end
