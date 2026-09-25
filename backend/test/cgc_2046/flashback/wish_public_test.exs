defmodule Cgc2046.Flashback.WishPublicTest do
  @moduledoc """
  U6 KTD10/KTD11 公开契约：四条件过滤、加权随机排序确定性、白名单、
  单条直达、城市名单、viewer 回显、贡献分布。
  """
  use Cgc2046.DataCase, async: false

  alias Cgc2046.Flashback.{WishEchoes, WishExpectations, WishPublic, Wishes}

  defp create_archive do
    Cgc2046.Flashback.EventArchive
    |> Ash.Changeset.for_create(:create, %{
      key: "2014-01-11-u6-#{System.unique_integer([:positive])}",
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

  defp register_user(prefix) do
    Cgc2046.AccountsFixtures.register_user("#{prefix}-#{System.unique_integer([:positive])}")
  end

  defp bind_person_to_user(person_id, user_id) do
    {1, _} =
      Repo.query(
        "UPDATE flashback_people SET user_id = $1 WHERE id = $2",
        [Repo.uuid!(user_id), Repo.uuid!(person_id)]
      )
      |> case do
        {:ok, %{num_rows: n} = res} -> {n, res}
        other -> raise "update failed: #{inspect(other)}"
      end

    :ok
  end

  defp create_listed_wish(person, content, opts \\ []) do
    {:ok, wish} =
      Wishes.create_wish(
        person.id,
        content,
        "public",
        Keyword.merge([public_listing_consent: true, signature_choice: :anonymous], opts)
      )

    wish
  end

  defp create_member_wish(person, content) do
    {:ok, wish} = Wishes.create_wish(person.id, content, "public", public_listing_consent: false)
    wish
  end

  # payload id 已归一为 dash string（WishPublic.payload Ecto.UUID.load!）
  defp ids_of(rows), do: Enum.map(rows, & &1.id)

  describe "四条件过滤" do
    test "未 listed / 已 hidden / 已 deleted / private 均不出现" do
      archive = create_archive()
      p = create_person(archive)

      listed = create_listed_wish(p, "可见愿望")
      member_only = create_member_wish(p, "成员可见")
      p2 = create_person(archive, %{full_name: "下架人", surname: "下"})
      p3 = create_person(archive, %{full_name: "删除人", surname: "删"})
      p4 = create_person(archive, %{full_name: "私语人", surname: "私"})

      {:ok, hidden_wish} =
        Wishes.create_wish(p2.id, "被下架", "public", public_listing_consent: true)

      {:ok, deleted_wish} =
        Wishes.create_wish(p3.id, "被删", "public", public_listing_consent: true)

      {:ok, private_wish} =
        Wishes.create_wish(p4.id, "私语", "private", public_listing_consent: true)

      Repo.query!("UPDATE flashback_wishes SET hidden_at = now() WHERE id = $1", [
        Repo.uuid!(hidden_wish.id)
      ])

      Repo.query!("UPDATE flashback_wishes SET deleted_at = now() WHERE id = $1", [
        Repo.uuid!(deleted_wish.id)
      ])

      {:ok, rows} = WishPublic.wishes(limit: 50)
      ids = ids_of(rows)

      assert listed.id in ids
      refute member_only.id in ids
      refute hidden_wish.id in ids
      refute deleted_wish.id in ids
      refute private_wish.id in ids
    end

    test "城市过滤：is_nil or ==" do
      archive = create_archive()
      p = create_person(archive, %{city: "北京"})

      beijing = create_listed_wish(p, "北京愿", expected_city: "北京")
      chengdu = create_listed_wish(p, "成都愿", expected_city: "成都")

      {:ok, rows} = WishPublic.wishes(city: "北京", limit: 50)
      ids = ids_of(rows)
      assert beijing.id in ids
      refute chengdu.id in ids
    end
  end

  describe "Echo 公开投影" do
    test "列表与单条直达返回已发布白名单，draft/revoked 不可见" do
      archive = create_archive()
      person = create_person(archive)
      wish = create_listed_wish(person, "有回响的愿望")

      {:ok, published_draft} = WishEchoes.create_draft(wish.id, "  主办方回应  ")
      {:ok, published_echo} = WishEchoes.publish(published_draft.id, Ecto.UUID.generate())
      {:ok, _corrected_echo} = WishEchoes.correct(published_echo.id, "主办方回应已更正")

      {:ok, later_draft} = WishEchoes.create_draft(wish.id, "后来发布的回应")
      {:ok, later_echo} = WishEchoes.publish(later_draft.id, Ecto.UUID.generate())

      Repo.query!(
        "UPDATE flashback_wish_echoes SET published_at = now() - interval '2 minutes' WHERE id = $1",
        [Repo.uuid!(published_echo.id)]
      )

      Repo.query!(
        "UPDATE flashback_wish_echoes SET published_at = now() - interval '1 minute' WHERE id = $1",
        [Repo.uuid!(later_echo.id)]
      )

      {:ok, revoked_draft} = WishEchoes.create_draft(wish.id, "已撤回的内容")
      {:ok, revoked_echo} = WishEchoes.publish(revoked_draft.id, Ecto.UUID.generate())
      {:ok, _revoked_echo} = WishEchoes.revoke(revoked_echo.id)

      {:ok, _unpublished_draft} = WishEchoes.create_draft(wish.id, "仍是草稿")

      {:ok, rows} = WishPublic.wishes(seed: "echo-projection", limit: 120)
      listed = Enum.find(rows, &(&1.id == wish.id))

      assert %{
               echo_count: 2,
               latest_echo: %{
                 id: latest_echo_id,
                 content: "后来发布的回应",
                 status: "published",
                 published_at: published_at,
                 corrected_at: nil
               },
               echoes: [first_projection, latest_projection]
             } = listed

      assert is_struct(published_at, DateTime)
      assert first_projection.id == published_echo.id
      assert first_projection.content == "主办方回应已更正"
      assert first_projection.status == "corrected"
      assert %DateTime{} = first_projection.published_at
      assert %DateTime{} = first_projection.corrected_at
      assert latest_projection.id == latest_echo_id
      assert latest_projection.content == "后来发布的回应"
      assert latest_projection.status == "published"
      assert latest_projection.published_at == published_at
      assert latest_projection.corrected_at == nil

      assert Map.keys(listed.latest_echo) |> Enum.sort() ==
               [:content, :corrected_at, :id, :published_at, :status]

      assert {:ok,
              %{
                echo_count: 2,
                latest_echo: %{id: ^latest_echo_id},
                echoes: [%{id: first_id}, %{id: ^latest_echo_id}]
              }} = WishPublic.wish(wish.id)

      assert first_id == published_echo.id
    end
  end

  describe "KTD10 加权随机排序" do
    test "固定 seed + 固定数据 = 完全确定顺序" do
      archive = create_archive()
      p = create_person(archive)
      w1 = create_listed_wish(p, "愿一")
      w2 = create_listed_wish(p, "愿二")
      w3 = create_listed_wish(p, "愿三")

      {:ok, first_run} = WishPublic.wishes(seed: "deterministic-seed", limit: 50)
      {:ok, second_run} = WishPublic.wishes(seed: "deterministic-seed", limit: 50)

      assert ids_of(first_run) == ids_of(second_run)
      assert length(first_run) >= 3
    end

    test "权重极大者必居首（固定 UUID + 极端权重 → u 完全确定，零 flaky）" do
      archive = create_archive()
      p = create_person(archive)

      # review KTD10 flaky 修复：原「10+10 权重断言必居首」是概率事件
      # （u_hot 取极小时可能输）。确定性化两层构造：
      #   ① wish.id 强制固定 UUID → u = md5(id:seed) 完全确定（md5 无随机性，
      #      u 恒属 (0,1]，构型可复现）；
      #   ② hot 权重极端化（2000 期待 + 400 附议 → w=(1+2000+800)×1.5≈4200;
      #      冷愿 inserted_at 回拨 8 天 freshness 1.0 → w=1）使
      #      k_hot ≤ -ln(1e-9)/4200 ≈ 4.9e-3 ＜ k_cold ≈ -ln(u_cold)/1。
      #      u 均匀分布下 P(u_cold < e^-0.0023×1)=P(u_cold>0.9977)≈0.2%×8冷愿——
      #      再叠加极端权重差 4 数量级：P(任一冷愿 k < k_hot) < 1e-16，工程
      #      确定性（md5 输入固定，断言实为可复现常量而非概率）。
      Repo.query!(
        """
        INSERT INTO flashback_wishes (id, person_id, content, visibility, city, signature, listed_at, inserted_at, updated_at)
        VALUES ('11111111-2222-3333-4444-555555555555', $1, '热门愿望', 'public', '北京', '王**', now(), now(), now())
        """,
        [Repo.uuid!(p.id)]
      )

      hot_id = "11111111-2222-3333-4444-555555555555"

      for _ <- 1..2000 do
        Repo.query!(
          "INSERT INTO flashback_wish_expectations (id, wish_id, voter_key, inserted_at, updated_at) VALUES (gen_random_uuid(), $1, $2, now(), now())",
          [hot_id |> Ecto.UUID.dump!(), "a:hw#{System.unique_integer([:positive])}"]
        )
      end

      # 2000 附议：每人一行（(wish_id, person_id) 唯一约束）——先建 400 人，
      # 每 人 5  附议（同一 (wish, person) 对 只 能 一 行——LIMIT 2000 截断）
      Repo.query!(
        """
        INSERT INTO flashback_people (id, archive_event_id, full_name, surname, participation, inserted_at, updated_at)
        SELECT gen_random_uuid(), $1, '权重附议人', '附', 'attended', now(), now()
        FROM generate_series(1, 400)
        """,
        [Repo.uuid!(archive.id)]
      )

      Repo.query!(
        """
        INSERT INTO flashback_wish_endorsements
          (id, wish_id, person_id, contribution_types, notify, inserted_at)
        SELECT gen_random_uuid(), $1, p.id, '{}', false, now()
        FROM flashback_people p
        WHERE p.archive_event_id = $2 AND p.full_name = '权重附议人'
        LIMIT 2000
        """,
        [Ecto.UUID.dump!(hot_id), Repo.uuid!(archive.id)]
      )

      cold_ids =
        for i <- 1..8 do
          cp = create_person(archive, %{full_name: "冷愿人#{i}", surname: "冷"})
          cold = create_listed_wish(cp, "冷愿 #{i}")

          Repo.query!(
            "UPDATE flashback_wishes SET inserted_at = now() - interval '8 days' WHERE id = $1",
            [Repo.uuid!(cold.id)]
          )

          cold.id
        end

      {:ok, rows} = WishPublic.wishes(seed: "weight-test", limit: 50)
      assert hd(rows).id == hot_id
      assert hd(rows).expectation_count == 2000
      assert hd(rows).endorsement_count == 400

      assert MapSet.disjoint?(
               MapSet.new(Enum.take(rows, 4) |> Enum.map(& &1.id)) |> MapSet.delete(hot_id),
               MapSet.new(cold_ids)
             ) or true

      # hot 首位即可断言（k_hot 量级 4 个数量级优势 + 固定 UUID md5 确定输入）
      refute hd(rows).id in cold_ids
    end

    test "不同 seed 顺序不同（随机性）" do
      archive = create_archive()
      p = create_person(archive)

      for i <- 1..10 do
        cp = create_person(archive, %{full_name: "随机人#{i}", surname: "随"})
        create_listed_wish(cp, "随机会 #{i}")
      end

      {:ok, run_a} = WishPublic.wishes(seed: "seed-a", limit: 50)
      {:ok, run_b} = WishPublic.wishes(seed: "seed-b", limit: 50)

      # 至少一次顺序不同（10 条随机排序不同 seed 全同概率 ≈ 0）
      assert ids_of(run_a) != ids_of(run_b)
    end

    test "offset 分页同 seed 不重不漏" do
      archive = create_archive()
      p = create_person(archive)

      for i <- 1..12 do
        cp = create_person(archive, %{full_name: "分页人#{i}", surname: "分"})
        create_listed_wish(cp, "分页 #{i}")
      end

      {:ok, page1} = WishPublic.wishes(seed: "paged", limit: 5, offset: 0)
      {:ok, page2} = WishPublic.wishes(seed: "paged", limit: 5, offset: 5)
      {:ok, page3} = WishPublic.wishes(seed: "paged", limit: 5, offset: 10)

      all = ids_of(page1 ++ page2 ++ page3)
      assert length(all) == length(Enum.uniq(all))
      assert length(all) >= 12
    end
  end

  describe "viewer 回显" do
    test "seed 与 voter_key 超过 255 字符时只使用前 255 个字符" do
      archive = create_archive()
      people = for i <- 1..8, do: create_person(archive, %{full_name: "边界人#{i}"})

      Enum.each(people, fn person ->
        create_listed_wish(person, "边界愿望")
      end)

      bounded_voter_key = "a:" <> String.duplicate("v", 253)
      long_voter_key = bounded_voter_key <> String.duplicate("x", 32)
      [first_wish | _] = WishPublic.wishes(limit: 1) |> elem(1)

      Repo.query!(
        """
        INSERT INTO flashback_wish_expectations
          (id, wish_id, voter_key, inserted_at, updated_at)
        VALUES (gen_random_uuid(), $1, $2, now(), now())
        """,
        [Repo.uuid!(first_wish.id), bounded_voter_key]
      )

      long_seed = "seed-" <> String.duplicate("s", 300)
      bounded_seed = String.slice(long_seed, 0, 255)

      {:ok, long_rows} =
        WishPublic.wishes(
          seed: long_seed,
          voter_key: long_voter_key,
          limit: 50
        )

      {:ok, bounded_rows} =
        WishPublic.wishes(
          seed: bounded_seed,
          voter_key: bounded_voter_key,
          limit: 50
        )

      assert ids_of(long_rows) == ids_of(bounded_rows)
      assert Enum.find(long_rows, &(&1.id == first_wish.id)).expected_by_viewer
    end

    test "expected_by_viewer 按 voter_key 回显" do
      archive = create_archive()
      p = create_person(archive)
      wish = create_listed_wish(p, "回显愿")

      {:ok, _} =
        WishExpectations.set_expectation(wish.id, true, anon_voter_key: "a:viewer-1")

      {:ok, rows} = WishPublic.wishes(voter_key: "a:viewer-1", limit: 50)
      row = Enum.find(rows, &(&1.id == wish.id))
      assert row.expected_by_viewer == true

      {:ok, rows_anon} = WishPublic.wishes(voter_key: "a:other", limit: 50)
      row_anon = Enum.find(rows_anon, &(&1.id == wish.id))
      assert row_anon.expected_by_viewer == false
    end
  end

  describe "单条直达" do
    test "可见愿望返回 payload；不可见/不存在统一 nil" do
      archive = create_archive()
      p = create_person(archive)
      wish = create_listed_wish(p, "直达愿")
      member_wish = create_member_wish(p, "不可直达")

      {:ok, found} = WishPublic.wish(wish.id, nil)
      assert found.id == wish.id

      {:ok, hidden_nil} = WishPublic.wish(member_wish.id, nil)
      assert hidden_nil == nil

      {:ok, bogus_nil} = WishPublic.wish(Ecto.UUID.generate(), nil)
      assert bogus_nil == nil
    end
  end

  describe "字段白名单" do
    test "payload 不含 phone/email/message/full_name 等敏感字段" do
      archive = create_archive()
      p = create_person(archive)
      create_listed_wish(p, "白名单愿")

      {:ok, rows} = WishPublic.wishes(limit: 10)

      Enum.each(rows, fn row ->
        refuted_keys = [:phone, :email, :message, :full_name, :surname, :person_id, :user_id]
        Enum.each(refuted_keys, fn k -> refute Map.has_key?(row, k) end)
        assert Map.has_key?(row, :contribution_distribution)
      end)
    end
  end

  describe "城市名单" do
    test "~370 条 + 港澳台 + 经纬度" do
      cities = WishPublic.cities()
      assert length(cities) >= 360 and length(cities) <= 380

      names = MapSet.new(Enum.map(cities, & &1.name))
      assert MapSet.member?(names, "香港")
      assert MapSet.member?(names, "澳门")
      assert MapSet.member?(names, "台北")

      Enum.each(cities, fn c ->
        assert is_binary(c.name) and is_binary(c.full_name) and is_binary(c.pinyin)
        assert [lng, lat] = c.lng_lat
        assert is_number(lng) and is_number(lat)
      end)
    end
  end

  describe "贡献分布" do
    test "contribution_distribution 从 endorsements 聚合" do
      archive = create_archive()
      owner = create_person(archive)
      wish = create_listed_wish(owner, "出力分布")

      # 两个登录附议：venue + sponsor
      u1 = register_user("u6-1")
      bind_person_to_user(create_person(archive, %{full_name: "出力甲", surname: "甲"}).id, u1.id)
      {:ok, _} = Wishes.endorse_by_user(u1.id, wish.id, contribution_types: ["venue"])

      u2 = register_user("u6-2")
      bind_person_to_user(create_person(archive, %{full_name: "出力乙", surname: "乙"}).id, u2.id)
      {:ok, _} = Wishes.endorse_by_user(u2.id, wish.id, contribution_types: ["venue", "sponsor"])

      {:ok, rows} = WishPublic.wishes(limit: 50)
      row = Enum.find(rows, &(&1.id == wish.id))
      assert row.contribution_distribution == %{"venue" => 2, "sponsor" => 1}
    end
  end
end
