defmodule Cgc2046.Flashback.Outreach.Emails do
  @moduledoc """
  闪念间外发邮件模板（U8/KTD6，R23）：每封页脚必带退订链接（R30
  「从第一封邮件起生效」）；HTML + 纯文本双体（纯文本链接同样可点）。

  模板清单与 `Outreach.Dispatch.templates/0` 白名单一一对应：

  - `reconnect`——唤醒首封（快门开场 + 专属链接）。

  收件地址与退订链接由 worker 传入（退订 token 按 person 铸造，模板层不自造）。
  """

  @doc "唤醒首封（R23）：收件人称呼 + 专属链接（明文 token 只进邮件体）。"
  @spec reconnect(String.t(), String.t() | nil, String.t(), String.t()) :: Swoosh.Email.t()
  def reconnect(to_email, display_name, enter_url, unsub_url) do
    base(to_email, display_name, "闪念间：有一张 12 年前的照片，一直在等你")
    |> Swoosh.Email.text_body(reconnect_text(enter_url, unsub_url))
    |> Swoosh.Email.html_body(
      wrap(
        ~s"""
        <p>2014 年 1 月 11 日，你写下了一份报名表。</p>
        <p>按下快门，白光一闪——那张照片会慢慢显影出当年的你写下的每个字。</p>
        #{cta(enter_url, "打开我的闪念间")}
        #{plain_url(enter_url)}
        """,
        unsub_url
      )
    )
  end

  # ── 内部 ─────────────────────────────────────────────────────────────

  defp base(to_email, display_name, subject) do
    config = Application.get_env(:cgc_2046, Cgc2046.Mailer, [])
    from = Keyword.get(config, :from, "no-reply@example.com")
    from_name = Keyword.get(config, :from_name, "CGC 2046")

    Swoosh.Email.new()
    |> Swoosh.Email.from({from_name, from})
    |> Swoosh.Email.to({display_name || "同学", to_email})
    |> Swoosh.Email.subject(subject)
  end

  defp reconnect_text(enter_url, unsub_url) do
    """
    2014 年 1 月 11 日，你写下了一份报名表。

    按下快门，白光一闪——那张照片会慢慢显影出当年的你写下的每个字。

    打开我的闪念间：#{enter_url}

    不想再收到此类邮件？取消订阅：#{unsub_url}

    —— CGC 2046
    """
  end

  defp cta(url, label) do
    "<p style=\"margin:24px 0;\"><a href=\"#{url}\" style=\"display:inline-block;background:#111;color:#fff;padding:12px 28px;border-radius:999px;text-decoration:none;\">#{escape(label)}</a></p>"
  end

  # 邮件客户端禁图/纯文本视图下的兜底链接（可复制）。
  defp plain_url(url) do
    "<p style=\"color:#888;font-size:12px;\">如果按钮打不开，请复制此地址到浏览器：<br>#{url}</p>"
  end

  # 页脚退订链接是本模块的硬约束（R30）：所有模板共用 wrap/2 收口，漏不掉。
  defp wrap(inner, unsub_url) do
    """
    <div style="max-width:520px;margin:0 auto;font-family:-apple-system,'PingFang SC','Microsoft YaHei',sans-serif;color:#222;line-height:1.7;">
      #{inner}
      <hr style="border:none;border-top:1px solid #eee;margin:32px 0;" />
      <p style="color:#aaa;font-size:12px;">这封信来自 CGC 2046「闪念间」——你在 2012-2018 年间参加过 Rails Girls / Girls Coding Day 的活动。<br />不想再收到此类邮件？<a href="#{unsub_url}" style="color:#888;">取消订阅</a></p>
    </div>
    """
  end

  defp escape(text) when is_binary(text) do
    text
    |> String.replace("&", "&amp;")
    |> String.replace("<", "&lt;")
    |> String.replace(">", "&gt;")
    |> String.replace("\"", "&quot;")
  end
end
