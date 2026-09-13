defmodule Cgc2046.Initiatives.RuleInheritance do
  @moduledoc """
  Event 与 InitiativeRule 的挂载边界。

  所有挂载和 Event 规则写入先锁 Initiative 行，再读取规则；这保证规则翻锁与
  Owner/Admin 的草稿写入不会在 READ COMMITTED 下互相覆盖。
  """

  alias Cgc2046.Repo

  @rule_keys [:deposit, :age_gate, :min_participants, :deadline_rule]

  @doc "应用 Event create/update changeset 中的挂载规则与锁死守卫。"
  def prepare_event_changes(changeset, _context) do
    previous_id = Ash.Changeset.get_data(changeset, :initiative_id)
    initiative_id = Ash.Changeset.get_attribute(changeset, :initiative_id)
    mounting? = Ash.Changeset.changing_attribute?(changeset, :initiative_id)

    # Lock both parents in stable order before the Event, including detach.
    with :ok <- lock_parents([previous_id, initiative_id]),
         :ok <- lock_current_event(changeset),
         :ok <- ensure_mount_state(changeset) do
      if is_nil(initiative_id) do
        changeset
      else
        with {:ok, initiative} <- lock_initiative(initiative_id),
             :ok <- ensure_open_when_mounting(initiative, mounting?),
             {:ok, rules} <- load_rules(initiative_id),
             :ok <- ensure_complete(rules),
             {:ok, attrs} <- effective_event_attrs(changeset, rules) do
          Enum.reduce(attrs, changeset, fn {field, value}, cs ->
            Ash.Changeset.force_change_attribute(cs, field, value)
          end)
        else
          {:error, message} -> Ash.Changeset.add_error(changeset, message)
        end
      end
    else
      {:error, message} -> Ash.Changeset.add_error(changeset, message)
    end
  end

  defp lock_parents(ids) do
    ids
    |> Enum.reject(&is_nil/1)
    |> Enum.uniq()
    |> Enum.sort()
    |> Enum.reduce_while(:ok, fn id, :ok ->
      case lock_initiative(id) do
        {:ok, _} -> {:cont, :ok}
        {:error, _} = error -> {:halt, error}
      end
    end)
  end

  defp lock_current_event(%{action_type: :create}), do: :ok

  defp lock_current_event(changeset) do
    case Repo.query("SELECT initiative_id, status FROM events WHERE id = $1 FOR UPDATE", [
           Repo.uuid!(changeset.data.id)
         ]) do
      {:ok, %{rows: [[parent_id, status]]}} ->
        parent_id = if parent_id, do: Ecto.UUID.load!(parent_id)

        if parent_id == changeset.data.initiative_id and
             status == to_string(changeset.data.status),
           do: :ok,
           else: {:error, "event changed; reload before editing"}

      _ ->
        {:error, "event not found"}
    end
  end

  def prepare_rule_change(changeset) do
    with {:ok, _} <- lock_initiative(Ash.Changeset.get_attribute(changeset, :initiative_id)),
         :ok <-
           validate_rule_value(
             Ash.Changeset.get_attribute(changeset, :key),
             Ash.Changeset.get_attribute(changeset, :value)
           ) do
      changeset
    else
      {:error, message} -> Ash.Changeset.add_error(changeset, message)
    end
  end

  @doc "规则值或锁标记改变后，锁死项传播到全部已挂载 Event。调用方应在 Ash action 事务内执行。"
  def propagate_rule_change(initiative_id, key, value, locked) do
    with {:ok, _initiative} <- lock_initiative(initiative_id),
         {:ok, key_atom} <- normalize_key(key),
         :ok <- validate_rule_value(key_atom, value) do
      if locked do
        events =
          case Repo.query(
                 "SELECT id, starts_at FROM events WHERE initiative_id = $1 FOR UPDATE",
                 [Repo.uuid!(initiative_id)]
               ) do
            {:ok, %{rows: rows}} -> rows
            {:error, reason} -> throw({:propagation_error, reason})
          end

        Enum.each(events, fn [id, starts_at] ->
          attrs = propagated_attrs(key_atom, value, starts_at)
          Repo.query!(update_sql(attrs), update_params(id, attrs))
        end)
      end

      :ok
    end
  catch
    {:propagation_error, reason} ->
      {:error, "initiative rule propagation failed: #{inspect(reason)}"}
  end

  defp normalize_key(key) when is_atom(key) and key in @rule_keys, do: {:ok, key}

  defp normalize_key(key) when is_binary(key),
    do:
      if(key in ~w(deposit age_gate min_participants deadline_rule),
        do: {:ok, String.to_existing_atom(key)},
        else: {:error, "invalid rule key"}
      )

  defp normalize_key(_), do: {:error, "invalid rule key"}

  def validate_rule_value(key, value) do
    case value_for_event(key, value, %{attributes: %{starts_at: nil}}) do
      {:ok, _} -> :ok
      {:error, message} -> {:error, message}
    end
  end

  defp propagated_attrs(:deposit, value, _starts_at) do
    {:ok, attrs} = value_for_event(:deposit, value, nil)
    attrs
  end

  defp propagated_attrs(:age_gate, value, _starts_at),
    do: %{min_age: elem(value_for_event(:age_gate, value, nil), 1)}

  defp propagated_attrs(:min_participants, value, _starts_at),
    do: %{min_participants: elem(value_for_event(:min_participants, value, nil), 1)}

  defp propagated_attrs(:deadline_rule, value, starts_at) do
    hours = Map.get(value, "hours_before_start", Map.get(value, :hours_before_start))

    %{
      registration_deadline:
        if(starts_at, do: NaiveDateTime.add(starts_at, -hours * 3600, :second), else: nil)
    }
  end

  defp update_sql(attrs) do
    columns =
      attrs
      |> Map.keys()
      |> Enum.with_index(1)
      |> Enum.map_join(", ", fn {key, index} -> "#{key} = $#{index}" end)

    "UPDATE events SET #{columns}, updated_at = NOW() WHERE id = $#{map_size(attrs) + 1}"
  end

  defp update_params(id, attrs), do: Map.values(attrs) ++ [id]

  @doc "读取某 Initiative 的规则；仅用于公开的规则服务，不返回凭证。"
  def rules_for(initiative_id) when is_binary(initiative_id) do
    case load_rules(initiative_id) do
      {:ok, rules} -> {:ok, rules}
      {:error, _} = error -> error
    end
  end

  @doc "判断 Initiative 是否具备全部四项规则。"
  def ready?(initiative_id) do
    case rules_for(initiative_id) do
      {:ok, rules} -> Enum.all?(@rule_keys, &Map.has_key?(rules, &1))
      _ -> false
    end
  end

  defp lock_initiative(id) do
    case Repo.query("SELECT id, status FROM initiatives WHERE id = $1 FOR UPDATE", [
           Repo.uuid!(id)
         ]) do
      {:ok, %{rows: [[id, status]]}} -> {:ok, %{id: id, status: status}}
      {:ok, %{rows: []}} -> {:error, "initiative not found"}
      {:error, reason} -> {:error, "initiative read failed: #{inspect(reason)}"}
    end
  end

  defp ensure_open(%{status: "open"}), do: :ok
  defp ensure_open(%{status: :open}), do: :ok
  defp ensure_open(_), do: {:error, "initiative must be open before an event can be mounted"}

  defp ensure_open_when_mounting(initiative, true), do: ensure_open(initiative)
  defp ensure_open_when_mounting(_initiative, false), do: :ok

  defp ensure_mount_state(changeset) do
    status = Ash.Changeset.get_data(changeset, :status)
    changing_mount? = Ash.Changeset.changing_attribute?(changeset, :initiative_id)

    cond do
      changing_mount? and status not in [nil, :draft, "draft"] ->
        {:error, "initiative can only be mounted or changed while event is draft"}

      true ->
        :ok
    end
  end

  defp load_rules(initiative_id) do
    result =
      Repo.query(
        "SELECT key, value, locked FROM initiative_rules WHERE initiative_id = $1 ORDER BY key",
        [Repo.uuid!(initiative_id)]
      )

    case result do
      {:ok, %{rows: rows}} ->
        rules =
          Map.new(rows, fn [key, value, locked] ->
            {String.to_existing_atom(key), %{value: value || %{}, locked: locked}}
          end)

        {:ok, rules}

      {:error, reason} ->
        {:error, "initiative rules read failed: #{inspect(reason)}"}
    end
  end

  defp ensure_complete(rules) do
    case @rule_keys -- Map.keys(rules) do
      [] -> :ok
      missing -> {:error, "initiative is missing rules: #{Enum.join(missing, ", ")}"}
    end
  end

  defp effective_event_attrs(changeset, rules) do
    creating? = changeset.action_type == :create
    mounting? = creating? or Ash.Changeset.changing_attribute?(changeset, :initiative_id)

    Enum.reduce_while(@rule_keys, {:ok, %{}}, fn key, {:ok, attrs} ->
      rule = Map.get(rules, key)
      event_field = event_field(key)

      cond do
        is_nil(rule) ->
          {:cont, {:ok, attrs}}

        rule.locked ->
          case value_for_event(key, rule.value, changeset) do
            {:ok, value} ->
              values = merge_event_value(%{}, event_field, value)

              conflict? =
                not mounting? and
                  Enum.any?(values, fn {field, expected} ->
                    Ash.Changeset.changing_attribute?(changeset, field) and
                      Ash.Changeset.get_attribute(changeset, field) != expected
                  end)

              if conflict?,
                do: {:halt, {:error, "initiative rule #{key} is locked"}},
                else: {:cont, {:ok, Map.merge(attrs, values)}}

            {:error, reason} ->
              {:halt, {:error, reason}}
          end

        mounting? ->
          case value_for_event(key, rule.value, changeset) do
            {:ok, value} -> {:cont, {:ok, merge_event_value(attrs, event_field, value)}}
            {:error, reason} -> {:halt, {:error, reason}}
          end

        true ->
          {:cont, {:ok, attrs}}
      end
    end)
  end

  defp event_field(:deposit), do: :deposit_enabled
  defp event_field(:age_gate), do: :min_age
  defp event_field(:min_participants), do: :min_participants
  defp event_field(:deadline_rule), do: :registration_deadline

  defp merge_event_value(attrs, :deposit_enabled, %{deposit_enabled: _} = values),
    do: Map.merge(attrs, values)

  defp merge_event_value(attrs, field, value), do: Map.put(attrs, field, value)

  defp value_for_event(:deposit, value, _changeset) when is_map(value) do
    enabled = Map.get(value, "enabled", Map.get(value, :enabled, false))
    amount = Map.get(value, "amount_cents", Map.get(value, :amount_cents))

    if is_boolean(enabled) and
         ((not enabled and is_nil(amount)) or (is_integer(amount) and amount > 0)) do
      {:ok, %{deposit_enabled: enabled, deposit_amount_cents: amount}}
    else
      {:error, "invalid deposit rule value"}
    end
  end

  defp value_for_event(:age_gate, value, _changeset) when is_map(value) do
    min_age = Map.get(value, "min_age", Map.get(value, :min_age))

    if is_integer(min_age) and min_age > 0,
      do: {:ok, min_age},
      else: {:error, "invalid age_gate rule value"}
  end

  defp value_for_event(:min_participants, value, _changeset) do
    value = if is_map(value), do: Map.get(value, "count", Map.get(value, :count)), else: value

    if is_integer(value) and value > 0,
      do: {:ok, value},
      else: {:error, "invalid min_participants rule value"}
  end

  defp value_for_event(:deadline_rule, value, changeset) when is_map(value) do
    hours = Map.get(value, "hours_before_start", Map.get(value, :hours_before_start))

    starts_at =
      case changeset do
        %Ash.Changeset{} ->
          Ash.Changeset.get_attribute(changeset, :starts_at)

        %{attributes: attrs} when is_map(attrs) ->
          Map.get(attrs, :starts_at) || Map.get(attrs, "starts_at")

        _ ->
          nil
      end

    cond do
      not (is_integer(hours) and hours >= 0) -> {:error, "invalid deadline_rule rule value"}
      is_nil(starts_at) -> {:ok, nil}
      match?(%DateTime{}, starts_at) -> {:ok, DateTime.add(starts_at, -hours * 3600, :second)}
      true -> {:error, "deadline_rule requires a DateTime starts_at"}
    end
  end

  defp value_for_event(_key, _value, _changeset), do: {:error, "invalid initiative rule value"}
end
