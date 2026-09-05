defmodule Cgc2046.Integrations.Wechat.UrlScheme do
  @moduledoc """
  微信 URL Scheme 生成（spike）：活动分享深链。

  仅 wechat；jump path = pages/event-detail/index，query = id + kind（无敏感值）。kind 为 event/course——前端
  `getContent(kind, id)` 按 kind 分流，缺 kind 会静默回落 event 导致 course 内容加载失败。

  配额契约（spike 核实）：临时 scheme 最长有效期 30 天（官方错误码 85401，
  SDK moduledoc 的「1 年」为过时表述）。SDK 透传不校验，**调用方必须保证 expires_at
  距今 ≤30 天**；clamp 策略在 `ShareSchemeService` 落地（D-1：min(目标
  registration_deadline + 7d, now + 30d)）。生成端 50 万/日、100 次/秒；
  2023-12-19 起取消一人一链，同目标可复用同一 scheme（存储/复用在
  `ShareScheme` 资源）。
  """
  alias Cgc2046.Integrations.Wechat.SdkClient

  @doc """
  生成 URL Scheme（spike 原型；存储/复用/clamp 在 `ShareSchemeService`）。

  `target_id` 为目标内容 id（event/course 通用，plan 011 P2 改名——原
  `event_id` 对 kind=course 名不副实；调用方仅测试与该服务）。
  """
  @spec create_link(String.t(), String.t(), DateTime.t() | nil) ::
          {:ok, String.t()} | {:error, term()}
  def create_link(target_id, kind, expires_at \\ nil) do
    with {:ok, client} <- SdkClient.fetch(),
         {:ok, %Tesla.Env{status: 200, body: %{"openlink" => link}}} <-
           WeChat.MiniProgram.UrlScheme.create_scheme(
             client,
             %{path: "/pages/event-detail/index", query: "id=#{target_id}&kind=#{kind}"},
             expires_at && DateTime.to_unix(expires_at)
           ) do
      {:ok, link}
    else
      {:ok, %Tesla.Env{status: 200, body: %{"errcode" => code, "errmsg" => msg}}} ->
        {:error, {:platform_rejected, code, msg}}

      error ->
        {:error, {:scheme_failed, error}}
    end
  end
end
