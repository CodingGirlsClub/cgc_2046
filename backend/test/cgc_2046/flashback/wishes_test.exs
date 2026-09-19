defmodule Cgc2046.Flashback.WishesTest do
  @moduledoc """
  许愿域（U4/KTD2/KTD3/KTD4）：创建可见性、附议幂等、留言、软删权与
  本人态、城市快照与正文约束、双入口身份落位。
  """

  use Cgc2046.DataCase, async: false

  alias Cgc2046.Flashback.{Wishes, Wish}

  defp create_archive do
    Cgc2046.Flashback.EventArchive
    |> Ash.Changeset.for_create(:create, %{
      key: "2014-01-11-bj-w#{System.unique_integer([:positive])}",
      name: "Rails Girls Beijing",
      city: "北京",
      occurred_on: ~D[2014-01-11]
    })
    |> Ash.create!(authorize?: false)
  end

  defp create_person(archive, overrides \\ %{}) do
    Cgc2046.Flashback.Person
    |> Ash.Changeset.for_create(
      :create,
      Map.merge(
        %{
          archive_event_id: archive.id,
          full_name: "王小明",
          surname: "王",
          city: "北京",
          participation: :attended
        },
        overrides
      )
    )
    |> Ash.create!(authorize?: false)
  end

  describe "创建（R5/R6）" do
    test "公开许愿 → list_public；私有 → 仅 list_private" do
      archive = create_archive()
      person = create_person(archive)
      {:ok, public} = Wishes.create_wish(person.id, "一起出一本书", "public")
      {:ok, private} = Wishes.create_wish(person.id, "想学 Rust", "private")

      assert [%{id: public_id}] = Wishes.list_public()
      assert public_id == public.id

      assert [%{id: private_id}] = Wishes.list_private(person.id)
      assert private_id == private.id
      assert [] = Wishes.list_private(create_person(archive, %{full_name: "李雷", surname: "李"}).id)
    end

    test "city 快照自许愿人名册城市（无城市入参）" do
      archive = create_archive()
      person = create_person(archive, %{city: "上海", full_name: "陈静", surname: "陈"})
      {:ok, wish} = Wishes.create_wish(person.id, "开一门 Rust 系统课", "public")
      assert wish.city == "上海"

      person_nil_city = create_person(archive, %{city: nil, full_name: "无城", surname: "无"})
      {:ok, wish2} = Wishes.create_wish(person_nil_city.id, "许愿二", "public")
      assert is_nil(wish2.city)
    end

    test "空白/超长正文 → invalid_content；非法 visibility → invalid_visibility" do
      archive = create_archive()
      person = create_person(archive)

      assert {:error, %{code: "flashback_wish_invalid_content"}} =
               Wishes.create_wish(person.id, "   ", "public")

      assert {:error, %{code: "flashback_wish_invalid_content"}} =
               Wishes.create_wish(person.id, String.duplicate("长", 501), "public")

      assert {:error, %{code: "flashback_wish_invalid_visibility"}} =
               Wishes.create_wish(person.id, "正常内容", "secret")
    end
  end

  describe "附议（R7 幂等）与本人态" do
    test "同人两次附议只计一次；endorsed_by_me 正确" do
      archive = create_archive()
      wisher = create_person(archive)
      endorser = create_person(archive, %{full_name: "李雷", surname: "李"})

      {:ok, wish} = Wishes.create_wish(wisher.id, "一起出一本书", "public")

      assert {:ok, %{endorsement_count: 1, endorsed_by_me: true}} =
               Wishes.endorse(endorser.id, wish.id)

      assert {:ok, %{endorsement_count: 1, endorsed_by_me: true}} =
               Wishes.endorse(endorser.id, wish.id)

      [%{endorsement_count: 1}] = Wishes.list_public()
    end

    test "附议私有/已删愿望 → not_found（不泄露存在性）" do
      archive = create_archive()
      wisher = create_person(archive)
      {:ok, private} = Wishes.create_wish(wisher.id, "私愿", "private")

      assert {:error, %{code: "flashback_wish_not_found"}} =
               Wishes.endorse(
                 create_person(archive, %{full_name: "李雷", surname: "李"}).id,
                 private.id
               )
    end
  end

  describe "留言（R8）与软删（R14/KTD4）" do
    test "留言正序展示；软删后不再显示" do
      archive = create_archive()
      wisher = create_person(archive)
      commenter = create_person(archive, %{full_name: "李雷", surname: "李"})
      {:ok, wish} = Wishes.create_wish(wisher.id, "一起出一本书", "public")

      {:ok, _} = Wishes.add_comment(commenter.id, wish.id, "算我一个")
      {:ok, comments} = Wishes.add_comment(commenter.id, wish.id, "成都可牵头")
      assert length(comments) == 2
      assert length(comments) == 2
      assert Enum.all?(comments, &(&1.commenter_masked =~ "李"))

      [first | _] = comments
      {:ok, _} = Wishes.soft_delete_comment(first.id, commenter.id)
      assert [%{content: "成都可牵头"}] = Wishes.list_comments(wish.id)
    end

    test "删除权：本人可删自己许愿；删他人 forbidden" do
      archive = create_archive()
      wisher = create_person(archive)
      other = create_person(archive, %{full_name: "李雷", surname: "李"})
      {:ok, wish} = Wishes.create_wish(wisher.id, "公开愿望", "public")

      assert {:error, %{code: "flashback_forbidden_wish"}} =
               Wishes.soft_delete_wish(wish.id, other.id)

      assert {:ok, _} = Wishes.soft_delete_wish(wish.id, wisher.id)
      assert [] = Wishes.list_public()
    end

    test "admin? 旁路（MCP 走同一函数 KTD4）" do
      archive = create_archive()
      wisher = create_person(archive)
      admin_actor = create_person(archive, %{full_name: "管理员", surname: "管"})
      {:ok, wish} = Wishes.create_wish(wisher.id, "公开愿望", "public")
      assert {:ok, _} = Wishes.soft_delete_wish(wish.id, admin_actor.id, admin?: true)
      assert [] = Wishes.list_public()
    end
  end
end
