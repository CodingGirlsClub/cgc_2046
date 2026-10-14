defmodule Cgc2046.Flashback.RecoverBoundArchiveTest do
  @moduledoc """
  找回铸链接的 R1 不变量回归（绑定即作废全部链接）。

  `Recover.match_people(:email, …)` 原只按 `email == ^email` 过滤，未排除已绑定
  账号 / 已删除的档案；`send_recovery_email/2` 再无条件为每个命中档案铸新 token。
  而绑定侧 `Binding.claim_tokens/2` 只作废「绑定那一刻已存在」的 token，结构化地
  看不到之后新铸的——预留邮箱持有人因此能对他人已绑定的档案重新拿到带全部权限的
  链接（进入/编辑改写联系方式/不可逆删除），静默推翻 R1。

  对照实现：同仓库 `Tokens.query_matched/1`（无 token 自动认领腿）已同时过滤
  `is_nil(user_id)` 与 `is_nil(deleted_at)`；此处补齐同一纪律。
  """

  use Cgc2046.DataCase, async: true

  require Ash.Query

  alias Cgc2046.Accounts.SignInFlow
  alias Cgc2046.Flashback
  alias Cgc2046.Flashback.{Person, Recover, Token}

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
          full_name: "李盼",
          surname: "李",
          city: "北京",
          role: :learner,
          participation: :not_selected
        },
        attrs
      )
    )
    |> Ash.create!(authorize?: false)
  end

  defp bind_to_account(person) do
    {:ok, user, _} = SignInFlow.find_or_create_user("+8613800009999")

    person
    |> Ash.Changeset.for_update(:update, %{})
    |> Ash.Changeset.force_change_attribute(:user_id, user.id)
    |> Ash.update!(authorize?: false)

    user
  end

  defp soft_delete(person) do
    person
    |> Ash.Changeset.for_update(:update, %{})
    |> Ash.Changeset.force_change_attribute(:deleted_at, DateTime.utc_now())
    |> Ash.update!(authorize?: false)
  end

  defp token_count(person) do
    Token
    |> Ash.Query.filter(person_id == ^person.id)
    |> Ash.read!(authorize?: false)
    |> length()
  end

  defp collect_recovery_mails do
    drain_mailbox()
    |> Enum.filter(&String.contains?(&1.subject, "闪念间档案入口"))
  end

  defp drain_mailbox(acc \\ []) do
    receive do
      {:email, mail} -> drain_mailbox([mail | acc])
    after
      0 -> Enum.reverse(acc)
    end
  end

  test "已绑定账号的档案不再收到找回链接、不铸新 token" do
    person = create_person(create_archive("recover-bound-1"), %{email: "bound@example.com"})
    _user = bind_to_account(person)

    assert {:ok, %{dispatched: true}} = Recover.initiate("bound@example.com", "5.6.7.8")

    assert collect_recovery_mails() == []
    assert token_count(person) == 0
  end

  test "已软删的档案不再收到找回链接、不铸新 token" do
    person = create_person(create_archive("recover-deleted-1"), %{email: "gone@example.com"})
    soft_delete(person)

    assert {:ok, %{dispatched: true}} = Recover.initiate("gone@example.com", "5.6.7.8")

    assert collect_recovery_mails() == []
    assert token_count(person) == 0
  end

  test "未绑定且未删除的档案照旧收信并铸 token（防过度收窄）" do
    person = create_person(create_archive("recover-open-1"), %{email: "open@example.com"})

    assert {:ok, %{dispatched: true}} = Recover.initiate("open@example.com", "5.6.7.8")

    assert [mail] = collect_recovery_mails()
    assert mail.to == [{"", "open@example.com"}]
    assert token_count(person) == 1
  end

  test "同邮箱多档案：只对未绑定的那些发信" do
    archive = create_archive("recover-mixed-1")
    bound = create_person(archive, %{email: "mixed@example.com", full_name: "绑定者"})
    _user = bind_to_account(bound)
    open = create_person(archive, %{email: "mixed@example.com", full_name: "未绑定者"})

    assert {:ok, %{dispatched: true}} = Recover.initiate("mixed@example.com", "5.6.7.8")

    assert [_mail] = collect_recovery_mails()
    assert token_count(bound) == 0
    assert token_count(open) == 1
  end
end
