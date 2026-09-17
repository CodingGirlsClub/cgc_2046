defmodule Cgc2046.Flashback.Endorsements do
  @moduledoc """
  附议写面（U5/R13）：token 身份 + 一人一卡一行（`unique_card_person`）。

  - 幂等：已附议再点 = 更新可认领角色（附议计数不重复 +1）；
  - `consented_at` 记录订阅授权时点（成场通知的配额锚点，U7/U9 消费——
    web 端拿不到小程序订阅授权，按 KTD5 通道分派退回邮件/短信）；
  - 首条附议触发 `proposed → forming`（U7 状态机，R13 卡亮起的第一个可见
    下一步）；
  - 卡不存在 → `flashback_card_not_found`（不泄露存在性区分）。
  """

  require Ash.Query

  alias Cgc2046.Flashback.{ActionCards, ActionCard, Endorsement, Tokens}

  @roles ~w(organizer promoter venue)

  @doc """
  附议（可携带认领角色：organizer / promoter / venue）。
  """
  @spec endorse(term(), String.t(), String.t() | nil) ::
          {:ok, map()} | {:error, term()}
  def endorse(token_plaintext, card_id, role_claimed) do
    with {:ok, token} <- Tokens.fetch_valid(token_plaintext),
         {:ok, card} <- fetch_card(card_id),
         :ok <- validate_role(role_claimed) do
      case fetch_endorsement(card.id, token.person_id) do
        nil -> create_endorsement(card, token.person_id, role_claimed)
        existing -> update_role(card, existing, role_claimed)
      end
    end
  end

  defp fetch_card(card_id) do
    case Ash.get(ActionCard, card_id, authorize?: false) do
      {:ok, card} ->
        {:ok, card}

      _ ->
        {:error,
         %{code: "flashback_card_not_found", message: "card not found", reason: :card_not_found}}
    end
  end

  defp validate_role(nil), do: :ok

  defp validate_role(role) when role in @roles, do: :ok

  defp validate_role(_),
    do: {:error, Tokens.invalid_input_error("role_claimed must be organizer/promoter/venue")}

  defp fetch_endorsement(card_id, person_id) do
    Endorsement
    |> Ash.Query.for_read(:read)
    |> Ash.Query.filter(card_id == ^card_id and person_id == ^person_id)
    |> Ash.read_one(authorize?: false)
    |> case do
      {:ok, endorsement} -> endorsement
      _ -> nil
    end
  end

  defp create_endorsement(card, person_id, role_claimed) do
    Endorsement
    |> Ash.Changeset.for_create(:create, %{
      card_id: card.id,
      person_id: person_id,
      role_claimed: role_claimed
    })
    |> Ash.create(authorize?: false)
    |> case do
      {:ok, endorsement} ->
        # 首条附议：proposed → forming（幂等，已 forming 时静默通过）。
        {:ok, updated_card} = ActionCards.advance_to_forming(card)
        {:ok, payload(updated_card, endorsement, true)}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp update_role(card, existing, role_claimed) do
    existing
    |> Ash.Changeset.for_update(:update_role, %{role_claimed: role_claimed})
    |> Ash.update(authorize?: false)
    |> case do
      {:ok, updated} -> {:ok, payload(card, updated, false)}
      {:error, reason} -> {:error, reason}
    end
  end

  defp payload(card, endorsement, first_time) do
    %{
      card_id: card.id,
      status: card.status,
      role_claimed: endorsement.role_claimed,
      first_time: first_time
    }
  end
end
