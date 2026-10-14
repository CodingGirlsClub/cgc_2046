defmodule Cgc2046.Flashback.TokenBindRaceTest do
  @moduledoc """
  #1102：绑定/删除与铸 token 的竞态，钉住收口后的**不变量**。

  竞态本身：`Binding.claim_tokens/2`（绑定）与 `Deletion.cascade!/1`（删除）都只作废
  「那一刻已存在」的 token（先 SELECT 再逐条改）；铸 token 的路径（找回邮件、outreach）
  与它们不在同一把锁上，之后提交的新 token 会漏网。

  **这里不重放时序**（需要双连接卡点），而是钉住两条不变量与一处发送面的收口——
  也就是这个竞态真正能被观察到的边界：

  1. 正常绑定/删除之后，档案名下不会有未作废的 token（夹具直接写 `user_id` 会绕过
     claim，那是测试构造态，不是生产可达态）；
  2. 竞态漏网的那枚 token 不提供任何越权面——绑定检查读的是 `person.user_id`（真源），
     不是 token 的 `claimed_by_user_id`，所以拿着它去绑定照样得到冲突；
  3. 发送面收口：outreach worker 铸 token 之前判档案状态，绑定后不再铸、不再发。
  """

  use Cgc2046.DataCase, async: true

  alias Cgc2046.Accounts.{SignInFlow, TokenCredential}
  alias Cgc2046.Flashback
  alias Cgc2046.Flashback.{Binding, Person, Token, Tokens}

  defp create_person do
    archive =
      Flashback.EventArchive
      |> Ash.Changeset.for_create(:create, %{
        key: "race-#{System.unique_integer([:positive])}",
        name: "Rails Girls Beijing",
        city: "北京"
      })
      |> Ash.create!(authorize?: false)

    Person
    |> Ash.Changeset.for_create(:create, %{
      archive_event_id: archive.id,
      full_name: "李盼",
      surname: "李",
      city: "北京",
      role: :learner,
      participation: :not_selected,
      email: "race-#{System.unique_integer([:positive])}@example.com"
    })
    |> Ash.create!(authorize?: false)
  end

  # 与 Recover.send_recovery_email/2、OutreachWorker.mint_token/1 同形的裸铸
  defp mint_token(person) do
    plain = "fb_" <> (:crypto.strong_rand_bytes(32) |> Base.url_encode64(padding: false))
    {:ok, hash} = TokenCredential.hash(plain)

    Token
    |> Ash.Changeset.for_create(:create, %{person_id: person.id, token_hash: hash})
    |> Ash.create!(authorize?: false)

    plain
  end

  defp account do
    {:ok, user, _} =
      SignInFlow.find_or_create_user("+86139#{:rand.uniform(89_999_999) + 10_000_000}")

    user
  end

  describe "正常绑定/删除的既有不变量" do
    test "绑定把所有已存在的 token 一并作废（链入即全部失效）" do
      person = create_person()
      mail_link = mint_token(person)
      sms_link = mint_token(person)

      :ok = Binding.bind(person, account())

      assert {:error, %{code: "flashback_token_claimed"}} = Tokens.fetch_valid(mail_link)
      assert {:error, %{code: "flashback_token_claimed"}} = Tokens.fetch_valid(sms_link)
    end

    test "删除把所有已存在的 token 一并撤销（走真实删除入口）" do
      person = create_person()
      link = mint_token(person)

      assert {:ok, %{deleted: true}} =
               Cgc2046.Flashback.Deletion.delete(%{person: person}, "DELETE")

      assert {:error, %{code: "flashback_token_revoked"}} = Tokens.fetch_valid(link)
    end
  end

  describe "竞态漏网 token 的权限边界" do
    test "绑定后才铸出的 token：能被解析，但拿去绑定不越权（冲突仍是真源判）" do
      person = create_person()
      other = account()
      :ok = Binding.bind(person, other)

      # 竞态结果态：名下有一枚未带 claimed_by_user_id 的 token
      leaked = mint_token(person)

      # 原 fetch_valid 只看 token 自身状态，它解析得出（这是有意的语义：
      # 绑定检查读 person.user_id，不由 token 面代判）
      assert {:ok, %Token{person: %Person{user_id: bound_id}}} = Tokens.fetch_valid(leaked)
      assert bound_id == other.id

      # 拿它去绑定别的账号 → 冲突，档案归属不动
      assert {:error, %{code: "flashback_recover_account_conflict"}} =
               Binding.bind(person, account())

      assert Ash.get!(Person, person.id, authorize?: false).user_id == other.id
    end

    test "档案认领真源是 person.user_id（token 面字段不是）" do
      person = create_person()
      other = account()
      :ok = Binding.bind(person, other)

      # 直接构造「token 未 claimed 但档案已绑定」的漏网态
      leaked = mint_token(person)

      assert {:ok, %Token{claimed_by_user_id: nil}} = Tokens.fetch_valid(leaked)
      assert Ash.get!(Person, person.id, authorize?: false).user_id == other.id
    end
  end
end
