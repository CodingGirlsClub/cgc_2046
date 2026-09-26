defmodule Cgc2046.Mcp.Tools.ListPublicInitiatives do
  @moduledoc """
  列出公开的倡导活动（open / closed / cancelled；draft 不公开），按 open → closed →
  cancelled 排序，同状态内按窗口开始时间，最多 100 条。任何已连接用户可用，无参数，不需要
  workspace_id。返回 count + initiatives（id / name / slug / url / hashtag / description /
  window_starts_at / window_ends_at / status）。
  """
  use Anubis.Server.Component, type: :tool, meta: %{workspace_id: :optional, membership: :public}
  alias Cgc2046.Mcp.Wrapper

  schema do
  end

  @impl true
  def execute(params, frame) do
    result =
      Wrapper.run(frame, params, "list_public_initiatives", fn _actor, _workspace_id, _params ->
        case Cgc2046.Initiatives.Public.list() do
          {:ok, initiatives} -> {:ok, %{initiatives: initiatives, count: length(initiatives)}}
          {:error, _} -> {:error, "failed to list public initiatives"}
        end
      end)

    Cgc2046.Mcp.Tools.Response.to_response(result, frame)
  end
end
