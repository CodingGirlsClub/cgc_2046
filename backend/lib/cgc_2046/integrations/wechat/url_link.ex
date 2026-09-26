defmodule Cgc2046.Integrations.Wechat.UrlLink do
  @moduledoc """
  微信 URL Link 生成（#770）：闪念间触达邮件主 CTA 直达小程序。

  与 `UrlScheme`（weixin:// 拉起，微信内生态用）的差异：URL Link 返回
  `https://wxaurl.cn/*` 短链，邮件/外部浏览器可点、微信内多一步官方中转页；
  有效期参数为 `expire_type=1` + `expire_interval`（间隔天数，≤30）。

  `path` 不可带 query（官方约束），动态参数走生成后拼接 `?cq=`（≤256 字符，
  字符集 `[0-9a-zA-Z!#$&'()*+,/:;=?@-._~]`；闪念间明文 token 为 43 字符
  `[A-Za-z0-9_-]`，全量落在允许集内，无需编码——#770 阶段 A 核对结论）。

  SDK wechat 0.20.0 无 UrlLink 模块（仅 `url_scheme.ex`），故经同一 SdkClient
  直调 `POST /wxa/generate_urllink`；access_token 由 SDK Refresher/TokenChecker
  托管，调用方不感知。生成上限 50 万次/天（与加密 scheme 共享），批次级缓存
  （`Cgc2046.Flashback.OutreachLink`）把调用量压到每批次一次。
  """

  alias Cgc2046.Integrations.Wechat.SdkClient

  @doc """
  生成 URL Link。`path` 必须是已发布小程序存在的页面路径（不带 query）；
  `expire_interval` 为有效天数（微信上限 30，本模块不 clamp——调用方
  OutreachLink 缓存按 expires_at 判断复用，超限由微信拒错传播）。
  """
  @spec create_link(String.t(), pos_integer()) :: {:ok, String.t()} | {:error, term()}
  def create_link(path, expire_interval) when is_binary(path) do
    with {:ok, client} <- SdkClient.fetch(),
         {:ok, %Tesla.Env{status: 200, body: %{"url_link" => link}}} <-
           client.post(
             "/wxa/generate_urllink",
             %{path: path, expire_type: 1, expire_interval: expire_interval},
             query: [access_token: client.get_access_token()]
           ) do
      {:ok, link}
    else
      # 未配置是部署事实（非瞬时故障），原样传播——调用方 fail-open 依据。
      {:error, :wechat_not_configured} = error ->
        error

      {:ok, %Tesla.Env{status: 200, body: %{"errcode" => code, "errmsg" => msg}}} ->
        {:error, {:platform_rejected, code, msg}}

      error ->
        {:error, {:urllink_failed, error}}
    end
  end
end
