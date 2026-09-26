defmodule Cgc2046.FlashbackFixtures do
  @moduledoc """
  闪念间测试共用 fixture。

  ## P2-1 机审通道门之后的挂树语义

  公开愿望默认进人工审核（无微信身份 → 机审 msgSecCheck 不可达 → hidden_at 待审，
  见 `Wishes.build_writer_snapshots/3`）。只测「附议 / 公开层 / 回响 / 举报」等
  其他行为的套件，用 `listed_wish!/3` 直接拿到**已挂树**的愿望——等价于
  admin 放行 + re-list 的终态，不让套件各自关心审核门。
  """

  alias Cgc2046.Flashback.Wishes
  alias Cgc2046.Repo

  @doc """
  创建公开愿望并直挂树（清 hidden_at、置 listed_at）。opts 原样传给
  `Wishes.create_wish/4`（如 `:expected_city`、`:signature_choice`）。
  """
  def listed_wish!(person_id, content, opts \\ []) do
    {:ok, wish} =
      Wishes.create_wish(
        person_id,
        content,
        "public",
        Keyword.merge([public_listing_consent: true], opts)
      )

    Repo.query!(
      "UPDATE flashback_wishes SET listed_at = now(), hidden_at = NULL WHERE id = $1",
      [Repo.uuid!(wish.id)]
    )

    Ash.get!(Cgc2046.Flashback.Wish, wish.id, authorize?: false)
  end

  @doc "把已存在的愿望直挂树（清 hidden_at、置 listed_at）。GraphQL 种子流程用。"
  def list_wish!(wish_id) do
    Repo.query!(
      "UPDATE flashback_wishes SET listed_at = now(), hidden_at = NULL WHERE id = $1",
      [Repo.uuid!(wish_id)]
    )

    :ok
  end

  @doc "给 user 挂微信身份（机审通道可用的前提），返回身份。"
  def attach_wechat_identity!(user_id, uid) do
    Cgc2046.Accounts.UserIdentity
    |> Ash.Changeset.for_create(:upsert, %{provider: :wechat, uid: uid, user_id: user_id})
    |> Ash.create!(authorize?: false)
  end

  @doc "mock 微信 msgSecCheck 通过（有微信身份的写面会真实外呼）。"
  def mock_wechat_check_pass do
    Tesla.Mock.mock(fn %{method: :post, url: "https://api.weixin.qq.com/wxa/msg_sec_check" <> _} ->
      Tesla.Mock.json(%{"errcode" => 0, "result" => %{"suggest" => "pass"}})
    end)
  end
end
