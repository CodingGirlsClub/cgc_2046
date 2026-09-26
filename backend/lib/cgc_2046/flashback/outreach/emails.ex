defmodule Cgc2046.Flashback.Outreach.Emails do
  @moduledoc """
  闪念间外发邮件模板（U8/KTD6，R23）：每封页脚必带退订链接（R30
  「从第一封邮件起生效」）；HTML + 纯文本双体（纯文本链接同样可点）。
  HTML 全内联样式（QQ/163 等客户端会剥 `<style>` 块），配色对齐 Web 端
  闪念间（flashback.css：暗房 #0a0a0c / 相纸白 / 金 accent #cbbf8f）。

  模板清单与 `Outreach.Dispatch.templates/0` 白名单一一对应：

  - `reconnect`——唤醒首封：真实学员的微博私信原汁原味开场（截图 +
    图下小字引文兜底，禁图客户端仍可读全引文），正文按本人场次日期
    个性化，专属链接为主入口（邮件独有的 token 直达），小程序搜索
    引导为增量（与短信「不发链接」策略同一口径）。

  收件地址、退订链接、截图地址由 worker 传入（退订 token 按 person
  铸造，模板层不自造）；occurred_on 为本人场次日期，可空——档案日期
  缺失时文案降级为「那年」，绝不因 nil 崩整封发送。
  """

  # 逐字引自原图私信（「虽然」起连续到句尾，零删改）——引文与截图上下
  # 并排，任何改写都会被读出对不上。
  @quote_text "虽然我后来一直没有进入 IT 界，还在原岗位上，但刚刚一闪念间想起来曾经参加的这个活动，很想感谢你，感谢你的热情和付出，曾经那么早让我有一小扇窗得以窥见编程世界。"
  @subject "程序媛汇：月亮刚圆过，宜重逢——闪念回当年，系愿于今朝"
  @quote_sign "—— 一位 2013 年 5 月参加 Rails Girls 的学员"
  @mini_program_line "手机上也可以在微信里搜索小程序「程序媛汇」，体验更顺手。"

  # 比特币奖品兑付联系邮箱（R25 人工通道）：显影页提醒（R7 全场告知）在 web 有、
  # 小程序/邮件此前没有；邮件是唯一主动触达「不记得这事的人」的通道，补一行 P.S.。
  @redeem_email "info@codingirlsclub.com"
  @redeem_mailto "mailto:info@codingirlsclub.com?subject=%E6%AF%94%E7%89%B9%E5%B8%81%E5%A5%96%E5%93%81%E5%85%91%E4%BB%98"
  @redeem_text "对了——2014 年 1 月的北京活动现场，赞助方发放过少量比特币作为奖品，此前只有一位同学来兑领过。如果你恰好也是当年的获奖者，欢迎发邮件至 #{@redeem_email} 联系兑付。"

  @doc "唤醒首封（R23）：称呼 + 本人场次日期/场次名（均可空）+ 专属链接。"
  @spec reconnect(
          String.t(),
          String.t() | nil,
          Date.t() | nil,
          String.t() | nil,
          String.t(),
          String.t(),
          String.t()
        ) ::
          Swoosh.Email.t()
  def reconnect(
        to_email,
        display_name,
        occurred_on,
        archive_name,
        enter_url,
        unsub_url,
        screenshot_url
      ) do
    base(to_email, display_name, @subject)
    |> Swoosh.Email.text_body(reconnect_text(display_name, occurred_on, enter_url, unsub_url))
    |> Swoosh.Email.html_body(
      reconnect_html(
        display_name,
        occurred_on,
        archive_name,
        enter_url,
        unsub_url,
        screenshot_url
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

  # 本人场次的展示口径：「{年} 年 {月} 月」；日期缺失（EventArchive.occurred_on
  # 可空）→「那年」。两个模板面共用同一判定，永不崩。
  defp period(nil), do: "那年"
  defp period(%Date{} = d), do: "#{d.year} 年 #{d.month} 月"

  # 页脚自我介绍句按本人场次派生（写死「2012-2018」对新场次不成立）；日期
  # 缺失 → 历史区间兜底句。事实锚点用「报名」——记忆线（当年到场）、圆梦线
  # （报名未去成）、教练（报名执教）全员成立，不随参与形态分叉；不带城市——
  # 一次发送可能覆盖多城，城市进页脚会误导收信人。
  defp footer_line(%Date{} = d, _name),
    do: "你曾在 #{d.year} 年报名过 Rails Girls / Girls Coding Day。"

  defp footer_line(_occurred_on, _archive_name),
    do: "你曾在 2012-2018 年间报名过 Rails Girls / Girls Coding Day。"

  defp reconnect_text(display_name, occurred_on, enter_url, unsub_url) do
    """
    你好，#{display_name || "同学"}：

    月亮刚圆过。宜想念，宜重逢——

    2023 年 4 月，一位 2013 年参加 Rails Girls 的学员，在微博上给我们发来一段话：

    “#{@quote_text}”
    #{@quote_sign}

    一扇窗，开了一个人的十年。#{period(occurred_on)}，你也在一张报名表上写下过自己——那份报名表，每个字都还在。

    打开我的闪念间：#{enter_url}

    打开后，你可以把那份报名表做成卡片保存，也可以找找当年的同伴和教练。
    #{@mini_program_line}

    #{@redeem_text}

    不想再收到此类邮件？取消订阅：#{unsub_url}

    —— CGC 2046
    """
  end

  # 视觉稿即实现（全内联）：暗房底 + 金 kicker + 拍立得白框原图 + 小字引文
  # 兜底（QQ/163 拦远程图时它就是完整引文）+ 相机式 CTA。
  defp reconnect_html(
         display_name,
         occurred_on,
         archive_name,
         enter_url,
         unsub_url,
         screenshot_url
       ) do
    name = escape(display_name || "同学")

    """
    <div style="margin:0;padding:0;background:#0a0a0c;">
    <div style="max-width:640px;margin:0 auto;padding:40px 20px 48px;font-family:-apple-system,'PingFang SC','Microsoft YaHei',sans-serif;">
    <div style="font-size:12px;letter-spacing:6px;color:#cbbf8f;text-align:center;margin-bottom:36px;">IN A FLASH · 闪念间</div>
    <p style="font-size:16px;color:#d9d4ca;line-height:1.8;margin:0 0 18px;">你好，#{name}：</p>
    <p style="font-size:15px;color:#d9d4ca;line-height:1.9;margin:0 0 26px;">月亮刚圆过。宜想念，宜重逢——</p>
    <p style="font-size:15px;color:#d9d4ca;line-height:1.9;margin:0 0 26px;">2023 年 4 月，一位 2013 年参加 Rails Girls 的学员，在微博上给我们发来一段话：</p>
    <div style="background:#ffffff;padding:14px 14px 44px;border-radius:2px;margin:0 0 16px;">
    <img src="#{screenshot_url}" alt="“#{@quote_text}”#{@quote_sign}" style="display:block;width:100%;height:auto;border:0;" />
    </div>
    <p style="font-size:12px;color:#918c82;line-height:1.9;margin:0 0 32px;text-align:center;">“#{@quote_text}”<br>#{@quote_sign}</p>
    <p style="font-size:15px;color:#d9d4ca;line-height:1.9;margin:0 0 32px;">一扇窗，开了一个人的十年。#{period(occurred_on)}，你也在一张报名表上写下过自己——那份报名表，每个字都还在。</p>
    <div style="text-align:center;margin:0 0 22px;"><a href="#{enter_url}" style="display:inline-block;background:#cfcabf;color:#2b2723;font-size:15px;font-weight:600;letter-spacing:2px;padding:13px 46px;border-radius:999px;text-decoration:none;">打开我的闪念间</a></div>
    <p style="font-size:13px;color:#918c82;line-height:1.9;text-align:center;margin:0 0 26px;">打开后，你可以把那份报名表做成卡片保存，<br>也可以找找当年的同伴和教练。<br>#{@mini_program_line}</p>
    <p style="font-size:13px;color:#918c82;line-height:1.9;margin:0 0 40px;">对了——2014 年 1 月的北京活动现场，赞助方发放过少量比特币作为奖品，此前只有一位同学来兑领过。如果你恰好也是当年的获奖者，欢迎<a href="#{@redeem_mailto}" style="color:#cbbf8f;text-decoration:underline;">联系我们</a>兑付。</p>
    <div style="border-top:1px solid #26262a;padding-top:22px;font-size:12px;color:#918c82;line-height:1.9;">这封信来自 CGC 2046「闪念间」——#{footer_line(occurred_on, archive_name)}<br>不想再收到此类邮件？<a href="#{unsub_url}" style="color:#918c82;">取消订阅</a></div>
    </div>
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
