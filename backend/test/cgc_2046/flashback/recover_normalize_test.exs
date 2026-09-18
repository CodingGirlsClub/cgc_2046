defmodule Cgc2046.Flashback.RecoverNormalizeTest do
  @moduledoc """
  实测 bug 回归：找回 identifier 规范化（R21/KTD7）。

  用户从聊天复制邮箱带上了 Markdown 反引号（\`a@b.c\`），后端精确匹配未
  命中 → 防枚举同文案 → 邮件没发。修复后：trim 空白 + 剥首尾成对包裹符
  （反引号/引号/括号等，嵌套递归）+ 手机号数字归一（空格/横线/括号）。
  本文件钉住「带包裹符的输入与裸输入命中同一条档案」。
  """

  use Cgc2046.DataCase, async: true

  alias Cgc2046.Flashback
  alias Cgc2046.Flashback.{Person, Recover}

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

  test "邮箱：反引号/引号/空白包裹与裸输入同样命中并发信（Swoosh 进程消息可观察面）" do
    archive = create_archive("recover-norm-1")
    create_person(archive, %{email: "lipan2000girl@163.com"})

    assert {:ok, %{dispatched: true}} = Recover.initiate("lipan2000girl@163.com", "5.6.7.8")
    assert {:ok, %{dispatched: true}} = Recover.initiate(" `lipan2000girl@163.com` ", "5.6.7.8")
    assert {:ok, %{dispatched: true}} = Recover.initiate("\"lipan2000girl@163.com\"", "5.6.7.8")
    assert {:ok, %{dispatched: true}} = Recover.initiate("（lipan2000girl@163.com）", "5.6.7.8")
    # 嵌套包裹：反引号再套空白
    assert {:ok, %{dispatched: true}} =
             Recover.initiate("\t` lipan2000girl@163.com `\n", "5.6.7.8")

    mails = collect_recovery_mails()
    assert length(mails) == 5

    for mail <- mails do
      assert mail.to == [{"", "lipan2000girl@163.com"}]

      # 恢复链接只发给预留邮箱；正文带脱敏档案署名（KTD2：明文 token 只进邮件）
      assert String.contains?(mail.text_body, "李*")
      assert String.contains?(mail.text_body, "/flashback/enter?token=")
    end
  end

  test "不成对包裹符不误剥：同形返回且不向错误地址发信" do
    archive = create_archive("recover-norm-2")
    create_person(archive, %{email: "real@example.com"})

    # 单侧反引号 → 剥壳失败 → 按原样匹配 → 未命中 → 静默（同形）
    assert {:ok, %{dispatched: true}} = Recover.initiate("`real@example.com", "5.6.7.8")

    assert collect_recovery_mails() == []
  end

  test "手机号：空格/横线/括号分隔归一后命中（发码通道，不产恢复邮件）" do
    archive = create_archive("recover-norm-3")
    create_person(archive, %{phone: "139-0000-0002", email: "p3@example.com"})

    assert {:ok, %{dispatched: true}} = Recover.initiate(" (139) 000-0002 ", "5.6.7.8")
    assert {:ok, %{dispatched: true}} = Recover.initiate("139 0000 0002", "5.6.7.8")

    # 手机通道走 PhoneVerificationCode 发码——不产生恢复邮件
    assert collect_recovery_mails() == []
  end
end
