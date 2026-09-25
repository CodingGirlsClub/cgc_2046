defmodule Cgc2046Web.GraphqlFlashbackWishTreeTest do
  use Cgc2046Web.ConnCase, async: false
  alias Cgc2046.Flashback.{Wish, WishEchoes}
  alias Cgc2046.{AccountsFixtures, Repo}
  @moduletag :capture_log
  defp query(document) do
    build_conn()
    |> put_req_header("content-type", "application/json")
    |> post("/api/graphql", %{query: document})
    |> json_response(200)
  end

  defp wish(user, city, attrs \\ %{}) do
    Wish
    |> Ash.Changeset.for_create(
      :create,
      Map.merge(
        %{
          content: "合成许愿树测试",
          visibility: "public",
          city: city,
          signature: "匿名",
          listed_at: DateTime.utc_now()
        },
        Map.drop(attrs, [:deleted_at])
      ),
      context: %{wish_author_attributes: %{user_id: user.id}}
    )
    |> Ash.Changeset.force_change_attribute(:deleted_at, attrs[:deleted_at])
    |> Ash.create!(authorize?: false)
  end

  test "城市来源覆盖分页以外的公开愿望，私密、隐藏、删除、未授权城市不泄露" do
    user = AccountsFixtures.register_user("tree-cities")
    for _ <- 1..61, do: wish(user, "北京")
    wish(user, "成都")
    wish(user, "上海", %{visibility: "private"})
    wish(user, "杭州", %{hidden_at: DateTime.utc_now()})
    wish(user, "广州", %{deleted_at: DateTime.utc_now()})
    wish(user, "深圳", %{listed_at: nil})

    assert %{"data" => %{"flashbackWishCities" => cities}} =
             query("{flashbackWishCities{name lngLat}}")

    assert Enum.map(cities, & &1["name"]) == ["北京", "成都"]
    assert Enum.all?(cities, &(length(&1["lngLat"]) == 2))
  end

  test "回响在分页前筛选；草稿与撤销回响、单有附议都不算；城市筛选可组合" do
    user = AccountsFixtures.register_user("tree-echo")
    for _ <- 1..61, do: wish(user, "北京")
    current = wish(user, "成都")
    draft_only = wish(user, "杭州")
    revoked_only = wish(user, "武汉")
    {:ok, draft} = WishEchoes.create_draft(current.id, "已经开始筹备")
    {:ok, _} = WishEchoes.publish(draft.id, Ecto.UUID.generate())
    {:ok, _} = WishEchoes.create_draft(draft_only.id, "尚未公开")
    {:ok, revoked} = WishEchoes.create_draft(revoked_only.id, "撤销的草稿")

    Repo.query!("UPDATE flashback_wish_echoes SET status='revoked' WHERE id=$1", [
      Repo.uuid!(revoked.id)
    ])

    assert %{"data" => %{"flashbackPublicWishes" => [%{"id" => id, "echoCount" => 1}]}} =
             query(~s'{flashbackPublicWishes(withEchoes:true,limit:1,seed:"tree"){id echoCount}}')

    assert id == current.id

    assert %{"data" => %{"flashbackPublicWishes" => []}} =
             query(~s'{flashbackPublicWishes(withEchoes:true,city:"杭州"){id}}')

    assert %{"data" => %{"flashbackPublicWishes" => [%{"id" => ^id}]}} =
             query(~s'{flashbackPublicWishes(withEchoes:true,city:"成都"){id}}')
  end
end
