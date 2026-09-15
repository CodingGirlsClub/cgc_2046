defmodule Cgc2046.Mcp.Tools.AdminInitiativeHelpers do
  @moduledoc false

  require Ash.Query

  alias Cgc2046.Initiatives.{Initiative, InitiativeRule}

  def row(initiative, actor) do
    case Ash.load(initiative, :rules, actor: actor) do
      {:ok, loaded} ->
        {:ok,
         %{
           id: loaded.id,
           name: loaded.name,
           slug: loaded.slug,
           hashtag: loaded.hashtag,
           description: loaded.description,
           window_starts_at: loaded.window_starts_at,
           window_ends_at: loaded.window_ends_at,
           status: to_string(loaded.status),
           created_by: loaded.created_by,
           rules: Enum.map(loaded.rules || [], &rule_row/1)
         }}

      {:error, _} ->
        {:error, "failed to load initiative rules"}
    end
  end

  def rule_row(rule) do
    %{
      id: rule.id,
      initiative_id: rule.initiative_id,
      key: to_string(rule.key),
      value: rule.value,
      locked: rule.locked
    }
  end

  def get(id, actor) do
    case Ash.get(Initiative, id, actor: actor) do
      {:ok, nil} -> {:error, "initiative not found"}
      {:ok, initiative} -> row(initiative, actor)
      {:error, _} -> {:error, "failed to load initiative"}
    end
  end

  def attrs(params, fields) do
    Enum.reduce(fields, %{}, fn field, acc ->
      value = Map.get(params, Atom.to_string(field), Map.get(params, field))
      if is_nil(value), do: acc, else: Map.put(acc, field, value)
    end)
  end

  def datetime_attrs(params) do
    [
      {:window_starts_at, parse_datetime(Map.get(params, "window_starts_at"))},
      {:window_ends_at, parse_datetime(Map.get(params, "window_ends_at"))}
    ]
    |> Enum.reject(fn {_key, value} -> is_nil(value) end)
    |> Map.new()
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

  def rule_key(value) when value in ["deposit", "age_gate", "min_participants", "deadline_rule"],
    do: {:ok, String.to_existing_atom(value)}

  def rule_key(_), do: {:error, "invalid rule key"}

  def get_rule(initiative_id, key, actor) do
    InitiativeRule
    |> Ash.Query.for_read(:read)
    |> Ash.Query.filter(initiative_id == ^initiative_id and key == ^key)
    |> Ash.read_one(actor: actor)
  end
end
