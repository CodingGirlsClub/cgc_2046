defmodule Cgc2046.Mcp.Tools.AssignEventModerator do
  @moduledoc """
  指派活动主理人（Owner/Admin 专属，直接写）。

  指派锚（#539）：`user_id` 参数接受邮箱 / CGC 编号（`CGC-XXXXXX`）/ 用户 ID
  三种精确锚，透传域层 `Accounts.UserResolution` 单源解析后落 UUID（与 Web
  同口径，MCP 不做本地格式校验——非法格式在域内落统一「用户不存在」）。
  """
  use Anubis.Server.Component, type: :tool
  alias Cgc2046.Errors.BusinessError
  alias Cgc2046.Events.Moderators
  alias Cgc2046.Mcp.Wrapper

  schema do
    field(:workspace_id, {:required, :string}, description: "目标工作台 ID（UUID）")
    field(:event_id, {:required, :string}, description: "目标活动 ID（UUID）")

    field(:user_id, {:required, :string},
      description:
        "被指派用户锚：邮箱 / CGC 编号（CGC-XXXXXX）/ 用户 ID 任一精确匹配；任一未命中统一报 user_not_found（不区分锚类型），CGC 前缀命中多人报 user_anchor_ambiguous（改用用户 ID）"
    )
  end

  @impl true
  def execute(params, frame) do
    result =
      Wrapper.run(frame, params, "assign_event_moderator", fn actor, workspace_id, params ->
        case Moderators.assign(params["event_id"], workspace_id, params["user_id"], actor) do
          {:ok, record} ->
            {:ok, %{moderator_id: record.id, event_id: record.event_id, user_id: record.user_id}}

          {:error, :forbidden} ->
            {:error, "forbidden: owner or admin required"}

          # #539 三锚点解析错误（域函数直返 BusinessError，不在 Ash.Error.Invalid
          # 容器）：code 前缀直达 agent（可程序化识别），message 含引导文案
          # （ambiguous 时引导换用户 ID）——不落笼统 fallback。
          {:error, %BusinessError{code: code, message: message}}
          when is_binary(code) and is_binary(message) ->
            {:error, "#{code}: #{message}"}

          {:error, error} ->
            {:error, Cgc2046.Mcp.Errors.message(error, "failed to assign moderator")}
        end
      end)

    Cgc2046.Mcp.Tools.Response.to_response(result, frame)
  end
end
