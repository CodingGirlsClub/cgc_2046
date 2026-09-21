defmodule Cgc2046.Flashback.WishesTest do
  @moduledoc """
  许愿域（U4/KTD2/KTD3/KTD4）：创建可见性、附议幂等、留言、软删权与
  本人态、城市快照与正文约束、双入口身份落位。
  """

  use Cgc2046.DataCase, async: false

  alias Cgc2046.Flashback.Wishes
  alias Cgc2046.MiniprogramFixtures.Barrier

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

  describe "年度额度（R20：每自然年 3 条，含私有与已软删，删除不退还）" do
    # 直改库回拨 inserted_at（绕过 Ash action；先例：mcp/token_test.exs backdate）。
    # 取去年年中，远离年界两侧偏移边界。
    defp backdate_to_last_year(wish) do
      shanghai_year = DateTime.add(DateTime.utc_now(), 8 * 3600, :second).year

      last_year =
        DateTime.new!(Date.new!(shanghai_year - 1, 6, 1), ~T[12:00:00.000000], "Etc/UTC")

      wish |> change(inserted_at: last_year) |> Repo.update!()
    end

    test "当年 3 条后第 4 条被拒（quota_exceeded）" do
      archive = create_archive()
      person = create_person(archive)

      for i <- 1..3 do
        assert {:ok, _} = Wishes.create_wish(person.id, "愿望 #{i}", "public")
      end

      assert {:error, %{code: "flashback_wish_quota_exceeded"}} =
               Wishes.create_wish(person.id, "第四条", "public")
    end

    test "软删不退还额度：删一条后第 4 条仍被拒" do
      archive = create_archive()
      person = create_person(archive)

      wishes =
        for i <- 1..3 do
          {:ok, wish} = Wishes.create_wish(person.id, "愿望 #{i}", "public")
          wish
        end

      {:ok, _} = Wishes.soft_delete_wish(hd(wishes).id, person.id)

      assert {:error, %{code: "flashback_wish_quota_exceeded"}} =
               Wishes.create_wish(person.id, "删除后再许", "public")
    end

    test "私有愿望也占额度：2 公开 + 1 私有后第 4 条被拒" do
      archive = create_archive()
      person = create_person(archive)

      {:ok, _} = Wishes.create_wish(person.id, "公开一", "public")
      {:ok, _} = Wishes.create_wish(person.id, "公开二", "public")
      {:ok, _} = Wishes.create_wish(person.id, "私有一", "private")

      assert {:error, %{code: "flashback_wish_quota_exceeded"}} =
               Wishes.create_wish(person.id, "第四条", "public")
    end

    test "跨年重置：去年 3 条不占今年额度" do
      archive = create_archive()
      person = create_person(archive)

      for i <- 1..3 do
        {:ok, wish} = Wishes.create_wish(person.id, "去年愿望 #{i}", "public")
        backdate_to_last_year(wish)
      end

      assert {:ok, _} = Wishes.create_wish(person.id, "今年第一条", "public")
      assert Wishes.quota_remaining(person.id) == 2
    end

    test "quota_remaining/1：0 条 → 3，2 条 → 1，3 条 → 0" do
      archive = create_archive()
      person = create_person(archive)

      assert Wishes.quota_remaining(person.id) == 3

      {:ok, _} = Wishes.create_wish(person.id, "一", "public")
      {:ok, _} = Wishes.create_wish(person.id, "二", "private")
      assert Wishes.quota_remaining(person.id) == 1

      {:ok, _} = Wishes.create_wish(person.id, "三", "public")
      assert Wishes.quota_remaining(person.id) == 0
    end
  end

  describe "年度额度并发（R20：person 行 FOR UPDATE 锁串行化）" do
    # 真实连接并发（unboxed）：共享 sandbox 只有一条连接，事务会在连接检出层
    # 被串行化，「去掉 FOR UPDATE」的变异在单连接下测不出；fixture 与计数断言
    # 同走 unboxed 真实提交，on_exit 显式清理真实行
    # （先例：admission/enrollment_concurrency_test.exs）。
    test "10 路并发许愿：恰好 3 成功、7 额度拒绝，库中恰 3 条" do
      barrier = start_supervised!({Barrier, 10})

      {archive, person} =
        unboxed(fn ->
          archive = create_archive()
          {archive, create_person(archive)}
        end)

      on_exit(fn ->
        unboxed(fn ->
          Repo.query!("DELETE FROM flashback_wishes WHERE person_id = $1", [
            Repo.uuid!(person.id)
          ])

          Repo.query!("DELETE FROM flashback_people WHERE id = $1", [Repo.uuid!(person.id)])

          Repo.query!("DELETE FROM flashback_event_archives WHERE id = $1", [
            Repo.uuid!(archive.id)
          ])
        end)
      end)

      results =
        1..10
        |> Enum.map(fn i ->
          Task.async(fn ->
            Barrier.arrive(barrier)
            unboxed(fn -> Wishes.create_wish(person.id, "并发愿望 #{i}", "public") end)
          end)
        end)
        |> Task.await_many(15_000)

      assert Enum.count(results, &match?({:ok, _}, &1)) == 3

      assert Enum.count(
               results,
               &match?({:error, %{code: "flashback_wish_quota_exceeded"}}, &1)
             ) == 7

      assert wishes_count(person.id) == 3
    end
  end

  defp unboxed(fun), do: Ecto.Adapters.SQL.Sandbox.unboxed_run(Cgc2046.Repo, fun)

  defp wishes_count(person_id) do
    %{rows: [[count]]} =
      unboxed(fn ->
        Repo.query!("SELECT COUNT(*) FROM flashback_wishes WHERE person_id = $1", [
          Repo.uuid!(person_id)
        ])
      end)

    count
  end
end
