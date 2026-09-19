defmodule Cgc2046.Mcp.Tools.AdminSoftDeleteWish do
  @moduledoc """
  软删许愿（U9/R18，platform_admin，两段式确认）：治理删除走
  `Flashback.Wishes.soft_delete_wish/3`（admin?: true——与学员自助删除
  同一实现，KTD4 单源）；确认摘要回显目标正文前 80 字与作者遮罩姓，
  运营确认前可核对目标是否被留言注入驱动。
  """
  use Anubis.Server.Component,
    type: :tool,
    meta: %{workspace_id: :optional, membership: :platform_admin}

  alias Cgc2046.Flashback.{AlumniProjection, Wish, Wishes}
  alias Cgc2046.Mcp.{Confirmation, Wrapper}
  require Ash.Query

  schema do
    field(:wish_id, :string, description: "许愿 id", required: true)
    field(:reason, :string, description: "删除理由（1–500 字，审计留痕）", required: true)
  end

  @impl true
  def execute(params, frame) do
    result =
      Wrapper.run(frame, params, "admin_soft_delete_wish", fn _actor, _ws, params ->
        with :ok <- validate_reason(params["reason"]),
             {:ok, wish} <- fetch_wish(params["wish_id"]) do
          if wish.deleted_at do
            {:error, "wish already deleted"}
          else
            Confirmation.request(
              frame.assigns[:current_user],
              "admin_soft_delete_wish",
              params,
              summary(wish, params["reason"])
            )
          end
        end
      end)

    Cgc2046.Mcp.Tools.Response.to_response(result, frame)
  end

  @doc """
  确认后真正执行（Confirmation.execute 分派）。
  """
  @spec execute_confirmed(term(), map()) :: {:ok, map()} | {:error, String.t()}
  def execute_confirmed(_actor, params) do
    case Wishes.soft_delete_wish(params["wish_id"], nil, admin?: true) do
      {:ok, wish} ->
        {:ok,
         %{
           wish_id: wish.id,
           deleted_at: wish.deleted_at,
           visibility: wish.visibility
         }}

      {:error, %{code: "flashback_wish_not_found"}} ->
        {:error, "wish not found"}

      # 并发下已删 → 幂等成功
      _ ->
        {:ok, %{wish_id: params["wish_id"], already_deleted: true}}
    end
  end

  defp fetch_wish(wish_id) when is_binary(wish_id) and wish_id != "" do
    Wish
    |> Ash.Query.filter(id == ^wish_id)
    |> Ash.Query.load(:person)
    |> Ash.read_one(authorize?: false)
    |> case do
      {:ok, nil} -> {:error, "wish not found"}
      {:ok, wish} -> {:ok, wish}
      error -> error
    end
  end

  defp fetch_wish(_), do: {:error, "wish not found"}

  defp validate_reason(reason) when is_binary(reason) do
    trimmed = String.trim(reason)

    cond do
      trimmed == "" -> {:error, "reason must not be blank"}
      String.length(trimmed) > 500 -> {:error, "reason must be at most 500 characters"}
      true -> :ok
    end
  end

  defp validate_reason(_), do: {:error, "reason must not be blank"}

  defp summary(wish, reason) do
    head = String.slice(wish.content, 0, 80)

    "软删许愿「#{head}」(#{wish.visibility}) · 许愿人 #{AlumniProjection.masked_name(wish.person)} · 理由：#{reason}。软删：走廊对学员不可见；数据保留，平台当前无恢复入口。"
  end
end
