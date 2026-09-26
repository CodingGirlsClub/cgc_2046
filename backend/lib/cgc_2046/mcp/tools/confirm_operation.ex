defmodule Cgc2046.Mcp.Tools.ConfirmOperation do
  @moduledoc """
  确认流内置工具（D-D3）：确认并执行 pending 操作。

  仅本人、pending 且未过期可确认；确认后调注册执行器落库 + 审计。
  本工具不要求 workspace 成员资格（pending 归属校验即授权；
  `meta: %{workspace_id: :optional}` 声明豁免，Wrapper 派生门控读取）。
  """
  use Anubis.Server.Component, type: :tool, meta: %{workspace_id: :optional}

  alias Cgc2046.Mcp.Confirmation
  alias Cgc2046.Mcp.Wrapper

  # 发给调用方 agent 的工具描述（只写契约）；@moduledoc 留给维护者
  @impl true
  def description do
    """
    确认并执行一个待确认的操作（pending_id 来自其他工具返回的 needs_confirmation）。只能确认本人发起、
    仍处于待确认状态且未过期的操作。只在用户明确同意后调用；返回该操作执行后的结果。
    """
  end

  schema do
    field(:pending_id, {:required, :string}, description: "待确认操作 ID（needs_confirmation 返回）")
  end

  @impl true
  def execute(params, frame) do
    result =
      Wrapper.run(frame, params, "confirm_operation", fn actor, _workspace_id, params ->
        Confirmation.confirm(actor, params["pending_id"])
      end)

    Cgc2046.Mcp.Tools.Response.to_response(result, frame)
  end
end
