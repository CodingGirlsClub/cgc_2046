defmodule Cgc2046.Flashback.RecoverForAccountTest do
  @moduledoc """
  已登录找回（#932）：小程序里「我当年用的是别的手机号」——验证后把档案绑定到**当前
  登录账号**。web 的 `Recover.verify/3` 按验证的号码 find-or-create 账号，已登录场景照搬会
  多造出一个账号；号码或档案已属于别的账号时明确报错，不静默合并。
  """
  use Cgc2046.DataCase, async: true

  require Ash.Query

  alias Cgc2046.Accounts.{PhoneNumber, PhoneVerificationCode, SignInFlow, TokenCredential, User}
  alias Cgc2046.Flashback
  alias Cgc2046.Flashback.{Person, Recover, Token}

  defp create_archive(key \\ "2014-01-11-bj") do
    Flashback.EventArchive
    |> Ash.Changeset.for_create(:create, %{
      key: key,
      name: "Rails Girls Beijing",
      city: "北京",
      occurred_on: ~D[2014-01-11]
    })
    |> Ash.create!(authorize?: false)
  end

  defp create_person(archive, phone, attrs \\ %{}) do
    Person
    |> Ash.Changeset.for_create(
      :create,
      Map.merge(
        %{
          archive_event_id: archive.id,
          full_name: "王晓雨",
          surname: "王",
          city: "北京",
          role: :learner,
          participation: :attended,
          phone: phone
        },
        attrs
      )
    )
    |> Ash.create!(authorize?: false)
  end

  defp account(phone) do
    {:ok, user, _created?} = SignInFlow.find_or_create_user(phone)
    user
  end

  defp issue_code(phone) do
    {:ok, normalized} = PhoneNumber.normalize(phone)
    {:ok, code, _} = PhoneVerificationCode.issue(normalized, :register)
    code
  end

  defp mint_token(person) do
    plain = "fb_" <> (:crypto.strong_rand_bytes(32) |> Base.url_encode64(padding: false))
    {:ok, hash} = TokenCredential.hash(plain)

    Token
    |> Ash.Changeset.for_create(:create, %{person_id: person.id, token_hash: hash})
    |> Ash.create!(authorize?: false)

    plain
  end

  defp reload(person) do
    Person |> Ash.Query.filter(id == ^person.id) |> Ash.read_one!(authorize?: false)
  end

  defp users_with_phone(phone) do
    {:ok, normalized} = PhoneNumber.normalize(phone)
    User |> Ash.Query.filter(phone == ^normalized) |> Ash.read!(authorize?: false) |> length()
  end

  test "用另一个号码验证 → 档案绑定到当前账号；不新建账号；链接 token 作废（R1）" do
    me = account("+8613800007777")
    person = create_person(create_archive(), "13900000011")

    mint_token(person)

    assert {:ok, %{bound: true, cards: [card]}} =
             Recover.verify_for_user("13900000011", issue_code("13900000011"), me)

    assert card.surname_masked == "王**"
    refute inspect(card) =~ "13900000011"
    assert reload(person).user_id == me.id
    assert users_with_phone("13900000011") == 0, "已登录找回不得按验证的号码另建账号"

    token = Token |> Ash.Query.filter(person_id == ^person.id) |> Ash.read_one!(authorize?: false)
    assert token.claimed_by_user_id == me.id
  end

  test "验证的号码已属于另一个账号 → flashback_recover_account_conflict，不绑定" do
    me = account("+8613800007778")
    _other = account("+8613900000012")
    person = create_person(create_archive(), "13900000012")

    assert {:error, %{code: "flashback_recover_account_conflict"}} =
             Recover.verify_for_user("13900000012", issue_code("13900000012"), me)

    assert is_nil(reload(person).user_id)
  end

  test "档案已被别的账号认领 → 同样冲突，不静默改绑" do
    me = account("+8613800007779")
    other = account("+8613800008888")
    person = create_person(create_archive(), "13900000013")

    person
    |> Ash.Changeset.for_update(:update, %{})
    |> Ash.Changeset.force_change_attribute(:user_id, other.id)
    |> Ash.update!(authorize?: false)

    assert {:error, %{code: "flashback_recover_account_conflict"}} =
             Recover.verify_for_user("13900000013", issue_code("13900000013"), me)

    assert reload(person).user_id == other.id
  end

  test "错码与无档案同文案（invalid_or_expired_code）；邮箱不走验证码" do
    me = account("+8613800007780")

    assert {:error, %{code: "invalid_or_expired_code"}} =
             Recover.verify_for_user("13900000014", "000000", me)

    # 码对但库里没有这个号码的档案：与码错同文案，不泄露存在性
    assert {:error, %{code: "invalid_or_expired_code"}} =
             Recover.verify_for_user("13900000015", issue_code("13900000015"), me)

    assert {:error, %{code: "invalid_or_expired_code"}} =
             Recover.verify_for_user("someone@example.com", "000000", me)
  end

  # ── 邮箱找回·贴链接（小程序）：找回邮件里的入口链接贴回小程序，绑到当前账号 ──

  test "贴链接：同邮箱的档案全部绑到当前账号（同手机通道全绑）；链接作废；不新建账号" do
    me = account("+8613800007781")
    first = create_person(create_archive(), nil, %{email: "old@example.com"})
    second = create_person(create_archive("2015-03-07-sh"), nil, %{email: "old@example.com"})
    stranger = create_person(create_archive("2016-05-21-gz"), nil, %{email: "else@example.com"})
    link = "https://example.com/flashback/enter?token=" <> mint_token(first)
    sibling_token = mint_token(second)

    assert {:ok, %{bound: true, cards: cards}} = Recover.claim_link_for_user(link, me)
    assert length(cards) == 2
    assert reload(first).user_id == me.id
    assert reload(second).user_id == me.id
    assert is_nil(reload(stranger).user_id)

    # 同封邮件里的另一条链接随绑定一起作废（R1），与网页入口同一套失效码
    assert {:error, %{code: "flashback_token_claimed"}} =
             Recover.claim_link_for_user(sibling_token, me)
  end

  test "贴链接：档案已被别的账号认领 → flashback_recover_account_conflict，不静默改绑" do
    me = account("+8613800007782")
    other = account("+8613800008889")
    person = create_person(create_archive(), nil, %{email: "taken@example.com"})
    token = mint_token(person)

    person
    |> Ash.Changeset.for_update(:update, %{})
    |> Ash.Changeset.force_change_attribute(:user_id, other.id)
    |> Ash.update!(authorize?: false)

    assert {:error, %{code: "flashback_recover_account_conflict"}} =
             Recover.claim_link_for_user(token, me)

    assert reload(person).user_id == other.id
  end

  test "贴链接：认不出链接 / 链接不存在 → flashback_token_not_found" do
    me = account("+8613800007783")

    assert {:error, %{code: "flashback_token_not_found"}} =
             Recover.claim_link_for_user("随便一段话", me)

    assert {:error, %{code: "flashback_token_not_found"}} =
             Recover.claim_link_for_user("fb_" <> String.duplicate("A", 43), me)
  end
end
