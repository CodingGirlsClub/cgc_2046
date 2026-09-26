defmodule Cgc2046.Mcp.Tools.AdminSoftDeleteWishComment do
  @moduledoc """
  软删许愿留言（U9/R18，platform_admin，两段式确认）：走
  `Flashback.Wishes.soft_delete_comment/3`（admin?: true，KTD4 单源）。
  摘要自取所属许愿正文回显。
  """
  use Anubis.Server.Component,
    type: :tool,
    meta: %{workspace_id: :optional, membership: :platform_admin}

  alias Cgc2046.Flashback.{Wish, WishComment, Wishes}
  alias Cgc2046.Mcp.{Confirmation, Wrapper}
  require Ash.Query

  # 发给调用方 agent 的工具描述（只写契约）；@moduledoc 留给维护者
  @impl true
  def description do
    """
    平台管理员专用：删除一条许愿留言（软删除），reason 必填（1–500 字）。确认摘要会显示该留言所属许愿
    的正文，用于确认前核对目标。
    走确认流：第一次调用只返回 needs_confirmation + pending_id + summary，
    用户确认后调 confirm_operation(pending_id) 才执行。
    """
  end

  schema do
    field(:comment_id, :string, description: "留言 id", required: true)
    field(:reason, :string, description: "删除理由（1–500 字）", required: true)
  end

  @impl true
  def execute(params, frame) do
    result =
      Wrapper.run(frame, params, "admin_soft_delete_wish_comment", fn _actor, _ws, params ->
        with :ok <- validate_reason(params["reason"]),
             {:ok, comment, wish} <- fetch_comment(params["comment_id"]) do
          if comment.deleted_at do
            {:error, "comment already deleted"}
          else
            Confirmation.request(
              frame.assigns[:current_user],
              "admin_soft_delete_wish_comment",
              params,
              summary(comment, wish, params["reason"])
            )
          end
        end
      end)

    Cgc2046.Mcp.Tools.Response.to_response(result, frame)
  end

  @spec execute_confirmed(term(), map()) :: {:ok, map()} | {:error, String.t()}
  def execute_confirmed(_actor, params) do
    case Wishes.soft_delete_comment(params["comment_id"], nil, admin?: true) do
      {:ok, comment} ->
        remaining =
          comment
          |> then(&%{id: &1.wish_id})
          |> then(&Wishes.list_comments(&1.id))

        {:ok,
         %{
           comment_id: comment.id,
           wish_id: comment.wish_id,
           deleted_at: comment.deleted_at,
           remaining_comment_count: length(remaining)
         }}

      {:error, %{code: "flashback_wish_comment_not_found"}} ->
        {:error, "comment not found"}

      _ ->
        {:ok, %{comment_id: params["comment_id"], already_deleted: true}}
    end
  end

  defp fetch_comment(comment_id) when is_binary(comment_id) and comment_id != "" do
    WishComment
    |> Ash.Query.filter(id == ^comment_id)
    |> Ash.read_one(authorize?: false)
    |> case do
      {:ok, nil} ->
        {:error, "comment not found"}

      {:ok, comment} ->
        Wish
        |> Ash.Query.filter(id == ^comment.wish_id)
        |> Ash.read_one(authorize?: false)
        |> case do
          {:ok, wish} -> {:ok, comment, wish}
          _ -> {:error, "comment not found"}
        end

      error ->
        error
    end
  end

  defp fetch_comment(_), do: {:error, "comment not found"}

  defp validate_reason(reason) when is_binary(reason) do
    trimmed = String.trim(reason)

    cond do
      trimmed == "" -> {:error, "reason must not be blank"}
      String.length(trimmed) > 500 -> {:error, "reason must be at most 500 characters"}
      true -> :ok
    end
  end

  defp validate_reason(_), do: {:error, "reason must not be blank"}

  defp summary(comment, wish, reason) do
    head = String.slice(comment.content, 0, 80)
    "软删留言「#{head}」· 所属许愿「#{String.slice(wish.content, 0, 40)}」· 理由：#{reason}。软删后不再显示；数据保留。"
  end
end
