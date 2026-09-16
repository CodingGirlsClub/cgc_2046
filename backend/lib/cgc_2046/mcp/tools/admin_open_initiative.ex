defmodule Cgc2046.Mcp.Tools.AdminOpenInitiative do
  use Anubis.Server.Component,
    type: :tool,
    meta: %{workspace_id: :optional, membership: :platform_admin}

  alias Cgc2046.Initiatives.Initiative
  alias Cgc2046.Mcp.{Confirmation, Wrapper}
  alias Cgc2046.Mcp.Tools.AdminInitiativeHelpers, as: H

  schema do
    field(:initiative_id, {:required, :string})
  end

  @impl true
  def execute(params, frame) do
    result =
      Wrapper.run(frame, params, "admin_open_initiative", fn actor, _ws, params ->
        case Ash.get(Initiative, params["initiative_id"], actor: actor) do
          {:ok, nil} ->
            {:error, "initiative not found"}

          {:ok, initiative} ->
            Confirmation.request(
              frame.assigns[:current_user],
              "admin_open_initiative",
              params,
              "开放倡导活动「#{initiative.name}」（#{initiative.id}）：#{initiative.status} → open"
            )

          {:error, _} ->
            {:error, "failed to load initiative"}
        end
      end)

    Cgc2046.Mcp.Tools.Response.to_response(result, frame)
  end

  @spec execute_confirmed(term(), map()) :: {:ok, map()} | {:error, String.t()}
  def execute_confirmed(actor, params), do: change_status(actor, params["initiative_id"], :open)

  defp change_status(actor, id, action) do
    case Ash.get(Initiative, id, actor: actor) do
      {:ok, nil} ->
        {:error, "initiative not found"}

      {:ok, initiative} ->
        case initiative |> Ash.Changeset.for_update(action, %{}) |> Ash.update(actor: actor) do
          {:ok, updated} ->
            H.row(updated, actor)

          {:error, error} ->
            {:error, Cgc2046.Mcp.Errors.message(error, "failed to open initiative")}
        end

      {:error, _} ->
        {:error, "failed to load initiative"}
    end
  end
end
