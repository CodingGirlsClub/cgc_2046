defmodule Cgc2046.Flashback.ClaimNotifyBoundTest do
  @moduledoc """
  无 token 自动认领腿的通知对等回归（H2 的即时缓解，不是根治）。

  微信一键收好（`claim_for_user/2` 不带 token）把「账号已验证手机号」与档案
  `phone` 相等当作数据主体证明。但档案手机号来自多年前的报名表（家长/老师
  代填、运营商二次放号），因此该腿可能把**非本人**的档案静默收进当前账号：
  原主人收不到任何通知（token 腿有 `notify_bound/1`，此腿此前完全静默），
  自己的链接被作废，且无自助路径可挽回。

  本文件钉住通知对等：认领成功后必须向档案的原通道发通知。根治（逐档案显式
  确认）属产品决策，不在本次范围。
  """

  use Cgc2046.DataCase, async: true

  require Ash.Query

  alias Cgc2046.Accounts.{PhoneNumber, SignInFlow}
  alias Cgc2046.Flashback
  alias Cgc2046.Flashback.{Person, Tokens}

  defp create_archive(key) do
    Flashback.EventArchive
    |> Ash.Changeset.for_create(:create, %{key: key, name: "Rails Girls Beijing", city: "北京"})
    |> Ash.create!(authorize?: false)
  end

  defp create_person(archive, attrs) do
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

  defp account(phone) do
    {:ok, user, _created?} = SignInFlow.find_or_create_user(phone)
    user
  end

  defp bound_notices do
    drain_mailbox()
    |> Enum.filter(&String.contains?(&1.subject, "已绑定账号"))
  end

  defp drain_mailbox(acc \\ []) do
    receive do
      {:email, mail} -> drain_mailbox([mail | acc])
    after
      0 -> Enum.reverse(acc)
    end
  end

  test "无 token 自动认领命中档案 → 向档案原邮箱发绑定通知（此前静默）" do
    me = account("+8613800006666")
    {:ok, normalized} = PhoneNumber.normalize("+8613800006666")
    _ = me

    person =
      create_person(create_archive("claim-notify-1"), %{
        phone: String.trim_leading(normalized, "+86"),
        email: "owner@example.com"
      })

    assert {:ok, %{bound: true, bound_count: 1}} = Tokens.claim_for_user(me, nil)

    assert [mail] = bound_notices()
    assert mail.to == [{"", "owner@example.com"}]
    assert person.id
  end

  test "带 token 腿的通知行为不受影响（对照）" do
    me = account("+8613800005555")

    person =
      create_person(create_archive("claim-notify-2"), %{
        phone: "13900000022",
        email: "tokened@example.com"
      })

    plain = mint_token(person)

    assert {:ok, %{bound: true}} = Tokens.claim_for_user(me, plain)

    assert [mail] = bound_notices()
    assert mail.to == [{"", "tokened@example.com"}]
  end

  test "无匹配档案 → 不发通知" do
    me = account("+8613800004444")

    assert {:ok, %{bound: false, bound_count: 0}} = Tokens.claim_for_user(me, nil)
    assert bound_notices() == []
  end

  test "档案无邮箱 → 认领照常成功，不因通知缺失而失败" do
    me = account("+8613800003333")

    create_person(create_archive("claim-notify-4"), %{phone: "13800003333"})

    assert {:ok, %{bound: true}} = Tokens.claim_for_user(me, nil)
    assert bound_notices() == []
  end

  defp mint_token(person) do
    alias Cgc2046.Accounts.TokenCredential
    alias Cgc2046.Flashback.Token

    plain = "fb_" <> (:crypto.strong_rand_bytes(32) |> Base.url_encode64(padding: false))
    {:ok, hash} = TokenCredential.hash(plain)

    Token
    |> Ash.Changeset.for_create(:create, %{person_id: person.id, token_hash: hash})
    |> Ash.create!(authorize?: false)

    plain
  end
end
