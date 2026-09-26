defmodule Cgc2046.Flashback.BindingTest do
  @moduledoc """
  档案绑定到账号的统一规则（2026-09-26，推广 #932 的「不静默合并」到全部绑定路径）：

  - 档案已属于另一个账号 → `flashback_recover_account_conflict`，不悄悄挪；同一账号重复绑定照旧成功；
  - 绑定即作废这份档案的**全部**链接（R1）——邀请分邮件 / 短信两路各一条，只作废用到的那条，
    别人拿另一条还能再走「收好」把档案挪走；
  - web 收好在验证码通过之后、建账号之前判断归属：不为冲突建账号；验证码错时不透露归属
    （先判断归属会变成试探档案主人号码的探针）；
  - 条件更新防并发：检查之后被别人抢先绑定，写入时拦下。
  """

  use Cgc2046.DataCase, async: true

  require Ash.Query

  alias Cgc2046.Accounts.{PhoneNumber, PhoneVerificationCode, SignInFlow, TokenCredential, User}
  alias Cgc2046.Flashback
  alias Cgc2046.Flashback.{Binding, Person, Token, Tokens}

  defp create_person(attrs \\ %{}) do
    archive =
      Flashback.EventArchive
      |> Ash.Changeset.for_create(:create, %{
        key: "bind-#{System.unique_integer([:positive])}",
        name: "Rails Girls Beijing",
        city: "北京"
      })
      |> Ash.create!(authorize?: false)

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
          participation: :attended
        },
        attrs
      )
    )
    |> Ash.create!(authorize?: false)
  end

  # outreach 邀请的 token 不带前缀（同 outreach_worker）
  defp mint_token(person) do
    plain = :crypto.strong_rand_bytes(32) |> Base.url_encode64(padding: false)
    {:ok, hash} = TokenCredential.hash(plain)

    Token
    |> Ash.Changeset.for_create(:create, %{person_id: person.id, token_hash: hash})
    |> Ash.create!(authorize?: false)

    plain
  end

  defp account(phone) do
    {:ok, user, _created?} = SignInFlow.find_or_create_user(phone)
    user
  end

  defp owned_by(person, user) do
    person
    |> Ash.Changeset.for_update(:update, %{})
    |> Ash.Changeset.force_change_attribute(:user_id, user.id)
    |> Ash.update!(authorize?: false)
  end

  defp owner_id(person), do: Ash.get!(Person, person.id, authorize?: false).user_id

  defp issue_code(phone) do
    {:ok, normalized} = PhoneNumber.normalize(phone)
    {:ok, code, _} = PhoneVerificationCode.issue(normalized, :register)
    {normalized, code}
  end

  defp users_with_phone(normalized) do
    User |> Ash.Query.filter(phone == ^normalized) |> Ash.read!(authorize?: false) |> length()
  end

  describe "web 收好（register_bind）" do
    test "档案已属于另一个账号 → 冲突；不为这个号码建账号，档案不动" do
      other = account("+8613800006001")
      person = create_person() |> owned_by(other)
      token = mint_token(person)
      {phone, code} = issue_code("13900006002")

      assert {:error, %{code: "flashback_recover_account_conflict"}} =
               Tokens.register_bind(token, "13900006002", code, %{})

      assert owner_id(person) == other.id
      assert users_with_phone(phone) == 0
    end

    test "验证码错时只报错码，不透露档案归属（不能拿来试探主人的号码）" do
      other = account("+8613800006011")
      token = create_person() |> owned_by(other) |> mint_token()

      assert {:error, %{code: "invalid_or_expired_code"}} =
               Tokens.register_bind(token, "13900006012", "000000", %{})
    end

    test "号码就是档案主人：再收好照旧成功（幂等）" do
      me = account("+8613800006003")
      person = create_person() |> owned_by(me)
      token = mint_token(person)
      {_phone, code} = issue_code("13800006003")

      assert {:ok, %{bound: true}} = Tokens.register_bind(token, "13800006003", code, %{})
      assert owner_id(person) == me.id
    end

    test "收好成功：这份档案的其他链接一并作废" do
      person = create_person()
      email_link = mint_token(person)
      sms_link = mint_token(person)
      {_phone, code} = issue_code("13900006004")

      assert {:ok, %{bound: true}} = Tokens.register_bind(email_link, "13900006004", code, %{})
      assert {:error, %{code: "flashback_token_claimed"}} = Tokens.fetch_valid(sms_link)
    end
  end

  describe "小程序一键收好（claim_for_user 带链接）" do
    test "档案属于别的账号 → 冲突且不改绑；属于自己 → 成功" do
      me = account("+8613800006005")
      other = account("+8613800006006")
      taken = create_person() |> owned_by(other)

      assert {:error, %{code: "flashback_recover_account_conflict"}} =
               Tokens.claim_for_user(me, mint_token(taken))

      assert owner_id(taken) == other.id

      mine = create_person() |> owned_by(me)
      assert {:ok, %{bound: true}} = Tokens.claim_for_user(me, mint_token(mine))
    end

    test "收好成功：这份档案的其他链接一并作废" do
      me = account("+8613800006007")
      person = create_person()
      first = mint_token(person)
      second = mint_token(person)

      assert {:ok, %{bound: true}} = Tokens.claim_for_user(me, first)
      assert {:error, %{code: "flashback_token_claimed"}} = Tokens.fetch_valid(second)
    end
  end

  test "自动匹配（claim_for_user 不带链接）绑定后，档案的旧邀请链接作废" do
    person = create_person(%{phone: "13900006008"})
    invitation = mint_token(person)
    me = account("13900006008")

    assert {:ok, %{bound: true, bound_count: 1}} = Tokens.claim_for_user(me, nil)
    assert {:error, %{code: "flashback_token_claimed"}} = Tokens.fetch_valid(invitation)
  end

  # web 邮箱注册不验证邮箱（confirmation_required?(false)）：自动匹配只认已验证的手机号——
  # 否则用别人的报名邮箱注册就能把对方档案收进自己名下（并作废对方手里的链接）
  test "自动匹配不认账号邮箱：只有邮箱、没验证过的账号认领不到同邮箱的档案，对方链接照常可用" do
    person = create_person(%{email: "victim@example.com"})
    invitation = mint_token(person)
    squatter = Cgc2046.AccountsFixtures.register_user_with_email("victim@example.com")

    assert {:ok, %{bound: false, bound_count: 0}} = Tokens.claim_for_user(squatter, nil)
    assert is_nil(owner_id(person))
    assert {:ok, _} = Tokens.fetch_valid(invitation)
  end

  test "并发：检查时档案还没主人、写入前被别人抢先绑定 → 条件更新拦下，返回冲突" do
    me = account("+8613800006009")
    other = account("+8613800006010")
    stale = create_person()
    _winner = owned_by(stale, other)

    assert {:error, %{code: "flashback_recover_account_conflict"}} = Binding.bind(stale, me)
    assert owner_id(stale) == other.id
  end
end
