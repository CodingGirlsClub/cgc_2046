defmodule Cgc2046.Flashback.QuoteLicenses do
  @moduledoc """
  金句授权行的管理端写面（R38）：平台下线开关 `hidden_at`。

  - **人工红线处理**，无审核流水线、无举报入口（本期边界）；
  - 置位后公开读面立即过滤（`Public.quotes/1` 金句墙 + `Public.profile/1`
    实名档案页），本人视图与本人授权档不受影响（本人仍可在回访处调整档位）；
  - 授权走 Ash policy（PlatformAdmin）——非管理员调用被拒（守卫测试钉住），
    GraphQL 层的 `with_admin` 是第二道。
  """

  require Ash.Query

  alias Cgc2046.Flashback.QuoteLicense

  @doc """
  下线 / 恢复某人的金句（R38，PlatformAdmin）。
  无授权行 → `flashback_quote_not_found`（不泄露「从未授权」与「不存在」的区别）。
  """
  @spec set_hidden(term(), String.t(), boolean()) ::
          {:ok, %{person_id: String.t(), hidden: boolean()}} | {:error, term()}
  def set_hidden(actor, person_id, hidden?) when is_boolean(hidden?) do
    case fetch_license(person_id) do
      {:ok, nil} ->
        {:error,
         %{
           code: "flashback_quote_not_found",
           message: "quote not found",
           reason: :quote_not_found
         }}

      {:ok, license} ->
        license
        |> Ash.Changeset.for_update(:set_hidden, %{
          hidden_at: if(hidden?, do: DateTime.utc_now(), else: nil)
        })
        |> Ash.update(actor: actor)
        |> case do
          {:ok, _license} -> {:ok, %{person_id: person_id, hidden: hidden?}}
          {:error, error} -> {:error, error}
        end

      {:error, error} ->
        {:error, error}
    end
  end

  defp fetch_license(person_id) when is_binary(person_id) do
    case Ecto.UUID.cast(person_id) do
      {:ok, uuid} ->
        # 定位步骤 authorize?: false（动作的授权在下面的 Ash.update(actor: actor)
        # 由 policy 判定）；非管理员即使定位到也过不了 update 的 PlatformAdmin 门。
        QuoteLicense
        |> Ash.Query.filter(person_id == ^uuid)
        |> Ash.read_one(authorize?: false)

      :error ->
        {:ok, nil}
    end
  end

  defp fetch_license(_), do: {:ok, nil}
end
