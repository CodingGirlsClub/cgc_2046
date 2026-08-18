defmodule Cgc2046.Miniprogram.UrlScheme do
  @moduledoc """
  微信 URL Scheme 生成（spike）：活动分享深链。

  仅 wechat；jump path = pages/event-detail/index，query = id + kind（无敏感值，见
  docs/01-定稿设计/微信分享与深链-spike结论.md §5）。kind 为 event/course——前端
  `getContent(kind, id)` 按 kind 分流，缺 kind 会静默回落 event 导致 course 内容加载失败。

  配额契约（spike 核实，见 §2）：临时 scheme 最长有效期 30 天（官方错误码 85401，
  SDK moduledoc 的「1 年」为过时表述）。SDK 透传不校验，**调用方必须保证 expires_at
  距今 ≤30 天**；「min(活动结束 + 缓冲, 30 天)」策略见 spike 文档 §6 D1，在实现计划
  落地（本 spike 原型不实现 clamp）。生成端 50 万/日、100 次/秒；2023-12-19 起取消
  一人一链，同 (event_id) 可复用同一 scheme。存储决策见 spike 文档 §6（D2），
  本模块不落存储。
  """
  alias Cgc2046.Miniprogram.WechatClient

  @spec create_event_link(String.t(), String.t(), DateTime.t() | nil) ::
          {:ok, String.t()} | {:error, term()}
  def create_event_link(event_id, kind, expires_at \\ nil) do
    with {:ok, client} <- WechatClient.fetch(),
         {:ok, %Tesla.Env{status: 200, body: %{"openlink" => link}}} <-
           WeChat.MiniProgram.UrlScheme.create_scheme(
             client,
             %{path: "/pages/event-detail/index", query: "id=#{event_id}&kind=#{kind}"},
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
