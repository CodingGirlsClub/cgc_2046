defmodule Cgc2046.NotificationService do
  @moduledoc "按平台身份投递订阅消息，并以数据库原子操作消费一次性授权。"

  require Ash.Query

  alias Cgc2046.Accounts.UserIdentity
  alias Cgc2046.Miniprogram.Client
  alias Cgc2046.NotificationConsent

  def send_to_user(user_id, platform, template_key, data) when is_map(data) do
    with {:ok, uid} <- identity_uid(user_id, platform) do
      send_to_identity(user_id, platform, uid, template_key, data)
    end
  end

  @doc "投递到指定平台身份（uid 已知，如同用户多身份场景）；授权按 user+platform 原子消费。"
  def send_to_identity(user_id, platform, uid, template_key, data) when is_map(data) do
    with {:ok, template_id} <- template_id(platform, template_key),
         {:ok, _remaining} <- NotificationConsent.take(user_id, platform, template_key) do
      case Client.send_notification(platform, uid, template_id, data) do
        :ok ->
          :ok

        {:error, _} = error ->
          _ = NotificationConsent.refund(user_id, platform, template_key)
          error
      end
    end
  end

  defp template_id(platform, template_key) do
    case get_in(Application.get_env(:cgc_2046, :miniprogram_templates, %{}), [
           platform,
           template_key
         ]) do
      template_id when is_binary(template_id) and template_id != "" -> {:ok, template_id}
      _ -> {:error, :template_not_configured}
    end
  end

  defp identity_uid(user_id, platform) do
    UserIdentity
    |> Ash.Query.filter(user_id == ^user_id and provider == ^platform)
    |> Ash.read_one(authorize?: false)
    |> case do
      {:ok, %UserIdentity{uid: uid}} -> {:ok, uid}
      {:ok, nil} -> {:error, :platform_identity_not_found}
      {:error, reason} -> {:error, reason}
    end
  end
end
