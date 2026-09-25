defmodule Cgc2046.Flashback.WishEchoDelivery do
  @moduledoc """
  回响出队前的有效性读面。入队与发送间，出力者可能取消，愿望或回响可能撤回。
  此时跳过发送且不消耗订阅配额；仍有效时读取触发本任务的回响，避免更正后发送旧文本。
  必须显式携带 echo_id，不根据摘要或时间猜测事件身份。上线前须排空旧格式队列，
  详见订阅模板运维文档「回响队列升级」。数据库故障抛出，由 Oban 重试。
  这只是发送前复核，已经交给平台的消息无法撤回。
  """
  alias Cgc2046.Repo

  @spec prepare(map()) :: :skip | {:ok, map()} | {:error, :echo_identity_missing}
  def prepare(%{
        "user_id" => user_id,
        "data" =>
          %{"wish_id" => wish_id, "endorsement_id" => endorsement_id, "echo_id" => echo_id} = data
      }) do
    with {:ok, user} <- Ecto.UUID.dump(user_id),
         {:ok, wish} <- Ecto.UUID.dump(wish_id),
         {:ok, endorsement} <- Ecto.UUID.dump(endorsement_id),
         {:ok, echo} <- Ecto.UUID.dump(echo_id) do
      case Repo.query!(
             """
             SELECT echo.content
             FROM flashback_wish_endorsements endorsement
             JOIN flashback_wishes wish ON wish.id = endorsement.wish_id
             JOIN flashback_wish_echoes echo ON echo.wish_id = wish.id
             WHERE endorsement.id = $1 AND endorsement.user_id = $2
               AND endorsement.wish_id = $3 AND endorsement.notify = TRUE
               AND wish.visibility = 'public' AND wish.listed_at IS NOT NULL
               AND wish.hidden_at IS NULL AND wish.deleted_at IS NULL
               AND echo.id = $4 AND echo.status IN ('published', 'corrected')
             """,
             [endorsement, user, wish, echo]
           ).rows do
        [[content]] -> {:ok, Map.put(data, "content_preview", String.slice(content, 0, 20))}
        [] -> :skip
      end
    else
      _ -> :skip
    end
  end

  def prepare(_), do: {:error, :echo_identity_missing}
end
