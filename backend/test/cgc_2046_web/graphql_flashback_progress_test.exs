defmodule Cgc2046Web.GraphqlFlashbackProgressTest do
  use Cgc2046Web.ConnCase, async: false

  alias Cgc2046.Accounts.TokenCredential
  alias Cgc2046.Repo
  alias Cgc2046.Flashback.{EventArchive, Person, Token}

  @moduletag :capture_log

  test "enter 的真实 GraphQL 载荷区分未收好与已有主人" do
    archive =
      EventArchive
      |> Ash.Changeset.for_create(:create, %{
        key: "progress-bound-test",
        name: "Progress fixture",
        city: "上海",
        occurred_on: ~D[2014-01-11]
      })
      |> Ash.create!(authorize?: false)

    for bound <- [false, true] do
      person =
        Person
        |> Ash.Changeset.for_create(:create, %{
          full_name: "测试",
          surname: "测",
          role: :learner,
          participation: :attended,
          archive_event_id: archive.id
        })
        |> Ash.create!(authorize?: false)

      if bound do
        user = Cgc2046.AccountsFixtures.register_user("progress-bound")

        person
        |> Ash.Changeset.for_update(:update, %{})
        |> Ash.Changeset.force_change_attribute(:user_id, user.id)
        |> Ash.update!(authorize?: false)
      end

      plain = "fb_" <> Base.url_encode64(:crypto.strong_rand_bytes(32), padding: false)
      {:ok, hash} = TokenCredential.hash(plain)

      Token
      |> Ash.Changeset.for_create(:create, %{person_id: person.id, token_hash: hash})
      |> Ash.create!(authorize?: false)

      response =
        build_conn()
        |> post("/api/graphql", %{
          "query" =>
            "mutation($token: String!) { flashbackEnter(token: $token) { progress { bound } } }",
          "variables" => %{"token" => plain}
        })
        |> json_response(200)

      refute Map.has_key?(response, "errors")
      assert get_in(response, ["data", "flashbackEnter", "progress", "bound"]) == bound
    end
  end

  test "单项 fogSpans 是坏 JSON：投影不抛异常，只丢该段（PR #960 评审）" do
    alias Cgc2046.Flashback.Answer

    archive =
      EventArchive
      |> Ash.Changeset.for_create(:create, %{
        key: "capsule-bad-span-test",
        name: "Capsule bad span fixture",
        city: "上海",
        occurred_on: ~D[2014-01-11]
      })
      |> Ash.create!(authorize?: false)

    person =
      Person
      |> Ash.Changeset.for_create(:create, %{
        full_name: "测试",
        surname: "测",
        role: :learner,
        participation: :attended,
        archive_event_id: archive.id
      })
      |> Ash.create!(authorize?: false)

    Answer
    |> Ash.Changeset.for_create(:create, %{
      person_id: person.id,
      question_key: "self_intro",
      raw_text: "在浦东一家外贸公司跟单，每天和传真机打交道。"
    })
    |> Ash.create!(authorize?: false)

    # 好的一段 + 坏的一段（非 JSON）：坏段只影响自己，不得拖垮整条查询
    Repo.query!(
      "update flashback_answers set fog_spans = $1::jsonb[] where person_id = $2::uuid",
      [
        [
          ~s({"len": 6, "start": 0, "reason": "privacy"}),
          "not-json{{{"
        ],
        Ecto.UUID.dump!(person.id)
      ]
    )

    plain = "fb_" <> Base.url_encode64(:crypto.strong_rand_bytes(32), padding: false)
    {:ok, hash} = TokenCredential.hash(plain)

    Token
    |> Ash.Changeset.for_create(:create, %{person_id: person.id, token_hash: hash})
    |> Ash.create!(authorize?: false)

    response =
      build_conn()
      |> post("/api/graphql", %{
        query: """
        query FlashbackCapsule($token: String) {
          flashbackCapsule(token: $token) {
            me {
              answers { questionKey rawText fogSpans { start len reason } text }
            }
          }
        }
        """,
        variables: %{"token" => plain}
      })
      |> json_response(200)

    assert response["errors"] == nil, inspect(response)
    answer = get_in(response, ["data", "flashbackCapsule", "me", "answers"]) |> List.first()
    assert [%{"start" => 0, "len" => 6}] = answer["fogSpans"]
  end

  test "capsule 的 me.answers.fogSpans 容忍字符串化 jsonb 形态（#941 遗留）" do
    alias Cgc2046.Flashback.Answer

    archive =
      EventArchive
      |> Ash.Changeset.for_create(:create, %{
        key: "capsule-fog-span-test",
        name: "Capsule fog fixture",
        city: "上海",
        occurred_on: ~D[2014-01-11]
      })
      |> Ash.create!(authorize?: false)

    person =
      Person
      |> Ash.Changeset.for_create(:create, %{
        full_name: "测试",
        surname: "测",
        role: :learner,
        participation: :attended,
        archive_event_id: archive.id
      })
      |> Ash.create!(authorize?: false)

    Answer
    |> Ash.Changeset.for_create(:create, %{
      person_id: person.id,
      question_key: "self_intro",
      raw_text: "在浦东一家外贸公司跟单，每天和传真机打交道。"
    })
    |> Ash.create!(authorize?: false)

    # 生产形态：adjustFog 写入后 jsonb 里是「字符串化 map」——用裸 SQL 复现，
    # 走 Ash 写入会被 Ash 读回时解码，测不到裸 Repo 读这条路径
    Repo.query!(
      "update flashback_answers set fog_spans = $1::jsonb[] where person_id = $2::uuid",
      [[~s({"len": 6, "start": 0, "reason": "privacy"})], Ecto.UUID.dump!(person.id)]
    )

    plain = "fb_" <> Base.url_encode64(:crypto.strong_rand_bytes(32), padding: false)
    {:ok, hash} = TokenCredential.hash(plain)

    Token
    |> Ash.Changeset.for_create(:create, %{person_id: person.id, token_hash: hash})
    |> Ash.create!(authorize?: false)

    response =
      build_conn()
      |> post("/api/graphql", %{
        query: """
        query FlashbackCapsule($token: String) {
          flashbackCapsule(token: $token) {
            me {
              answers { questionKey rawText fogSpans { start len reason } }
            }
          }
        }
        """,
        variables: %{"token" => plain}
      })
      |> json_response(200)

    assert response["errors"] == nil, inspect(response)
    answer = get_in(response, ["data", "flashbackCapsule", "me", "answers"]) |> List.first()
    assert answer["questionKey"] == "self_intro"
    assert [%{"start" => 0, "len" => 6}] = answer["fogSpans"]
  end
end
