defmodule Cgc2046.Mcp.Tools.GetPublicInitiative do
  @moduledoc """
  公开读取 Initiative 的跨 Workspace 活动页投影。
  """

  use Anubis.Server.Component,
    type: :tool,
    meta: %{workspace_id: :optional, membership: :public}

  alias Cgc2046.Initiatives.Public
  alias Cgc2046.Mcp.Wrapper

  # 发给调用方 agent 的工具描述（只写契约）；@moduledoc 留给维护者
  @impl true
  def description do
    """
    按 slug 读取一个公开的倡导活动页（open / closed / cancelled 都可读；draft 返回 not found）。任何已
    连接用户可用，不需要 workspace_id。只有 open 的倡导活动才列出挂载的场次；每个场次带参与条件：
    payment_mode 与押金明细、是否有年龄门槛、收费起价、成班进度。不返回规则原始值与锁定标记。
    """
  end

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
