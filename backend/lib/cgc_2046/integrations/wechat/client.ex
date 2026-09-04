defmodule Cgc2046.Integrations.Wechat.Client do
  @moduledoc """
  小程序三平台服务端 API 客户端（Phase 1：登录会话 + 手机号解密）。

  - `code2session/2`：登录凭证 code → `%{openid, unionid, session_key}`
    （wechat 扁平 errcode / tt err_no+data / xhs code+data+open_id 三种信封在此归一）
  - `decrypt_phone/4`：session_key AES-128-CBC 解密 encryptedData → 归一化手机号（`+区号号码`）

  安全红线：
  - session_key 仅在本模块调用栈内流转——不进日志、DB、GraphQL 响应、error reason。
  - appid/secret 全部来自 runtime config（`:cgc_2046, :miniprogram_platforms`；
    dev/test 为 config.exs dummy 值，prod 由 runtime.exs 经环境变量注入），不硬编码。

  测试注入：`:cgc_2046, :miniprogram_req_plug` 配置 Req plug（test 环境为
  `{Req.Test, Cgc2046.MiniprogramClientStub}`），未配置时走真实 HTTP。
  """
  require Logger

  alias Cgc2046.Integrations.Wechat.SdkClient

  @type platform :: :wechat | :tt | :xhs
  @type session :: %{openid: String.t(), unionid: String.t() | nil, session_key: String.t()}

  # 端点证据（2026-08-08 核实）：
  # - wechat: GET /sns/jscode2session —— 微信官方文档（developers.weixin.qq.com）确认形状。
  # - tt: POST /api/apps/v2/jscode2session —— 抖音开放平台文档 + 社区 SDK 公认形状
  #   （err_no/err_tips + data 信封）；Phase 4 真凭据联调时复核。
  # - xhs: 两步——GET /api/rmp/token 换 access_token（3h），再 GET /api/rmp/session 换会话。
  #   证据：官方《登录态管理》(miniapp.xiaohongshu.com/doc/DC473950) 确认 auth.code2Session
  #   返回 open_id + session_key 且**小红书暂不提供 unionid**；redengineer/redmini#1237
  #   （小红书官方团队答复）与实测在线端点确认 host=miniapp.xiaohongshu.com、/api/rmp/*
  #   路径族、错误信封 {"success":false,"msg":"应用访问令牌不匹配","data":null,"code":410101}
  #   （curl 2026-08-08 实测）；两步流程与"code 必须放 query"见开发者实践记录（tea521、掘金）。
  @endpoints %{
    wechat: %{base_url: "https://api.weixin.qq.com", session_path: "/sns/jscode2session"},
    tt: %{base_url: "https://developer.toutiao.com", session_path: "/api/apps/v2/jscode2session"},
    xhs: %{
      base_url: "https://miniapp.xiaohongshu.com",
      token_path: "/api/rmp/token",
      session_path: "/api/rmp/session"
    }
  }

  @platforms Map.keys(@endpoints)
  def platforms, do: @platforms

  # 落页契约：页面必须存在于 miniprogram/src/app.config.ts。
  # 订阅消息：weapp 有「我的」（profile，本机通知中心）；裁剪端无 profile，
  # 落「我的报名」（三端都注册的 tab 页）。小程序码：join 三端都注册且消费 scene
  # （miniprogram/src/app.tsx useLaunch → pendingScene → join）。
  @notification_page %{
    wechat: "pages/profile/index",
    tt: "pages/my-enrollments/index",
    xhs: "pages/my-enrollments/index"
  }
  @code_page "pages/join/index"

  @doc """
  平台登录凭证换会话。

  成功返回 `{:ok, %{openid, unionid, session_key}}`；失败返回净化后的
  `{:error, reason}`（不含 secret/session_key 等敏感值）。
  """
  @spec code2session(platform, String.t()) :: {:ok, session} | {:error, term}
  def code2session(platform, code) when platform in @platforms and is_binary(code) do
    with {:ok, config} <- platform_config(platform) do
      case platform do
        :xhs -> xhs_code2session(config, code)
        _ -> single_call_code2session(platform, config, code)
      end
    end
  end

  @doc "生成平台小程序码；返回平台响应中的原始图片字节。"
  @spec generate_code(platform, String.t()) :: {:ok, binary()} | {:error, term()}
  def generate_code(platform, scene) when platform in @platforms and is_binary(scene) do
    case platform do
      # wechat 走 SDK client：token 由 SDK 内部缓存/刷新，不现取现用
      :wechat ->
        request_code(:wechat, scene)

      _ ->
        with {:ok, config} <- platform_config(platform),
             {:ok, access_token} <- fetch_api_access_token(platform, config),
             {:ok, image} <- request_code(platform, config, access_token, scene) do
          {:ok, image}
        end
    end
  end

  @doc "发送一次订阅消息；三平台成功信封统一为 `:ok`。"
  @spec send_notification(platform, String.t(), String.t(), map()) ::
          :ok | {:error, term()}
  def send_notification(platform, openid, template_id, data)
      when platform in @platforms and is_binary(openid) and is_binary(template_id) and
             is_map(data) do
    case platform do
      # wechat 走 SDK client：token 由 SDK 内部缓存/刷新，不现取现用
      :wechat ->
        request_notification(:wechat, openid, template_id, data)

      _ ->
        with {:ok, config} <- platform_config(platform),
             {:ok, access_token} <- fetch_api_access_token(platform, config) do
          request_notification(platform, config, access_token, openid, template_id, data)
        end
    end
  end

  defp request_notification(:wechat, openid, template_id, data) do
    with {:ok, client} <- SdkClient.fetch() do
      client
      |> WeChat.MiniProgram.SubscribeMessage.send(openid, template_id, data, %{
        page: @notification_page.wechat
      })
      |> parse_wechat_envelope()
    end
  end

  defp request_notification(:tt, _config, token, openid, template_id, data) do
    "https://open.douyin.com"
    |> req()
    |> Req.post(
      url: "/api/notification/v2/subscription/notify_user/",
      headers: [{"access-token", token}],
      json: %{
        open_id: openid,
        msg_id: template_id,
        page: @notification_page.tt,
        data: data
      }
    )
    |> case do
      {:ok, %Req.Response{status: 200, body: %{"err_no" => 0}}} -> :ok
      response -> parse_platform_failure(response)
    end
  end

  defp request_notification(:xhs, %{notification_path: path}, token, openid, template_id, data) do
    "https://miniapp.xiaohongshu.com"
    |> req()
    |> Req.post(
      url: path,
      headers: [{"access-token", token}],
      json: %{open_id: openid, template_id: template_id, page: @notification_page.xhs, data: data}
    )
    |> case do
      {:ok, %Req.Response{status: 200, body: %{"code" => 0}}} -> :ok
      response -> parse_platform_failure(response)
    end
  end

  defp fetch_api_access_token(:tt, config) do
    "https://open.douyin.com"
    |> req()
    |> Req.post(
      url: "/oauth/client_token/",
      json: %{
        client_key: config.appid,
        client_secret: config.secret,
        grant_type: "client_credential"
      }
    )
    |> parse_access_token(:tt)
  end

  defp fetch_api_access_token(:xhs, config) do
    fetch_xhs_access_token(@endpoints.xhs, config)
  end

  defp parse_access_token(
         {:ok, %Req.Response{status: 200, body: %{"data" => %{"access_token" => token}}}},
         :tt
       )
       when is_binary(token),
       do: {:ok, token}

  defp parse_access_token({:ok, %Req.Response{status: status}}, _),
    do: {:error, {:platform_http_status, status}}

  defp parse_access_token({:error, _}, _), do: {:error, :platform_unreachable}
  defp parse_access_token(_, _), do: {:error, :platform_bad_response}

  defp request_code(:wechat, scene) do
    with {:ok, client} <- SdkClient.fetch() do
      client
      |> WeChat.MiniProgram.Code.create_code_unlimited(scene, %{
        page: @code_page,
        check_path: false
      })
      |> parse_wechat_image()
    end
  end

  defp request_code(:tt, config, token, scene) do
    "https://open.douyin.com"
    |> req()
    |> Req.post(
      url: "/api/apps/v1/qrcode/create/",
      headers: [{"access-token", token}],
      json: %{
        app_name: "douyin",
        appid: config.appid,
        path: "#{@code_page}?scene=#{scene}"
      }
    )
    |> case do
      {:ok, %Req.Response{status: 200, body: %{"data" => %{"img" => encoded}}}}
      when is_binary(encoded) ->
        case Base.decode64(encoded) do
          {:ok, image} -> {:ok, image}
          :error -> {:error, :platform_bad_response}
        end

      response ->
        parse_platform_failure(response)
    end
  end

  defp request_code(:xhs, %{qrcode_path: path}, token, scene) do
    "https://miniapp.xiaohongshu.com"
    |> req()
    |> Req.post(
      url: path,
      headers: [{"access-token", token}],
      json: %{scene: scene, page: @code_page}
    )
    |> case do
      {:ok, %Req.Response{status: 200, body: %{"code" => 0, "data" => data}}}
      when is_map(data) ->
        decode_image_field(data["base64"] || data["qrcode"] || data["url"])

      response ->
        parse_platform_failure(response)
    end
  end

  # SDK 信封：成功 {:ok, %Tesla.Env{status: 200, body: %{"errcode" => 0}}}；
  # 业务失败 200 + %{"errcode" => code, "errmsg" => msg}——errcode 保真出栈。
  defp parse_wechat_envelope({:ok, %Tesla.Env{status: 200, body: %{"errcode" => 0}}}), do: :ok

  defp parse_wechat_envelope(
         {:ok, %Tesla.Env{status: 200, body: %{"errcode" => code, "errmsg" => msg}}}
       )
       when is_integer(code),
       do: {:error, {:platform_rejected, code, msg}}

  defp parse_wechat_envelope({:ok, %Tesla.Env{status: status}}),
    do: {:error, {:platform_http_status, status}}

  defp parse_wechat_envelope({:error, _}), do: {:error, :platform_unreachable}
  defp parse_wechat_envelope(_), do: {:error, :platform_bad_response}

  # 成功 body 为图片二进制；错误 body 为 JSON map（Tesla.Middleware.JSON 已解码）。
  defp parse_wechat_image({:ok, %Tesla.Env{status: 200, body: body}}) when is_binary(body),
    do: {:ok, body}

  defp parse_wechat_image(
         {:ok, %Tesla.Env{status: 200, body: %{"errcode" => code, "errmsg" => msg}}}
       )
       when is_integer(code),
       do: {:error, {:platform_rejected, code, msg}}

  defp parse_wechat_image(response), do: parse_wechat_envelope(response)

  defp decode_image_field("data:image" <> _ = data_uri) do
    case String.split(data_uri, ",", parts: 2) do
      [_, encoded] -> decode_image_field(encoded)
      _ -> {:error, :platform_bad_response}
    end
  end

  defp decode_image_field(encoded) when is_binary(encoded) do
    case Base.decode64(encoded) do
      {:ok, image} -> {:ok, image}
      :error -> {:error, :platform_bad_response}
    end
  end

  defp decode_image_field(_), do: {:error, :platform_bad_response}

  # 200 + JSON 错误体（Req 已解码为 map）——先提 errcode/err_no/code，再谈 HTTP 状态。
  # 避免微信 43101（拒收）/抖音小红书同构错误被压平成 {:platform_http_status, 200}。
  defp parse_platform_failure(
         {:ok, %Req.Response{status: 200, body: %{"errcode" => code, "errmsg" => msg}}}
       )
       when is_integer(code) and code != 0,
       do: {:error, {:platform_rejected, code, msg}}

  defp parse_platform_failure(
         {:ok, %Req.Response{status: 200, body: %{"err_no" => code, "err_msg" => msg}}}
       )
       when is_integer(code) and code != 0,
       do: {:error, {:platform_rejected, code, msg || ""}}

  defp parse_platform_failure(
         {:ok, %Req.Response{status: 200, body: %{"code" => code, "msg" => msg}}}
       )
       when is_integer(code) and code != 0,
       do: {:error, {:platform_rejected, code, msg || ""}}

  defp parse_platform_failure({:ok, %Req.Response{status: status}}),
    do: {:error, {:platform_http_status, status}}

  defp parse_platform_failure({:error, _}), do: {:error, :platform_unreachable}
  defp parse_platform_failure(_), do: {:error, :platform_bad_response}

  defp single_call_code2session(platform, config, code) do
    endpoint = @endpoints[platform]

    request =
      case platform do
        :wechat ->
          [
            method: :get,
            url: endpoint.session_path,
            params: [
              appid: config.appid,
              secret: config.secret,
              js_code: code,
              grant_type: "authorization_code"
            ]
          ]

        :tt ->
          [
            method: :post,
            url: endpoint.session_path,
            json: %{appid: config.appid, secret: config.secret, code: code}
          ]
      end

    endpoint.base_url
    |> req()
    |> Req.request(request)
    |> case do
      {:ok, %Req.Response{status: 200, body: body}} ->
        # 防枚举只约束客户端可见性；服务端必须留失败原因（errcode 定位
        # 40029/40163 code 失效、40125 secret、45011 频控），否则真机联调
        # 只见 "Platform sign in failed" 无从排查（#99 真机验收实证）。
        case parse_session(platform, body) do
          {:ok, _} = ok ->
            ok

          {:error, reason} = error ->
            Logger.warning("[code2session] #{platform} rejected: #{inspect(reason)}")
            error
        end

      {:ok, %Req.Response{status: status}} ->
        Logger.warning("[code2session] #{platform} http status #{status}")
        {:error, {:platform_http_status, status}}

      {:error, _reason} ->
        {:error, :platform_unreachable}
    end
  end

  # xhs 两步（证据见 @endpoints 注释）：先 app_id/app_secret 换 access_token，
  # 再带 access_token + code 换会话。v1 不缓存 token（登录 QPS 极低；
  # 3h 有效期的缓存/刷新是 Phase 4 联调期的优化项）。
  defp xhs_code2session(config, code) do
    endpoint = @endpoints.xhs

    with {:ok, access_token} <- fetch_xhs_access_token(endpoint, config),
         {:ok, session} <- fetch_xhs_session(endpoint, config, access_token, code) do
      {:ok, session}
    end
  end

  defp fetch_xhs_access_token(endpoint, config) do
    # 假设（无官方可渲染文档，社区样本支持）：参数 app_id/app_secret/grant_type，
    # 响应 data.access_token。真凭据联调时若形状不符只需改这一个函数。
    endpoint.base_url
    |> req()
    |> Req.request(
      method: :get,
      url: endpoint.token_path,
      params: [
        app_id: config.appid,
        app_secret: config.secret,
        grant_type: "client_credential"
      ]
    )
    |> case do
      {:ok, %Req.Response{status: 200, body: body}} ->
        case parse_xhs_envelope(body) do
          {:ok, %{"access_token" => access_token}} when is_binary(access_token) ->
            {:ok, access_token}

          {:ok, _} ->
            {:error, :code2session_bad_response}

          {:error, _} = error ->
            error
        end

      {:ok, %Req.Response{status: status}} ->
        {:error, {:platform_http_status, status}}

      {:error, _reason} ->
        {:error, :platform_unreachable}
    end
  end

  defp fetch_xhs_session(endpoint, config, access_token, code) do
    # 证据：redmini#1237 的 tp 变体把 code 放 query；tea521 实测"code 必须放在 query"。
    # 假设：自研应用参数名为 app_id/access_token（tp 变体为 appid/auth_access_token）。
    endpoint.base_url
    |> req()
    |> Req.request(
      method: :get,
      url: endpoint.session_path,
      params: [app_id: config.appid, access_token: access_token, code: code]
    )
    |> case do
      {:ok, %Req.Response{status: 200, body: body}} ->
        case parse_xhs_envelope(body) do
          {:ok, data} when is_map(data) ->
            # 字段名证据冲突：官方《登录态管理》写 open_id，社区样本写 openid——
            # 两者同语义，任一命中即可（真凭据联调后收敛为单一字段）。
            openid = data["openid"] || data["open_id"]

            if is_binary(openid) and is_binary(data["session_key"]) do
              # 官方文档明确：小红书暂不提供 unionid → 恒为 nil
              {:ok, %{openid: openid, unionid: nil, session_key: data["session_key"]}}
            else
              {:error, :code2session_bad_response}
            end

          {:ok, _} ->
            {:error, :code2session_bad_response}

          {:error, _} = error ->
            error
        end

      {:ok, %Req.Response{status: status}} ->
        {:error, {:platform_http_status, status}}

      {:error, _reason} ->
        {:error, :platform_unreachable}
    end
  end

  # xhs 信封（在线端点实测）：{"success":bool,"msg":string,"data":any,"code":int}，
  # code==0 为成功（410101=令牌不匹配等平台错误码为非零）。
  defp parse_xhs_envelope(%{"code" => 0, "data" => data}), do: {:ok, data}

  defp parse_xhs_envelope(%{"code" => code}) when is_integer(code),
    do: {:error, {:code2session_rejected, code}}

  defp parse_xhs_envelope(_), do: {:error, :code2session_bad_response}

  # wechat：成功 %{"openid", "session_key", "unionid"?}；失败 %{"errcode", "errmsg"}
  defp parse_session(:wechat, %{"openid" => openid, "session_key" => session_key} = body)
       when is_binary(openid) and is_binary(session_key) do
    {:ok, %{openid: openid, unionid: Map.get(body, "unionid"), session_key: session_key}}
  end

  defp parse_session(:wechat, %{"errcode" => errcode}) when is_integer(errcode) do
    {:error, {:code2session_rejected, errcode}}
  end

  # tt：成功 %{"err_no" => 0, "data" => %{"openid", "session_key", "unionid"?}}
  defp parse_session(:tt, %{"err_no" => 0, "data" => data})
       when is_map(data) do
    case data do
      %{"openid" => openid, "session_key" => session_key}
      when is_binary(openid) and is_binary(session_key) ->
        {:ok, %{openid: openid, unionid: Map.get(data, "unionid"), session_key: session_key}}

      _ ->
        {:error, :code2session_bad_response}
    end
  end

  defp parse_session(:tt, %{"err_no" => err_no}) when is_integer(err_no) do
    {:error, {:code2session_rejected, err_no}}
  end

  @doc """
  phoneCode → 手机号（getPhoneNumber 新契约，wechat + tt）。

  wechat：SDK 直取——POST /wxa/business/getuserphonenumber；成功 body
  phone_info 含 purePhoneNumber/phoneNumber + countryCode——归一化为与
  decrypt_phone 相同的 `+区号号码` 形（phone-keyed find-or-create 的确定性
  前提，见 decrypt_phone 注释）。

  tt：POST open.douyin.com/api/apps/v2/get_phone_number（client_token +
  `%{code}`，code 为前端 getPhoneNumber 回调的动态口令，5 分钟一次性，
  与 tt.login code 不可混用）。响应 `data.phone_number` 在匿名手机号方案
  下可能是应用公钥加密的密文——明文（区号可选手动数字串）直接归一化；
  密文返回 `{:error, :phone_number_encrypted}`（RSA 解密待真机确认响应
  结构后实现，DOUYIN_REDNOTE_CHECKLIST 挂账）。

  xhs 无等价 API → {:error, :phone_code_unsupported}。
  """
  @spec fetch_phone_by_code(platform, String.t() | nil, String.t()) ::
          {:ok, String.t()} | {:error, term()}
  def fetch_phone_by_code(:wechat, openid, phone_code)
      when is_binary(openid) and is_binary(phone_code) do
    with {:ok, client} <- SdkClient.fetch(),
         {:ok, %Tesla.Env{status: 200, body: %{"errcode" => 0, "phone_info" => info}}} <-
           WeChat.MiniProgram.UserInfo.get_phone_number(client, openid, phone_code),
         local when is_binary(local) <- info["purePhoneNumber"] || info["phoneNumber"],
         {:ok, phone} <- Cgc2046.Accounts.PhoneNumber.normalize(local, info["countryCode"]) do
      {:ok, phone}
    else
      _ -> {:error, :phone_fetch_failed}
    end
  end

  def fetch_phone_by_code(:tt, _openid, phone_code)
      when is_binary(phone_code) and phone_code != "" do
    with {:ok, config} <- platform_config(:tt),
         {:ok, token} <- fetch_api_access_token(:tt, config),
         {:ok, %Req.Response{status: 200, body: %{"err_no" => 0, "data" => data}}}
         when is_map(data) <-
           "https://open.douyin.com"
           |> req()
           |> Req.post(
             url: "/api/apps/v2/get_phone_number",
             headers: [{"access-token", token}],
             json: %{code: phone_code}
           ),
         {:ok, phone} <- normalize_tt_phone_number(data) do
      {:ok, phone}
    else
      {:error, reason} -> {:error, reason}
      _ -> {:error, :phone_fetch_failed}
    end
  end

  def fetch_phone_by_code(_platform, _openid, _phone_code),
    do: {:error, :phone_code_unsupported}

  # tt phone_number 明文判定：区号可选手动数字串（大陆 11 位 / +86…13 位）。
  # 匿名手机号方案下该字段是应用公钥加密的 base64 密文——仅记键名不记值
  # （安全红线：手机号明文/密文不落日志）。
  defp normalize_tt_phone_number(%{"phone_number" => raw} = data) when is_binary(raw) do
    if Regex.match?(~r/^\+?\d{5,20}$/, raw) do
      Cgc2046.Accounts.PhoneNumber.normalize(raw, Map.get(data, "country_code", "86"))
    else
      Logger.warning(
        "[tt get_phone_number] phone_number is not plaintext (anonymous-phone scheme); " <>
          "response keys: #{inspect(Map.keys(data))}"
      )

      {:error, :phone_number_encrypted}
    end
  end

  defp normalize_tt_phone_number(_), do: {:error, :phone_fetch_failed}

  @doc """
  自由文本内容安全检查（v1 wechat-only，plan 2026-08-18-009 D-1；msgSecCheck v2 契约，
  advisor09 F1）。

  报名 reason 提交链路同步拦截：wechat 经宿主 Wechat.Requester 直发 v2
  `POST /wxa/msg_sec_check`（SDK `Security.msg_check/2` 为 v1 已废弃——body 无
  version/openid，v2 契约不可达），body `%{content, version: 2, scene: 2, openid}`，
  access_token 由 SDK client 管理（`client.get_access_token/0`）。请求体含 content
  明文，经宿主 Wechat.Requester 出网（debug:false 既有红线）。tt/xhs 显式
  pass-through（各自平台审核独立，Phase 4 接入，零外呼）。

  语义（plan D-2 + v2）：
  - `{:ok, :passed}`：v2 `result.suggest == "pass"`
  - `{:ok, :skipped}`：infra 故障 fail-open（errcode 非 0 含 47001/61010/45009 /
    网络错误 / 非 200 / wechat 未配置）——平台瞬时故障不阻断报名，已记 telemetry
    `[:cgc_2046, :content_check, :skipped]`（metadata 仅类别原子，**不含 content 明文**）
  - `{:ok, :unchecked}`：tt/xhs pass-through（零外呼）
  - `{:error, :content_rejected}`：`result.suggest` 为 `"risky"`/`"review"`——
    违规内容 fail-closed（提交被拒）

  content ≤2500 字节由调用方（Enrollment.check_content 服务端校验）保证，本函数
  不再 clamp。幂等：纯读检查，重试安全。
  """
  @spec content_check(platform, String.t(), String.t()) ::
          {:ok, :passed | :skipped | :unchecked} | {:error, :content_rejected}
  def content_check(:wechat, content, openid)
      when is_binary(content) and is_binary(openid) do
    case SdkClient.fetch() do
      {:ok, client} ->
        body = %{content: content, version: 2, scene: 2, openid: openid}

        classify_msg_check(
          client.post("/wxa/msg_sec_check", body,
            query: [access_token: client.get_access_token()]
          )
        )

      {:error, reason} ->
        emit_content_check_skipped(reason)
        {:ok, :skipped}
    end
  end

  def content_check(platform, _content, _openid) when platform in [:tt, :xhs] do
    {:ok, :unchecked}
  end

  # v2 判定：errcode 0 + result.suggest "pass" → 放行；"risky"/"review" →
  # fail-closed 拒绝；其余（errcode 非 0 / 非 200 / 网络 / 无法解析）一律
  # fail-open 放行 + telemetry 计数。
  defp classify_msg_check(
         {:ok,
          %Tesla.Env{status: 200, body: %{"errcode" => 0, "result" => %{"suggest" => "pass"}}}}
       ),
       do: {:ok, :passed}

  defp classify_msg_check(
         {:ok,
          %Tesla.Env{
            status: 200,
            body: %{"errcode" => 0, "result" => %{"suggest" => suggest}}
          }}
       )
       when suggest in ["risky", "review"],
       do: {:error, :content_rejected}

  defp classify_msg_check(other) do
    emit_content_check_skipped(other)
    {:ok, :skipped}
  end

  # reason 类别原子（无 content 明文，红线：明文不进日志/telemetry/错误消息）
  defp emit_content_check_skipped({:ok, %Tesla.Env{status: 200, body: %{"errcode" => 45_009}}}),
    do: emit_skipped(:rate_limited)

  defp emit_content_check_skipped({:ok, %Tesla.Env{status: 200, body: %{"errcode" => _}}}),
    do: emit_skipped(:unknown_errcode)

  defp emit_content_check_skipped({:ok, %Tesla.Env{status: _status}}),
    do: emit_skipped(:http_status)

  defp emit_content_check_skipped({:error, _}), do: emit_skipped(:network)

  defp emit_content_check_skipped(:wechat_not_configured),
    do: emit_skipped(:wechat_not_configured)

  defp emit_content_check_skipped(_), do: emit_skipped(:unknown)

  defp emit_skipped(reason) do
    :telemetry.execute(
      [:cgc_2046, :content_check, :skipped],
      %{count: 1},
      %{reason: reason}
    )
  end

  @doc """
  用 session_key 解密 getPhoneNumber 加密数据，返回归一化手机号（`+区号号码`）。

  算法与三平台官方规范一致：Base64(session_key) 为密钥的 AES-128-CBC + PKCS7。
  带 watermark 的负载校验 appid 与本应用一致（防跨应用数据注入）。
  解密失败统一 `{:error, :phone_decrypt_failed}`——不泄漏密文材料与内部细节；
  平台凭证缺失短路为 `{:error, :platform_not_configured}`（issue #264）。
  """
  @spec decrypt_phone(platform, session, String.t(), String.t()) ::
          {:ok, String.t()}
          | {:error, :phone_decrypt_failed | :platform_not_configured}
  def decrypt_phone(platform, %{session_key: session_key}, encrypted_data, iv)
      when platform in @platforms do
    with {:ok, config} <- platform_config(platform),
         {:ok, key} <- decode64(session_key),
         {:ok, iv_bytes} <- decode64(iv),
         {:ok, ciphertext} <- decode64(encrypted_data),
         {:ok, plaintext} <- aes_128_cbc_decrypt(key, iv_bytes, ciphertext),
         {:ok, payload} <- Jason.decode(plaintext),
         :ok <- verify_watermark(config, payload),
         {:ok, phone} <- extract_phone(payload) do
      {:ok, phone}
    else
      {:error, :platform_not_configured} = error -> error
      _ -> {:error, :phone_decrypt_failed}
    end
  end

  defp decode64(value) when is_binary(value) do
    case Base.decode64(value) do
      {:ok, decoded} -> {:ok, decoded}
      :error -> :error
    end
  end

  defp decode64(_), do: :error

  defp aes_128_cbc_decrypt(key, iv, ciphertext)
       when byte_size(key) == 16 and byte_size(iv) == 16 do
    # 显式 padding 选项：boolean 形式在 OTP 27+ 对非块对齐输入会静默截断，
    # 微信/抖音/小红书规范均为 AES-128-CBC + PKCS7。
    {:ok,
     :crypto.crypto_one_time(:aes_128_cbc, key, iv, ciphertext,
       encrypt: false,
       padding: :pkcs_padding
     )}
  rescue
    _ -> :error
  end

  defp aes_128_cbc_decrypt(_, _, _), do: :error

  # 微信负载带 watermark.appid；抖音/小红书负载无 watermark 时跳过校验
  defp verify_watermark(%{appid: appid}, %{"watermark" => %{"appid" => payload_appid}}) do
    if payload_appid == appid, do: :ok, else: :error
  end

  defp verify_watermark(_platform, _payload), do: :ok

  # 手机号归一化已抽单源 Cgc2046.Accounts.PhoneNumber（plan 002 D5）：
  # 全平台确定性（Q2 phone-keyed 归一的前提）——countryCode 缺失的负载无法确定
  # 规范形（本地号还是已含区号不可知）——fail-closed 判登录失败，宁可拒绝也不冒
  # 同一号码锚出两个 User（"+86138…" vs "138…"）的分裂风险。
  defp extract_phone(payload) do
    local = payload["purePhoneNumber"] || payload["phoneNumber"]
    country_code = payload["countryCode"]

    case Cgc2046.Accounts.PhoneNumber.normalize(local, country_code) do
      {:ok, phone} -> {:ok, phone}
      {:error, :invalid} -> :error
    end
  end

  # 平台凭证门禁（issue #264）：runtime.exs 缺 env 时键在值 nil，此处归一为
  # {:error, :platform_not_configured} 干净短路（守卫语义同 wechat_pay
  # configured_key?：is_binary and != ""，防空串穿透门禁后在深处崩溃；
  # xhs 另需 qrcode_path/notification_path 两个 API 路径）。
  @required_keys %{
    wechat: [:appid, :secret],
    tt: [:appid, :secret],
    xhs: [:appid, :secret, :qrcode_path, :notification_path]
  }

  defp platform_config(platform) do
    config =
      :cgc_2046
      |> Application.get_env(:miniprogram_platforms, %{})
      |> Map.get(platform, %{})

    if Enum.all?(@required_keys[platform], &configured_key?(config, &1)) do
      {:ok, config}
    else
      {:error, :platform_not_configured}
    end
  end

  defp configured_key?(config, key) do
    value = Map.get(config, key)
    is_binary(value) and value != ""
  end

  defp req(base_url) do
    opts = [base_url: base_url, receive_timeout: 5_000, retry: false, redirect: false]

    case Application.get_env(:cgc_2046, :miniprogram_req_plug) do
      nil -> Req.new(opts)
      plug -> Req.new(Keyword.put(opts, :plug, plug))
    end
  end
end
