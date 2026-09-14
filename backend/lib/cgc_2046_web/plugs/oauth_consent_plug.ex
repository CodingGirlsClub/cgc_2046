defmodule Cgc2046Web.Plugs.OAuthConsentPlug do
  @moduledoc """
  授权页（`/oauth/authorize`，U4）的请求级上下文与响应修补。

  库（`ash_authentication_oauth2_server` 0.3.1）在授权页只给两个扩展点：
  `consent_view` 与 `sign_in_path`。视图收到的是**一小组协议字段**（`client_name` /
  `client_id` / `redirect_uri` / `scope` / `resource` / `action_path` / `csrf_token` /
  `consent_request`，无 conn、无 actor），拒绝路径的 `error_description` 在
  `ConsentRouter.handle_post_authorized/4` 里硬编码为 `nil`。本 plug 因此承担三件事，
  都只作用于该路由：

  1. **locale**：按 `Accept-Language` 协商（zh_CN / en），写进程（`Gettext.put_locale`
     ——视图拿不到 conn；Phoenix 每请求一进程，作用域即请求）。授权页与拒绝描述同源。
  2. **账号桥**：把 `load_actor` 落下的当前用户（`conn.private.ash.actor`，与库判定
     授权人的 actor **同一个**）经进程字典交给 `Cgc2046Web.OAuthConsentView` 渲染
     ——视图无 conn 入参，这是唯一通道（作用域同 1）。钓鱼防线要求页面展示
     「以哪个账号授权」，展示源必须与授权源同源，不能另取一路查询。
  3. **拒绝描述**：`before_send` 检查库发出的拒绝 302——`error=access_denied` 且无
     `error_description` 时补一条本地化描述。宿主把 `error_description` 直达用户
     （U2 spike 报告 ②），`nil` 时用户只看到 `user_denied` 这种内部词。库自带描述时
     不重复写入（升级安全）。

  挂在 `:oauth_consent` 管线 `load_actor` 之后（见 `Cgc2046Web.Router`）。
  """

  import Plug.Conn

  use Gettext, backend: Cgc2046Web.Gettext

  alias Ash.PlugHelpers
  alias Cgc2046Web.Gettext, as: Backend

  @account_key {__MODULE__, :account}
  @default_locale "zh_CN"

  @doc false
  def init(opts), do: opts

  @doc false
  def call(conn, _opts) do
    conn
    |> put_request_locale()
    |> put_consent_account()
    |> register_before_send(&describe_denial/1)
  end

  @doc """
  当前渲染中的授权账号（授权页视图用）。

  `nil` 表示本 plug 未在管线中运行——授权页缺账号展示即钓鱼防线失效，调用方应视为
  布线错误（视图直接 raise），不要渲染一个没有账号的同意页。
  """
  @spec current_account() :: %{display_name: String.t() | nil, email: String.t() | nil} | nil
  def current_account, do: Process.get(@account_key)

  @doc """
  按 `Accept-Language` 协商请求 locale（质量值优先，同级按头内顺序）。

  - 命中 zh* → `zh_CN`；命中 en* → `en`
  - 头缺失/为空（非浏览器客户端）→ `zh_CN`（产品默认语言，与 web 的 defaultLocale 一致）
  - 头存在但没有我们支持的语种 → `en`（对非中文用户，英文比中文更可读）
  """
  @spec negotiate_locale(String.t() | nil) :: String.t()
  def negotiate_locale(header) do
    case header do
      nil -> @default_locale
      header -> header |> parse_accept_language() |> pick_locale()
    end
  end

  # ---- locale ----

  defp put_request_locale(conn) do
    locale =
      conn
      |> get_req_header("accept-language")
      |> List.first()
      |> negotiate_locale()

    Gettext.put_locale(Backend, locale)
    conn
  end

  defp parse_accept_language(header) do
    header
    |> String.split(",")
    |> Enum.map(&parse_language_tag/1)
    |> Enum.reject(&is_nil/1)
    # 质量值降序；Enum.sort_by 稳定，同质量值保持头内顺序（RFC 9110 §12.4.2）
    |> Enum.sort_by(fn {_tag, q} -> q end, :desc)
  end

  defp parse_language_tag(entry) do
    case entry |> String.split(";") |> Enum.map(&String.trim/1) do
      ["" | _] ->
        nil

      [tag | params] ->
        case quality(params) do
          q when q > 0.0 -> {String.downcase(tag), q}
          _ -> nil
        end
    end
  end

  defp quality(params) do
    Enum.find_value(params, 1.0, fn
      "q=" <> value ->
        case Float.parse(value) do
          {q, _rest} -> q
          :error -> 1.0
        end

      _ ->
        nil
    end)
  end

  defp pick_locale([]), do: @default_locale

  defp pick_locale(tags) do
    Enum.find_value(tags, "en", fn {tag, _q} -> locale_for_tag(tag) end)
  end

  defp locale_for_tag("zh" <> _), do: "zh_CN"
  defp locale_for_tag("en" <> _), do: "en"
  defp locale_for_tag(_), do: nil

  # ---- 账号桥 ----

  defp put_consent_account(conn) do
    case PlugHelpers.get_actor(conn) do
      nil ->
        conn

      actor ->
        Process.put(@account_key, %{display_name: actor.display_name, email: actor.email})
        conn
    end
  end

  # ---- 拒绝描述 ----

  # 拒绝 302 的形状由库决定（`error=access_denied` + `state` + `iss`，无 description）；
  # 只在这一形状上补描述，其他响应（同意的 302 带 code、协议端点、错误页）原样透传。
  defp describe_denial(%{status: 302} = conn) do
    case get_resp_header(conn, "location") do
      [location] -> put_deny_description(conn, location)
      _ -> conn
    end
  end

  defp describe_denial(conn), do: conn

  defp put_deny_description(conn, location) do
    uri = URI.parse(location)
    params = decode_query(uri.query)

    if params["error"] == "access_denied" and not Map.has_key?(params, "error_description") do
      query = URI.encode_query(Map.put(params, "error_description", deny_description()))

      put_resp_header(conn, "location", URI.to_string(%{uri | query: query}))
    else
      conn
    end
  end

  defp decode_query(nil), do: %{}

  defp decode_query(query) do
    URI.decode_query(query)
  rescue
    # 畸形 query 不是我们的响应（库自己构造 location），不碰
    ArgumentError -> %{}
  end

  defp deny_description do
    dgettext(
      "oauth_consent",
      "You denied the authorization request, so the app did not get access to your account."
    )
  end
end
