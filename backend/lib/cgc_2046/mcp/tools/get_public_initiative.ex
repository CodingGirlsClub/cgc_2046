defmodule Cgc2046.Mcp.Tools.GetPublicInitiative do
  @moduledoc """
  公开读取 Initiative 的跨 Workspace 活动页投影。
  """

  use Anubis.Server.Component,
    type: :tool,
    meta: %{workspace_id: :optional, membership: :public}

  alias Cgc2046.Initiatives.Public
  alias Cgc2046.Mcp.Wrapper

  schema do
    field(:slug, {:required, :string}, description: "Initiative 公开 slug")
  end

  @impl true
  def execute(params, frame) do
    result =
      Wrapper.run(frame, params, "get_public_initiative", fn _actor, _workspace_id, params ->
        case Public.get_by_slug(params["slug"]) do
          {:ok, payload} -> {:ok, payload}
          {:error, :not_found} -> {:error, "public initiative not found: #{params["slug"]}"}
          {:error, _} -> {:error, "failed to load public initiative"}
        end
      end)

    Cgc2046.Mcp.Tools.Response.to_response(result, frame)
  end
end
