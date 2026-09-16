defmodule Cgc2046.Mcp.Tools.AdminUpdateInitiative do
  use Anubis.Server.Component,
    type: :tool,
    meta: %{workspace_id: :optional, membership: :platform_admin}

  alias Cgc2046.Initiatives.Initiative
  alias Cgc2046.Mcp.{Confirmation, Wrapper}
  alias Cgc2046.Mcp.Tools.AdminInitiativeHelpers, as: H

  schema do
    field(:initiative_id, {:required, :string})
    field(:name, :string)
    field(:slug, :string)
    field(:hashtag, :string)
    field(:description, :string)
    field(:window_starts_at, :string)
    field(:window_ends_at, :string)
  end

  @impl true
  def execute(params, frame) do
    result =
      Wrapper.run(frame, params, "admin_update_initiative", fn actor, _ws, params ->
        case Ash.get(Initiative, params["initiative_id"], actor: actor) do
          {:ok, nil} ->
            {:error, "initiative not found"}

          {:ok, initiative} ->
            fields =
              H.attrs(params, ~w(name slug hashtag description)a)
              |> Map.merge(H.datetime_attrs(params))

            if map_size(fields) == 0 do
              {:error, "at least one initiative field is required"}
            else
              summary =
                "更新倡导活动「#{initiative.name}」（#{initiative.id}）的元数据字段：#{Map.keys(fields) |> Enum.join(", ")}"

              Confirmation.request(
                frame.assigns[:current_user],
                "admin_update_initiative",
                params,
                summary
              )
            end

          {:error, _} ->
            {:error, "failed to load initiative"}
        end
      end)

    Cgc2046.Mcp.Tools.Response.to_response(result, frame)
  end

  @spec execute_confirmed(term(), map()) :: {:ok, map()} | {:error, String.t()}
  def execute_confirmed(actor, params) do
    with {:ok, initiative} <- Ash.get(Initiative, params["initiative_id"], actor: actor) do
      attrs =
        H.attrs(params, ~w(name slug hashtag description)a)
        |> Map.merge(H.datetime_attrs(params))

      case initiative |> Ash.Changeset.for_update(:update, attrs) |> Ash.update(actor: actor) do
        {:ok, updated} ->
          H.row(updated, actor)

        {:error, error} ->
          {:error, Cgc2046.Mcp.Errors.message(error, "failed to update initiative")}
      end
    else
      {:error, _} -> {:error, "failed to load initiative"}
    end
  end
end
