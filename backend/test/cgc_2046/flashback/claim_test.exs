defmodule Cgc2046.Flashback.ClaimTest do
  @moduledoc """
  R27 小程序路径「微信一键收好」+ 三级视角①「登录后自动匹配 → 直接认领」：

  - 带 token：绑定该档案 + 链接作废（claimed_by_user_id 置位）；
  - 不带 token：按登录用户的手机/邮箱匹配未认领档案并全部绑定；
  - 无匹配 → bound: false（前端给找回引导，不假装成功）；
  - 未登录 → auth_required；幂等（重复调用不重复写）。
  """

  use Cgc2046.DataCase, async: true

  require Ash.Query

  alias Cgc2046.Accounts.TokenCredential
  alias Cgc2046.Accounts.SignInFlow
  alias Cgc2046.Flashback
  alias Cgc2046.Flashback.{Answer, Person, QuoteLicense, Token, Tokens}

  defp archive do
    Flashback.EventArchive
    |> Ash.Changeset.for_create(:create, %{
      key: "2014-01-11-bj",
      name: "Rails Girls Beijing",
      city: "北京",
      occurred_on: ~D[2014-01-11],
      applied_count: 344,
      attended_count: 102
    })
    |> Ash.create!(authorize?: false)
  end

  defp person(arch, attrs) do
    Person
    |> Ash.Changeset.for_create(
      :create,
      Map.merge(
        %{
          archive_event_id: arch.id,
          full_name: "王晓雨",
          surname: "王",
          city: "北京",
          occupation_then: "学生",
          role: :learner,
          participation: :attended,
          phone: "13900000001",
          email: "claim@example.com"
        },
        attrs
      )
    )
    |> Ash.create!(authorize?: false)
  end

  defp wall_ready(p) do
    Answer
    |> Ash.Changeset.for_create(:create, %{
      person_id: p.id,
      question_key: "self_intro",
      raw_text: "我想亲眼看看是不是。"
    })
    |> Ash.create!(authorize?: false)

    QuoteLicense
    |> Ash.Changeset.for_create(:create, %{
      person_id: p.id,
      level: :anonymous,
      chosen_quote_spans: [%{"question_key" => "self_intro", "start" => 0, "len" => 5}]
    })
    |> Ash.create!(authorize?: false)

    p
  end

  defp token_for(p) do
    plain = :crypto.strong_rand_bytes(24) |> Base.url_encode64(padding: false)
    {:ok, hash} = TokenCredential.hash(plain)

    Token
    |> Ash.Changeset.for_create(:create, %{person_id: p.id, token_hash: hash})
    |> Ash.create!(authorize?: false)

    plain
  end

  test "带 token：绑定档案 + 链接作废（claimed_by_user_id 置位）" do
    person = person(archive(), %{})
    plain = token_for(person)
    {:ok, user, _created?} = SignInFlow.find_or_create_user("13911110000")

    assert {:ok, %{bound: true, bound_count: 1}} = Tokens.claim_for_user(user, plain)

    reloaded = Ash.get!(Person, person.id, authorize?: false)
    assert reloaded.user_id == user.id

    token = Token |> Ash.Query.filter(person_id == ^person.id) |> Ash.read_one!(authorize?: false)
    assert token.claimed_by_user_id == user.id
    assert token.claimed_at

    # 链接已作废：再进返回 claimed
    assert {:error, %{code: "flashback_token_claimed"}} = Tokens.fetch_valid(plain)
  end

  test "不带 token：按库里手机自动匹配未认领档案并绑定（含圆梦线）" do
    arch = archive()
    attended = person(arch, %{phone: "13911112222", email: "match-a@example.com"})

    dream =
      person(arch, %{
        phone: "13911112222",
        email: "match-b@example.com",
        participation: :not_selected
      })

    _other = person(arch, %{phone: "13900009999", email: "other@example.com"})

    # 走真实入口建号（手机锚定 find-or-create）——手机即身份，无需再改属性
    {:ok, user, _created?} = SignInFlow.find_or_create_user("13911112222")

    assert {:ok, %{bound: true, bound_count: 2, masked_phone: masked}} =
             Tokens.claim_for_user(user, nil)

    assert masked =~ "****"
    assert Ash.get!(Person, attended.id, authorize?: false).user_id == user.id
    assert Ash.get!(Person, dream.id, authorize?: false).user_id == user.id
  end

  test "无匹配 → bound: false（前端给找回引导，不假装成功）" do
    _person = person(archive(), %{phone: "13900000001"})
    {:ok, user, _created?} = SignInFlow.find_or_create_user("13988887777")

    assert {:ok, %{bound: false, bound_count: 0}} = Tokens.claim_for_user(user, nil)
  end

  test "幂等：重复认领不重复写、不报错" do
    person = wall_ready(person(archive(), %{phone: "13922223333"}))
    plain = token_for(person)
    {:ok, user, _created?} = SignInFlow.find_or_create_user("13922223333")

    assert {:ok, %{bound: true}} = Tokens.claim_for_user(user, plain)
    # 链接已作废 → 第二次带 token 会拿到 claimed（不静默成功）
    assert {:error, %{code: "flashback_token_claimed"}} = Tokens.claim_for_user(user, plain)

    # 会话匹配路径重复调用：已绑定（user_id 非空）不再命中 → bound false
    assert {:ok, %{bound: false}} = Tokens.claim_for_user(user, nil)
  end

  test "未登录 → auth_required" do
    assert {:error, %{code: "flashback_auth_required"}} = Tokens.claim_for_user(nil, "whatever")
  end
end
