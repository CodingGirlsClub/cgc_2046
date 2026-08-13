defmodule Cgc2046.Events.SpeakerInvitations do
  @moduledoc """
  SpeakerInvitation 的查询面辅助（E-4 #49）。

  - list_for_event/2：Event 的邀请列表（Owner/Admin 门控经资源 read policy，
    tenant = Event 的 workspace_id；非管理角色 → forbidden）
  - card/1：token 公开卡片查询（Speaker 着陆页，无需登录）——只返回邀请主题/
    时间 + Event 公开信息（D2 白名单），不泄露其它邀请；无效/过期/已用 token
    统一错误（不做防枚举时序攻击，任务验收明确错误信息统一即可）。
  """

  alias Cgc2046.Events.{Event, SpeakerInvitation}

  require Ash.Query

  @spec list_for_event(String.t(), term()) ::
          {:ok, [SpeakerInvitation.t()]} | {:error, :forbidden | :event_not_found | term()}
  def list_for_event(event_id, actor) do
    case Ash.get(Event, event_id, authorize?: false) do
      {:ok, %Event{} = event} ->
        SpeakerInvitation
        |> Ash.Query.filter(event_id == ^event_id)
        |> Ash.Query.sort(inserted_at: :desc)
        |> Ash.read(tenant: event.workspace_id, actor: actor)
        |> case do
          {:ok, invitations} -> {:ok, invitations}
          {:error, %Ash.Error.Forbidden{}} -> {:error, :forbidden}
          {:error, reason} -> {:error, reason}
        end

      {:ok, nil} ->
        {:error, :event_not_found}

      {:error, _} ->
        {:error, :event_not_found}
    end
  end

  @spec card(String.t()) :: {:ok, map()} | {:error, :invalid_or_expired_token}
  def card(token) do
    with {:ok, hash} <- valid_token(token),
         {:ok, invitation} <- fetch_by_token(hash),
         :ok <- ensure_decidable(invitation),
         {:ok, event} <- fetch_event(invitation.event_id) do
      {:ok,
       %{
         status: to_string(invitation.status),
         topic: invitation.topic,
         scheduled_at: invitation.scheduled_at,
         event: %{
           id: event.id,
           slug: event.slug,
           title: event.title,
           description: event.description,
           status: to_string(event.status)
         }
       }}
    else
      _ -> {:error, :invalid_or_expired_token}
    end
  end

  defp valid_token(token) when is_binary(token) and token != "" do
    {:ok, SpeakerInvitation.hash_token(token)}
  end

  defp valid_token(_), do: {:error, :invalid_or_expired_token}

  defp fetch_by_token(hash) do
    case SpeakerInvitation
         |> Ash.Query.filter(token_hash == ^hash)
         |> Ash.read_one(authorize?: false) do
      {:ok, %SpeakerInvitation{} = invitation} -> {:ok, invitation}
      _ -> {:error, :invalid_or_expired_token}
    end
  end

  # 仅 invited 且未过期可决策；已接受/已婉拒/已完成 = 已用（统一错误）
  defp ensure_decidable(%SpeakerInvitation{status: :invited, expires_at: expires_at}) do
    if is_nil(expires_at) or DateTime.compare(DateTime.utc_now(), expires_at) == :lt do
      :ok
    else
      {:error, :invalid_or_expired_token}
    end
  end

  defp ensure_decidable(_), do: {:error, :invalid_or_expired_token}

  defp fetch_event(event_id) do
    case Ash.get(Event, event_id, authorize?: false) do
      {:ok, %Event{} = event} -> {:ok, event}
      _ -> {:error, :invalid_or_expired_token}
    end
  end
end
