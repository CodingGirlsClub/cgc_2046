defmodule Cgc2046.Flashback.FlashbackModelTest do
  use Cgc2046.DataCase, async: true

  alias Cgc2046.AccountsFixtures
  alias Cgc2046.Errors.BusinessError
  alias Cgc2046.Flashback
  alias Cgc2046.Flashback.{Answer, Person, Token}

  @moduledoc """
  U1 数据模型守卫：token_hash 唯一、fog_spans 结构/重叠/越界、
  public_slug 撞名与发布锁定（ADR-0014 成套契约）、管理动作的授权面。

  identity 索引名对齐由全仓守卫覆盖（test/cgc_2046/identity_index_guard_test.exs，
  DSL → pg_indexes 自动纳入十张新表）。
  """

  defp create_archive(key \\ "2014-01-11-bj") do
    Flashback.EventArchive
    |> Ash.Changeset.for_create(:create, %{
      key: key,
      name: "Rails Girls Beijing",
      city: "北京",
      occurred_on: ~D[2014-01-11],
      applied_count: 344,
      attended_count: 102
    })
    |> Ash.create!(authorize?: false)
  end

  defp create_person(archive, attrs \\ %{}) do
    attrs =
      Map.merge(
        %{
          full_name: "王小明",
          surname: "王",
          role: :learner,
          participation: :attended,
          phone: "13800001234",
          email: "xiaoming@example.com"
        },
        attrs
      )

    Person
    |> Ash.Changeset.for_create(:create, Map.put(attrs, :archive_event_id, archive.id))
    |> Ash.create!(authorize?: false)
  end

  describe "token_hash 唯一性（KTD2）" do
    test "重复 token_hash 的第二次插入被唯一索引拒绝" do
      archive = create_archive()
      person = create_person(archive)

      Token
      |> Ash.Changeset.for_create(:create, %{
        person_id: person.id,
        token_hash: "a" <> String.duplicate("b", 63)
      })
      |> Ash.create!(authorize?: false)

      assert {:error, %Ash.Error.Invalid{} = error} =
               Token
               |> Ash.Changeset.for_create(:create, %{
                 person_id: person.id,
                 token_hash: "a" <> String.duplicate("b", 63)
               })
               |> Ash.create(authorize?: false)

      # 唯一约束冲突必须落在错误里（match: :exact 携索引名，而不是静默成功）。
      assert Exception.message(error) =~ "token_hash: has already been taken"
    end

    test "不同 hash 可并存（重发即重签新 token，不吊销旧 token）" do
      archive = create_archive()
      person = create_person(archive)

      for i <- 1..2 do
        assert {:ok, _} =
                 Token
                 |> Ash.Changeset.for_create(:create, %{
                   person_id: person.id,
                   token_hash: String.duplicate(<<i + 48>>, 64)
                 })
                 |> Ash.create(authorize?: false)
      end
    end
  end

  describe "fog_spans 结构校验（KTD4）" do
    setup do
      archive = create_archive()
      person = create_person(archive)
      %{person: person}
    end

    defp create_answer(person, spans) do
      Answer
      |> Ash.Changeset.for_create(:create, %{
        person_id: person.id,
        question_key: "self_intro",
        raw_text: "我在盛大做测试，想亲眼看看是不是。",
        fog_spans: spans
      })
      |> Ash.create(authorize?: false)
    end

    test "合法区间入库并规范化为字符串键", %{person: person} do
      text = "我在盛大做测试，想亲眼看看是不是。"
      # 「盛大」= grapheme 2..3（0 基）。
      start = String.length(String.slice(text, 0..1))
      len = String.length("盛大")

      assert {:ok, answer} = create_answer(person, [%{start: start, len: len, reason: "雇主"}])
      assert answer.fog_spans == [%{"start" => start, "len" => len, "reason" => "雇主"}]
    end

    test "区间非法（len 非正 / start 负 / 非整数）拒绝", %{person: person} do
      for bad <- [
            %{start: 0, len: 0},
            %{start: -1, len: 2},
            %{start: 1.5, len: 2},
            %{"start" => 1}
          ] do
        assert {:error, %Ash.Error.Invalid{errors: [err]}} = create_answer(person, [bad])
        assert err.field == :fog_spans
      end
    end

    test "越界（start + len 超出原文 grapheme 长度）拒绝", %{person: person} do
      assert {:error, %Ash.Error.Invalid{errors: [err]}} =
               create_answer(person, [%{start: 14, len: 5}])

      assert err.field == :fog_spans
      assert err.message =~ "span_out_of_bounds"
    end

    test "重叠区间拒绝", %{person: person} do
      assert {:error, %Ash.Error.Invalid{errors: [err]}} =
               create_answer(person, [%{start: 0, len: 4}, %{start: 2, len: 3}])

      assert err.field == :fog_spans
      assert err.message =~ "overlapping_spans"
    end

    test "adjust_fog 只改 spans、raw_text 不可达且校验复用", %{person: person} do
      {:ok, answer} = create_answer(person, [])
      assert String.length(answer.raw_text) > 0

      assert {:error, %Ash.Error.Invalid{errors: [%{field: :fog_spans}]}} =
               answer
               |> Ash.Changeset.for_update(:adjust_fog, %{fog_spans: [%{start: 0, len: 99}]})
               |> Ash.update(authorize?: false)

      assert {:ok, updated} =
               answer
               |> Ash.Changeset.for_update(:adjust_fog, %{fog_spans: [%{start: 0, len: 2}]})
               |> Ash.update(authorize?: false)

      assert updated.fog_spans == [%{"start" => 0, "len" => 2}]
      # 原文不动（KTD4：raw_text 永不改写）。
      assert updated.raw_text == answer.raw_text
    end
  end

  describe "public_slug 契约（R32/R33，ADR-0014）" do
    setup do
      archive = create_archive()

      %{
        archive: archive,
        alice: create_person(archive, %{full_name: "李雷", surname: "李"}),
        bob: create_person(archive, %{full_name: "韩梅梅", surname: "韩"})
      }
    end

    test "撞名 → flashback_slug_taken", %{alice: alice, bob: bob} do
      {:ok, alice} =
        alice
        |> Ash.Changeset.for_update(:update, %{public_slug: "lei-2014-bj"})
        |> Ash.update(authorize?: false)

      assert alice.public_slug == "lei-2014-bj"

      assert {:error,
              %Ash.Error.Invalid{
                errors: [%BusinessError{code: "flashback_slug_taken", fields: [:public_slug]}]
              }} =
               bob
               |> Ash.Changeset.for_update(:update, %{public_slug: "lei-2014-bj"})
               |> Ash.update(authorize?: false)
    end

    test "发布后锁定 → flashback_slug_locked（同值回传不触发）", %{alice: alice} do
      alice =
        alice
        |> Ash.Changeset.for_update(:update, %{public_slug: "lei-2014-bj"})
        |> Ash.update!(authorize?: false)

      # 发布：直接 SQL 置位（发布入口在 U6，此处只钉锁契约）。
      {:ok, _} =
        Ecto.Adapters.SQL.query(
          Cgc2046.Repo,
          "UPDATE flashback_people SET public_slug_published_at = now() WHERE id = $1",
          [Ecto.UUID.dump!(alice.id)]
        )

      locked = Ash.reload!(alice, authorize?: false)

      assert {:error, %Ash.Error.Invalid{errors: [%BusinessError{code: "flashback_slug_locked"}]}} =
               locked
               |> Ash.Changeset.for_update(:update, %{public_slug: "other-slug"})
               |> Ash.update(authorize?: false)

      # 同值回传不算变更，不触发锁定（表单回传场景，同 initiative #588）。
      assert {:ok, _} =
               locked
               |> Ash.Changeset.for_update(:update, %{public_slug: "lei-2014-bj"})
               |> Ash.update(authorize?: false)
    end
  end

  describe "授权面：管理动作 gate 于 PlatformAdmin（U1 变异验证钉住点）" do
    setup do
      archive = create_archive()

      %{
        archive: archive,
        admin: AccountsFixtures.platform_admin("fb-admin"),
        member: AccountsFixtures.register_user("fb-member")
      }
    end

    test "非管理员建 ActionCard 被拒（Forbidden）", %{archive: _archive, member: member} do
      assert {:error, %Ash.Error.Forbidden{}} =
               Flashback.ActionCard
               |> Ash.Changeset.for_create(:create, %{title: "骑行场", city: "北京"})
               |> Ash.create(actor: member)
    end

    test "匿名（actor nil）建 ActionCard 被拒", %{archive: _archive} do
      assert {:error, %Ash.Error.Forbidden{}} =
               Flashback.ActionCard
               |> Ash.Changeset.for_create(:create, %{title: "骑行场", city: "北京"})
               |> Ash.create(authorize?: true)
    end

    test "平台管理员可建可读", %{archive: _archive, admin: admin} do
      assert {:ok, _card} =
               Flashback.ActionCard
               |> Ash.Changeset.for_create(:create, %{title: "骑行场", city: "北京"})
               |> Ash.create(actor: admin)

      assert {:ok, [_]} =
               Flashback.ActionCard
               |> Ash.Query.for_read(:read)
               |> Ash.read(actor: admin)
    end
  end
end
