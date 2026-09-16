defmodule Cgc2046.Mcp.Tools.AdminUpsertInitiativeRule do
  use Anubis.Server.Component,
    type: :tool,
    meta: %{workspace_id: :optional, membership: :platform_admin}

  alias Cgc2046.Initiatives.{Initiative, InitiativeRule}
  alias Cgc2046.Mcp.{Confirmation, Wrapper}
  alias Cgc2046.Mcp.Tools.AdminInitiativeHelpers, as: H

  schema do
    field(:initiative_id, {:required, :string})

    field(:key, {:required, :string},
      description: "deposit | age_gate | min_participants | deadline_rule"
    )

    field(:value_json, {:required, :string}, description: "规则值 JSON 对象")
    field(:locked, {:required, :boolean})
  end

  @impl true
  def execute(params, frame) do
    result =
      Wrapper.run(frame, params, "admin_upsert_initiative_rule", fn actor, _ws, params ->
        with {:ok, key} <- H.rule_key(params["key"]),
             {:ok, _value} <- decode(params["value_json"]),
             {:ok, initiative} <- Ash.get(Initiative, params["initiative_id"], actor: actor),
             true <- not is_nil(initiative) do
          Confirmation.request(
            frame.assigns[:current_user],
            "admin_upsert_initiative_rule",
            Map.put(params, "key", Atom.to_string(key)),
            "更新倡导活动「#{initiative.name}」的 #{params["key"]} 规则（locked=#{params["locked"]}）"
          )
        else
          false -> {:error, "initiative not found"}
          {:error, message} when is_binary(message) -> {:error, message}
          {:error, _} -> {:error, "failed to load initiative"}
        end
      end)

    Cgc2046.Mcp.Tools.Response.to_response(result, frame)
  end

  @spec execute_confirmed(term(), map()) :: {:ok, map()} | {:error, String.t()}
  def execute_confirmed(actor, params) do
    with {:ok, key} <- H.rule_key(params["key"]),
         {:ok, value} <- decode(params["value_json"]),
         {:ok, initiative} <- Ash.get(Initiative, params["initiative_id"], actor: actor),
         true <- not is_nil(initiative),
         {:ok, existing} <- H.get_rule(params["initiative_id"], key, actor) do
      attrs = %{value: value, locked: params["locked"]}

      result =
        if existing do
          existing |> Ash.Changeset.for_update(:update, attrs) |> Ash.update(actor: actor)
        else
          InitiativeRule
          |> Ash.Changeset.for_create(
            :create,
            Map.merge(attrs, %{initiative_id: initiative.id, key: key})
          )
          |> Ash.create(actor: actor)
        end

      case result do
        {:ok, rule} ->
          H.row(initiative, actor) |> append_rule_result(rule)

        {:error, error} ->
          {:error, Cgc2046.Mcp.Errors.message(error, "failed to update initiative rule")}
      end
    else
      false -> {:error, "initiative not found"}
      {:error, message} when is_binary(message) -> {:error, message}
      {:error, _} -> {:error, "failed to load initiative rule"}
    end
  end

  defp append_rule_result({:ok, row}, rule),
    do: {:ok, Map.put(row, :updated_rule, H.rule_row(rule))}

  defp append_rule_result(error, _rule), do: error

  defp decode(value) do
    case Jason.decode(value) do
      {:ok, map} when is_map(map) -> {:ok, map}
      _ -> {:error, "value_json must be a JSON object"}
    end
  end
end
