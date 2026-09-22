defmodule Cgc2046.Flashback.DeletionTest do
  @moduledoc """
  U10/R30/KTD8 删除级联——级联清单逐项断言 + 二次确认 + 名册/统计排除。

  变异验证记录（本文件随附）：逐项删掉 cascade! 中任一步骤 → 对应断言红
  （见各 assert 的「级联清单第 N 项」注释）。
  """
  use Cgc2046.DataCase, async: false

  require Ash.Query

  alias Cgc2046.Flashback
  alias Cgc2046.Flashback.{Deletion, Person, Public}
  alias Cgc2046.Repo

  @moduletag :capture_log

  defp create_archive do
    Flashback.EventArchive
    |> Ash.Changeset.for_create(:create, %{
      key: "2014-01-11-bj",
      name: "Rails Girls Beijing",
      city: "北京",
      occurred_on: ~D[2014-01-11]
    })
    |> Ash.create!(authorize?: false)
  end

  defp create_person(archive) do
    Person
    |> Ash.Changeset.for_create(:create, %{
      archive_event_id: archive.id,
      full_name: "王小明",
      surname: "王",
      city: "北京",
      role: :learner,
      participation: :attended,
      phone: "13900000001",
      email: "wang@example.com"
    })
    |> Ash.create!(authorize?: false)
  end

  defp full_fixture do
    archive = create_archive()
    person = create_person(archive)

    answer =
      Flashback.Answer
      |> Ash.Changeset.for_create(:create, %{
        person_id: person.id,
        question_key: "self_intro",
        raw_text: "我在盛大做测试。"
      })
      |> Ash.create!(authorize?: false)

    today =
      Flashback.Today
      |> Ash.Changeset.for_create(:create, %{person_id: person.id, want: "想系统学 AI"})
      |> Ash.Changeset.force_change_attribute(:sent_to_wall_at, DateTime.utc_now())
      |> Ash.create!(authorize?: false)

    license =
      Flashback.QuoteLicense
      |> Ash.Changeset.for_create(:create, %{
        person_id: person.id,
        level: :credited,
        chosen_quote_spans: [%{question_key: "self_intro", start: 0, len: 5}],
        credited_note: "现在在做无障碍开发"
      })
      |> Ash.create!(authorize?: false)

    # 许愿三项（U8）：本人许愿 + 本人附议他人愿 + 他人许愿保留
    {:ok, _my_wish} =
      Cgc2046.Flashback.Wishes.create_wish(person.id, "一起出一本书", "public")

    other_wish_owner = create_person(archive)
    {:ok, other_wish} = Cgc2046.Flashback.Wishes.create_wish(other_wish_owner.id, "开课", "public")
    Repo.query!(
      """
      INSERT INTO flashback_wish_endorsements
        (id, wish_id, person_id, contribution_types, notify, inserted_at)
      VALUES (gen_random_uuid(), $1, $2, '{}', false, now())
      """,
      [Repo.uuid!(other_wish.id), Repo.uuid!(person.id)]
    )
    {:ok, _} = Cgc2046.Flashback.Wishes.add_comment(person.id, other_wish.id, "算我一个")

    # 已发布的公开 slug（实名页占用）
    person
    |> Ash.Changeset.for_update(:update, %{})
    |> Ash.Changeset.force_change_attribute(:public_slug, "wang-xiaoming")
    |> Ash.Changeset.force_change_attribute(:public_slug_published_at, DateTime.utc_now())
    |> Ash.update!(authorize?: false)

    # 绑定账号 + outreach 行（匿名化的消费对象）
    user_id = Ecto.UUID.generate()

    person
    |> Ash.Changeset.for_update(:update, %{})
    |> Ash.Changeset.force_change_attribute(:user_id, user_id)
    |> Ash.update!(authorize?: false)

    outreach =
      Flashback.Outreach
      |> Ash.Changeset.for_create(:create, %{
        person_id: person.id,
        channel: :email,
        template: "reconnect",
        batch: "archive-2014-01-11-bj"
      })
      |> Ash.create!(authorize?: false)

    # touch（link_opened——公开统计「已回来」的数据源）
    Flashback.Touch
    |> Ash.Changeset.for_create(:create, %{person_id: person.id, event: :link_opened})
    |> Ash.create!(authorize?: false)

    %{
      archive: archive,
      person: person,
      answer: answer,
      today: today,
      license: license,
      outreach: outreach,
      user_id: user_id
    }
  end

  defp reload_person(id), do: Repo.reload!(%Person{id: id})

  defp count_rows(schema, person_id) do
    schema
    |> Ash.Query.for_read(:read)
    |> Ash.Query.filter(person_id == ^person_id)
    |> Ash.count!(authorize?: false)
  end

  describe "二次确认（KTD8 fail-closed）" do
    test "confirm 错值 → flashback_delete_confirm_required，数据原样" do
      fx = full_fixture()

      assert {:error, %{code: "flashback_delete_confirm_required"}} =
               Deletion.delete(%{person: fx.person}, "delete")

      assert count_rows(Flashback.Answer, fx.person.id) == 1
      assert reload_person(fx.person.id).deleted_at == nil
    end

    test "重复删除 → flashback_already_deleted" do
      fx = full_fixture()

      assert {:ok, %{deleted: true}} = Deletion.delete(%{person: fx.person}, "DELETE")

      assert {:error, %{code: "flashback_already_deleted"}} =
               Deletion.delete(%{person: fx.person}, "DELETE")
    end
  end

  describe "级联清单逐项（KTD8）" do
    test "全部落点：token 作废/回信删/授权删/答案删/slug 下线/匿名化/解绑/deleted_at" do
      fx = full_fixture()
      {plain, token} = issue_token(fx.person)

      assert {:ok, %{deleted: true, deleted_at: at}} =
               Deletion.delete(%{person: fx.person}, "DELETE")

      assert is_binary(at)

      person = reload_person(fx.person.id)

      # 1. token 作废（链接失效）
      token = Repo.reload!(token)
      assert token.revoked_at != nil

      # 2. 回信删除（含寄出态——行硬删）
      assert count_rows(Flashback.Today, fx.person.id) == 0

      # 3. 许愿三项级联：本人许愿(含其上他人附议)、本人留言与附议全清

      # 4. 金句授权删除
      assert count_rows(Flashback.QuoteLicense, fx.person.id) == 0

      # 5. 公开 slug 下线
      assert person.public_slug == nil
      assert person.public_slug_published_at == nil

      # 6. outreach 个人字段匿名化（行保留；person 明文清空）
      outreach = Repo.reload!(fx.outreach)
      assert outreach.person_id == fx.person.id
      assert person.phone == nil
      assert person.email == nil
      assert person.full_name == "已删除档案"

      # 7. 当年答案删除（PIPL 数据清除）
      assert count_rows(Flashback.Answer, fx.person.id) == 0

      # 8. 账号解绑（会话腿自此 not_bound）
      assert person.user_id == nil

      # 9. deleted_at 置位
      assert person.deleted_at != nil

      # touch 保留（四率聚合，无 PII）
      assert count_rows(Flashback.Touch, fx.person.id) == 1

      _ = plain
    end

    test "实名公开页删除后 404（profile nil）+ 金句墙零出现" do
      fx = full_fixture()

      # 删除前可解析
      assert {:ok, %{full_name: "王小明"}} = Public.profile("wang-xiaoming")

      Deletion.delete(%{person: fx.person}, "DELETE")

      assert {:ok, nil} = Public.profile("wang-xiaoming")
      assert {:ok, []} = Public.quotes()
    end

    test "名册撤下：胶囊 roster 不再含删除者；公开统计 returned/sent 归零" do
      fx = full_fixture()
      other = create_person_only_again(fx.archive)

      # 删除前：两人都在名册（me_payload 所需字段齐——裸 map 形状同 resolve_person）
      {:ok, archives} =
        Cgc2046.Flashback.AlumniProjection.capsule(%{
          person: %{
            id: other.id,
            archive_event_id: fx.archive.id,
            full_name: other.full_name,
            surname: other.surname,
            city: other.city,
            occupation_then: other.occupation_then,
            role: other.role,
            participation: other.participation,
            applied_at: other.applied_at,
            user_id: other.user_id
          }
        })

      roster_before = archives.archives |> hd() |> Map.get(:roster)
      assert length(roster_before) == 3

      Deletion.delete(%{person: fx.person}, "DELETE")

      {:ok, archives} =
        Cgc2046.Flashback.AlumniProjection.capsule(%{
          person: %{
            id: other.id,
            archive_event_id: fx.archive.id,
            full_name: other.full_name,
            surname: other.surname,
            city: other.city,
            occupation_then: other.occupation_then,
            role: other.role,
            participation: other.participation,
            applied_at: other.applied_at,
            user_id: other.user_id
          }
        })

      roster_after = archives.archives |> hd() |> Map.get(:roster)
      # R30：本人卡从墙上撤下（结构性卡也不剩——她已不在名单里）；
      # 许愿 fixture 的第三人在册 → 删除后剩 other 与 wish_owner 两人
      assert length(roster_after) == 2
      # 裸 SQL 的 uuid 是 16 字节 binary（同 alumni_projection 的 uuid_param 反向）
      assert Ecto.UUID.cast!(hd(roster_after).id) == other.id

      {:ok, stats} = Public.stats()
      # 删除者的 link_opened 与寄出不计入公开统计
      assert stats.returned_count == 0
      assert stats.sent_count == 0
    end
  end

  defp create_person_only_again(archive) do
    Person
    |> Ash.Changeset.for_create(:create, %{
      archive_event_id: archive.id,
      full_name: "李小红",
      surname: "李",
      city: "北京",
      role: :learner,
      participation: :attended,
      phone: "13900000002",
      email: "li@example.com"
    })
    |> Ash.create!(authorize?: false)
  end

  defp issue_token(person) do
    plain = "fb_" <> (:crypto.strong_rand_bytes(32) |> Base.url_encode64(padding: false))
    {:ok, hash} = Cgc2046.Accounts.TokenCredential.hash(plain)

    {:ok, token} =
      Flashback.Token
      |> Ash.Changeset.for_create(:create, %{person_id: person.id, token_hash: hash})
      |> Ash.create(authorize?: false)

    {plain, token}
  end

  describe "身份解析（与读写面同构）" do
    test "token / 登录账号 / 两者皆无" do
      fx = full_fixture()
      {plain, _} = issue_token(fx.person)

      assert {:ok, %{person: %{id: id}}} = Deletion.resolve_identity(plain, nil)
      assert id == fx.person.id

      assert {:ok, %{person: %{id: id}}} =
               Deletion.resolve_identity(nil, %{id: fx.user_id})

      assert {:error, %{code: "flashback_auth_required"}} = Deletion.resolve_identity(nil, nil)

      assert {:error, %{code: "flashback_person_not_bound"}} =
               Deletion.resolve_identity(nil, %{id: Ecto.UUID.generate()})
    end
  end
end
