defmodule Cgc2046Web.OAuthConsentView do
  @moduledoc """
  MCP OAuth 授权同意页（U4；R9/R10、KTD2）。

  挂在库的 `ConsentRouter` 上（`oauth2_server_consent_routes(consent_view: __MODULE__)`）：
  协议字段校验、同意判定与发码都在库里，本模块只负责**渲染**——以及页面必须让用户看清
  的三件事（KTD2 的钓鱼防线）：授权给哪个应用、以哪个 CGC 账号、授权码只回调到哪个地址。

  约定与依赖：

  - 文案经后端 gettext（域 `oauth_consent`，`priv/gettext/{zh_CN,en}`）：msgid 为英文
    原文，`zh_CN` 目录持中文译文。请求 locale 与当前账号由
    `Cgc2046Web.Plugs.OAuthConsentPlug` 提供（视图没有 conn 入参，见该 plug @moduledoc）。
  - 表单字段（`action=approve|deny`、密封令牌 `consent_request`、CSRF `_csrf_token`）与
    隐藏域的 `name="…" value="…"` 属性顺序都是库 `ConsentRouter` 的约定。
  - 样式内联、无静态资源、无脚本：授权页经部署层路径路由直达后端（KTD2），不依赖
    前端资源与 CSP；表单是纯 HTML POST，F5 与无 JS 环境同样可用。
  """

  use Gettext, backend: Cgc2046Web.Gettext

  alias Cgc2046Web.Plugs.OAuthConsentPlug

  @doc """
  渲染同意页（库 `consent_view` 约定入口）。

  assigns（库提供）：`:client_name`、`:client_id`、`:redirect_uri`、`:scope`、
  `:resource`、`:action_path`、`:csrf_token`、`:consent_request`。
  """
  @spec render(:consent, map()) :: iodata()
  def render(:consent, assigns) do
    app = esc(assigns.client_name)
    {account_name, account_email} = account_lines(OAuthConsentPlug.current_account())

    """
    <!DOCTYPE html>
    <html lang="#{html_lang()}">
      <head>
        <meta charset="utf-8" />
        <meta name="viewport" content="width=device-width, initial-scale=1" />
        <meta name="robots" content="noindex, nofollow" />
        <title>#{app_title(assigns.client_name)}</title>
        <style>
          :root { color-scheme: dark; }
          * { box-sizing: border-box; }
          body {
            margin: 0; min-height: 100vh; padding: 24px;
            display: flex; align-items: center; justify-content: center;
            background: #08090a; color: #f7f8f8; line-height: 1.6;
            font-family: -apple-system, BlinkMacSystemFont, "PingFang SC",
              "Hiragino Sans GB", "Microsoft YaHei", "Segoe UI", sans-serif;
            -webkit-font-smoothing: antialiased;
          }
          .card {
            width: 100%; max-width: 520px; padding: 28px 28px 22px;
            background: #0f1011; border: 1px solid rgba(255,255,255,.08);
            border-radius: 14px;
          }
          .brand {
            display: flex; align-items: center; gap: 8px;
            margin-bottom: 20px; color: #8a8f98; font-size: 13px;
          }
          .brand-dot { width: 8px; height: 8px; border-radius: 50%; background: #ea5504; }
          h1 { margin: 0 0 8px; font-size: 20px; line-height: 1.4; }
          .lead { margin: 0 0 20px; color: #d0d6e0; font-size: 14px; }
          .meta {
            margin: 0 0 8px; border: 1px solid rgba(255,255,255,.08);
            border-radius: 10px; overflow: hidden;
          }
          .row { display: flex; gap: 12px; padding: 10px 14px; }
          .row + .row { border-top: 1px solid rgba(255,255,255,.06); }
          .k { flex: 0 0 96px; padding-top: 2px; color: #8a8f98; font-size: 12px; }
          .v { flex: 1; min-width: 0; font-size: 14px; word-break: break-word; }
          .mono {
            font-family: ui-monospace, SFMono-Regular, Menlo, monospace;
            font-size: 12px; color: #d0d6e0; word-break: break-all;
          }
          .chip {
            display: inline-block; margin-left: 6px; padding: 1px 7px;
            border: 1px solid rgba(255,255,255,.14); border-radius: 999px;
            color: #8a8f98; font-size: 11px; vertical-align: 1px;
          }
          .hint { margin: 8px 0 0; color: #8a8f98; font-size: 12px; }
          .actions { display: flex; gap: 10px; margin-top: 22px; }
          button {
            font: inherit; padding: 11px 16px; border-radius: 9px; cursor: pointer;
            color: #f7f8f8; background: transparent; border: 1px solid rgba(255,255,255,.14);
          }
          button.primary {
            flex: 1.7; background: #ea5504; border-color: #ea5504;
            color: #fff; font-weight: 600;
          }
          button.primary:hover { background: #f26a1f; border-color: #f26a1f; }
          button.secondary { flex: 1; }
          button.secondary:hover { background: rgba(255,255,255,.05); }
          button:focus-visible { outline: 2px solid #f26a1f; outline-offset: 2px; }
          .note {
            margin: 20px 0 0; padding-top: 16px; color: #8a8f98; font-size: 12px;
            border-top: 1px solid rgba(255,255,255,.06);
          }
          .note p { margin: 0; }
          .note p + p { margin-top: 6px; }
          @media (max-width: 480px) {
            .card { padding: 22px 18px 18px; }
            .row { flex-direction: column; gap: 2px; }
            .k { flex: none; padding-top: 0; }
            .actions { flex-direction: column; }
          }
        </style>
      </head>
      <body>
        <main class="card">
          <div class="brand"><span class="brand-dot"></span><span>CGC 2046</span></div>
          <h1>#{dgettext("oauth_consent", "Authorize %{app} to connect to your CGC account", %{app: app})}</h1>
          <p class="lead">#{dgettext("oauth_consent", "After connecting, the app acts as you do on this platform — same permissions as your website account, nothing more.")}</p>

          <div class="meta">
            <div class="row">
              <div class="k">#{dgettext("oauth_consent", "Application")}</div>
              <div class="v">
                #{app}
                <div class="mono">#{dgettext("oauth_consent", "Client ID")}: #{esc(assigns.client_id)}</div>
              </div>
            </div>
            <div class="row">
              <div class="k">#{dgettext("oauth_consent", "CGC account")}</div>
              <div class="v">
                #{account_name}
                #{if account_email, do: ~s(<div class="mono">#{account_email}</div>), else: ""}
              </div>
            </div>
            <div class="row">
              <div class="k">#{dgettext("oauth_consent", "Granted access")}</div>
              <div class="v">
                #{dgettext("oauth_consent", "All workspaces of this account")}<span class="chip">#{esc(assigns.scope)}</span>
                <div class="hint">#{dgettext("oauth_consent", "Whatever you can do on the website, this app can do as you; it cannot reach any other account.")}</div>
              </div>
            </div>
            <div class="row">
              <div class="k">#{dgettext("oauth_consent", "Callback address")}</div>
              <div class="v">
                <span class="mono">#{esc(assigns.redirect_uri)}</span>
                <div class="hint">#{dgettext("oauth_consent", "The authorization code is only sent to this address. If you did not start this request from the app above, deny it.")}</div>
              </div>
            </div>
          </div>
          <p class="hint">#{dgettext("oauth_consent", "Connected service")}: <span class="mono">#{esc(assigns.resource)}</span></p>

          <form method="POST" action="#{esc(assigns.action_path)}">
            <input type="hidden" name="_csrf_token" value="#{esc(assigns.csrf_token)}" />
            <input type="hidden" name="consent_request" value="#{esc(assigns.consent_request)}" />
            <div class="actions">
              <button type="submit" name="action" value="approve" class="primary">#{dgettext("oauth_consent", "Approve and continue")}</button>
              <button type="submit" name="action" value="deny" class="secondary">#{dgettext("oauth_consent", "Deny")}</button>
            </div>
          </form>

          <div class="note">
            <p>#{dgettext("oauth_consent", "After approving, keep this page open until the app reports that it is connected.")}</p>
            <p>#{dgettext("oauth_consent", "You can revoke this authorization at any time in your CGC account settings.")}</p>
          </div>
        </main>
      </body>
    </html>
    """
  end

  # 账号展示：库以同一 actor 判定授权人（见 OAuthConsentPlug 的账号桥）。
  # 本 plug 未运行时不是「账号为空」而是布线错误——同意页没有账号展示即钓鱼防线失效，
  # 宁可显式失败也不渲染一个看不出以谁身份授权的页面。
  defp account_lines(nil) do
    raise """
    OAuthConsentPlug 未在 :oauth_consent 管线中提供当前账号：
    Cgc2046Web.Router 的授权页管线必须挂 Cgc2046Web.Plugs.OAuthConsentPlug（load_actor 之后）。
    """
  end

  defp account_lines(%{display_name: name, email: email})
       when is_binary(name) and name != "" do
    {esc(name), (email && esc(email)) || nil}
  end

  defp account_lines(%{email: email}), do: {(email && esc(email)) || "—", nil}

  defp app_title(client_name) do
    dgettext("oauth_consent", "Authorize %{app} to connect to your CGC account", %{
      app: client_name
    })
    |> esc()
  end

  defp html_lang do
    case Gettext.get_locale(Cgc2046Web.Gettext) do
      "zh_CN" -> "zh-CN"
      locale -> locale
    end
  end

  defp esc(value), do: Plug.HTML.html_escape(value |> to_string())
end
