defmodule Cgc2046Web.FlashbackUnsubscribeController do
  @moduledoc """
  闪念间一键退订端点（U8/R30/KTD6）：邮件页脚链接与短信短链共用
  `GET /api/flashback/unsubscribe?t=<token>`。

  token = `Phoenix.Token`（HMAC 签名 90 天窗）→ 按人抑制 email 与 sms 双通道
  （幂等：重复点击显示已退订，不重复置位）。无需登录、无 JS——邮件/短信里
  点开即完成（R30 不为行使删除权设门槛的同款精神）。

  响应为极简 HTML（前端是 Next.js，退订确认页不值得建路由；backend 直出，
  无内联脚本，样式仅行内 style 属性——邮件客户端同款形态，不涉 CSP nonce）。
  """

  use Cgc2046Web, :controller

  alias Cgc2046.Flashback.Outreach.Dispatch

  def show(conn, %{"t" => token}) do
    case Dispatch.verify_unsubscribe_token(token) do
      {:ok, person_id} ->
        already = Dispatch.unsubscribed?(person_id)
        :ok = Dispatch.unsubscribe_person(person_id)

        body = if already, do: "你已退订。", else: "已为你退订。"

        conn
        |> put_resp_content_type("text/html")
        |> send_resp(200, page(body))

      {:error, :invalid_token} ->
        conn
        |> put_resp_content_type("text/html")
        |> send_resp(
          404,
          page("退订链接无效或已过期。如仍想退订，可在闪念间首页使用自助找回入口联系运营处理。")
        )
    end
  end

  def show(conn, _params) do
    conn
    |> put_resp_content_type("text/html")
    |> send_resp(404, page("退订链接无效。"))
  end

  defp page(body) do
    """
    <!DOCTYPE html>
    <html lang="zh-CN">
    <head><meta charset="utf-8" /><meta name="viewport" content="width=device-width, initial-scale=1" /><title>闪念间 · 退订</title></head>
    <body style="font-family:-apple-system,'PingFang SC',sans-serif;color:#222;background:#fafafa;">
      <div style="max-width:480px;margin:16vh auto 0;padding:0 24px;text-align:center;line-height:1.8;">
        <p style="font-size:20px;">#{body}</p>
        <p style="color:#999;font-size:13px;">此后 CGC 2046 不会再向你发送闪念间相关的邮件与短信。</p>
      </div>
    </body>
    </html>
    """
  end
end
