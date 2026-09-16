defmodule Cgc2046.Mcp.Tools.AdminCreateInitiative do
  use Anubis.Server.Component,
    type: :tool,
    meta: %{workspace_id: :optional, membership: :platform_admin}

  alias Cgc2046.Initiatives.Initiative
  alias Cgc2046.Mcp.{Confirmation, Wrapper}
  alias Cgc2046.Mcp.Tools.AdminInitiativeHelpers, as: H

  schema do
    field(:name, {:required, :string}, description: "活动名称")
    field(:slug, {:required, :string}, description: "全局唯一 slug")
    field(:hashtag, :string)
    field(:description, :string)
    field(:window_starts_at, :string)
    field(:window_ends_at, :string)
  end

  @impl true
  def execute(params, frame) do
    result =
      Wrapper.run(frame, params, "admin_create_initiative", fn _actor, _ws, params ->
        summary = "创建倡导活动「#{params["name"]}」（slug #{params["slug"]}），初始状态 draft"

        Confirmation.request(
          frame.assigns[:current_user],
          "admin_create_initiative",
          params,
          summary
        )
      end)

    Cgc2046.Mcp.Tools.Response.to_response(result, frame)
  end

  @spec execute_confirmed(term(), map()) :: {:ok, map()} | {:error, String.t()}
  def execute_confirmed(actor, params) do
    attrs =
      H.attrs(params, ~w(name slug hashtag description)a)
      |> Map.merge(H.datetime_attrs(params))
      |> Map.put(:created_by, actor.id)

    case Initiative |> Ash.Changeset.for_create(:create, attrs) |> Ash.create(actor: actor) do
      {:ok, initiative} ->
        H.row(initiative, actor)

      {:error, error} ->
        {:error, Cgc2046.Mcp.Errors.message(error, "failed to create initiative")}
    end
  end
end
