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

  # 端点证据（2026-08-08 核实；xhs 三项 2026-09-25 复核官方文档原文）：
  # - wechat: GET /sns/jscode2session —— 微信官方文档（developers.weixin.qq.com）确认形状。
  # - tt: POST /api/apps/v2/jscode2session —— 抖音开放平台文档 + 社区 SDK 公认形状
  #   （err_no/err_tips + data 信封）；Phase 4 真凭据联调时复核。
  # - xhs: 两步——POST /api/rmp/token（JSON 体 {appid, secret}）换 access_token
  #   （data.expire_in 秒，当前 7200；同一时间最多最近两个有效，新签发把上一个
  #   缩短至 5 分钟），再 GET /api/rmp/session?app_id&access_token&code 换会话。
  #   证据：官方《获取应用调用凭证》(miniapp.xiaohongshu.com/doc/DC010382，已核对
  #   原文）与《code2Session》(doc/DC414670，已核对原文：code 放 query、响应
  #   data.openid/session_key、**小红书暂不提供 unionid**)；错误信封
  #   {"success":false,"msg":"应用访问令牌不匹配","data":null,"code":410101}
  #   （curl 2026-08-08 实测在线端点）。
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

  # xhs access_token 进程级缓存（:persistent_term）。生产单节点部署
  # （deploy.yml 单 SERVER_HOST），滚动发布双节点重叠期由平台「最近两个
  # token 同时有效」规则兜底；10 分钟刷新提前量 > 平台「新签发把旧 token
  # 缩短至 5 分钟」窗口，自发刷新不会顶掉自己在用的 token。
  @xhs_token_cache_key {__MODULE__, :xhs_access_token}
  @xhs_token_refresh_margin_ms 10 * 60 * 1000

  # 落页契约：页面必须存在于 miniprogram/src/app.config.ts。
  # #232 调研（2026-09-05）：学员通知点击落 profile 是断点——profile「本机
  # 通知记录」只存本人操作回执，服务端下发的通知不在其中，点开什么都看不
  # 到；相关内容（报名状态）在 my-enrollments 有权威展示。故按 template_key
  # 路由：学员类 → 我的报名；管理类 → 工作台（审批待办在那）；裁剪端无
  # workspace/profile tab，一律落我的报名。小程序码：join 三端都注册且消费
  # scene（miniprogram/src/app.tsx useLaunch → pendingScene → join）。
  # 主理人指派（#558 后续）：深链到活动详情页（带 event_id）——被指派者点开
  # 即见「扫码核销」入口（canModerateEvent 门），指派这一刻就成为入口。
  # #594 开班/未达阈值/改期三模板归学员类：收件人都是报名人（Qualification 与
  # ScheduleChangedSubscriber 取件均为 pending/payment_pending/confirmed）。
  # **不深链 event-detail**：未达阈值送达时活动已被 EventLifecycleWorker 转
  # cancelled，而 ActorReadsOffering 对普通成员只放行 open/closed（普通学员读
  # cancelled 需 visibility=public 且挂活跃 Initiative，ReadsArchivedInitiativeEvent），
  # 深链会渲染「活动不存在或不可访问」——比 profile 更糟。退款的权威面在「我的
  # 报名」：enrollmentPaymentText 对 confirmed 报名 + refunding/refunded 订单出
  # 「退款中/已退款」。改期的「新时间」与地点同为该页权威落点（#617：卡片渲染
  # EnrollmentSummary.startsAt/venue，同 event_reminder 缺口一并闭合）。
  # #546 核销码通知**必须**落 my-enrollments：6 位码与二维码就在该页报名卡上
  # 渲染（pages/my-enrollments/index.tsx 的 checkInCodeText，仅 confirmed 显示），
  # 落 profile 等于把用户送回「本机通知记录」空页——正是本 issue 要消除的
  # 「不知道码在哪」。
  @learner_templates ~w(approval_result enrollment_completed enrollment_check_in_code
                         payment_succeeded
                         payment_expired refund_succeeded refund_failed
                         event_reminder learning_stagnation
                         event_qualification_confirmed event_qualification_underfilled
                         event_schedule_changed)
  # speaker_accepted 受众纯管理者（speaker_invitation_worker.ex:46）；advisor
  # review #422 捕获其误兜底 profile 的断点残留。speaker_completed 双受众
  # （管理者 + speaker 本人）维持兜底 profile——已知取舍：speaker 侧点开无
  # 权威页，多数方（管理者）可从 workspace  speakers 面板查看。
  # #585 event_qualification_manager：成班结果的管理腿（Owner/Admin 收件），
  # 落工作台——成班/取消的后续处理面在那；参与者两键仍归 @learner_templates。
  @manager_templates ~w(approval_reminder enrollment_submitted payment_received speaker_accepted
                        event_qualification_manager)

  # 志愿者段位通知六模板（U4；R14）→ 招募流「我的申请」页：申请人查看批次/
  # 段位/拒绝原因/分配结果的权威面（#232 落页契约：点开必须有权威内容，不能落
  # profile 本机通知记录——服务端下发的通知不在其中）。该页由小程序招募流
  # （U10）注册（pages/volunteer-apply/index，仅微信端页清单）。
  @applicant_templates ~w(volunteer_application_submitted volunteer_application_interview
                          volunteer_application_training volunteer_application_assigned
                          volunteer_application_rejected volunteer_application_canceled)

  # 回响通知直达独立公开许愿树；无档案或未登录也能读取对应愿望与回响。
  @wish_templates ~w(flashback_wish_echo)

  defp notification_page(platform, template_key, data) do
    cond do
      # 裁剪端（tt/xhs）仅注册「发现/我的报名」两 tab（app.config.ts cutPages）
      platform in [:tt, :xhs] ->
        "pages/my-enrollments/index"

      # 深链仅在 data 带 event_id 时成立；缺失回落通用路由（不拼坏 URL）
      # removed（#538）同落 event-detail：公开主理人投影即「名单里没有我了」
      # 的对照面；被移除者 canModerateEvent 变 false，核销入口自然消失。
      template_key in ~w(event_moderator_assigned event_moderator_removed) and
          is_binary(data["event_id"]) ->
        "pages/event-detail/index?id=#{data["event_id"]}&kind=event"

      template_key in @learner_templates ->
        "pages/my-enrollments/index"

      template_key in @applicant_templates ->
        "pages/volunteer-apply/index"

      template_key in @wish_templates and is_binary(data["wish_id"]) ->
        "pages/flashback-wishes/index?" <> URI.encode_query(%{wishId: data["wish_id"]})

      template_key in @wish_templates ->
        "pages/flashback-wishes/index"

      template_key in @manager_templates ->
        "pages/workspace/index"

      # speaker_completed（双受众）与未知模板：维持原落页（profile 本机通知中心）
      true ->
        "pages/profile/index"
    end
  end

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

      :xhs ->
        with {:ok, config} <- platform_config(:xhs) do
          with_xhs_token(@endpoints.xhs, config, fn access_token ->
            request_code(:xhs, config, access_token, scene)
          end)
        end

      _ ->
        with {:ok, config} <- platform_config(platform),
             {:ok, access_token} <- fetch_api_access_token(platform, config),
             {:ok, image} <- request_code(platform, config, access_token, scene) do
          {:ok, image}
        end
    end
  end

  @doc "发送一次订阅消息；三平台成功信封统一为 `:ok`。落页按 template_key 路由（#232）。"
  @spec send_notification(platform, String.t(), String.t(), map(), String.t(), map()) ::
          :ok | {:error, term()}
  def send_notification(platform, openid, template_id, data, template_key, page_context \\ %{})
      when platform in @platforms and is_binary(openid) and is_binary(template_id) and
             is_map(data) and is_binary(template_key) do
    case platform do
      # wechat 走 SDK client：token 由 SDK 内部缓存/刷新，不现取现用
      :wechat ->
        request_notification(:wechat, openid, template_id, data, template_key, page_context)

      :xhs ->
        with {:ok, config} <- platform_config(:xhs) do
          with_xhs_token(@endpoints.xhs, config, fn access_token ->
            request_notification(
              :xhs,
              config,
              access_token,
              openid,
              template_id,
              data,
              template_key,
              page_context
            )
          end)
        end

      _ ->
        with {:ok, config} <- platform_config(platform),
             {:ok, access_token} <- fetch_api_access_token(platform, config) do
          request_notification(
            platform,
            config,
            access_token,
            openid,
            template_id,
            data,
            template_key,
            page_context
          )
        end
    end
  end

  defp request_notification(:wechat, openid, template_id, data, template_key, page_context) do
    with {:ok, client} <- SdkClient.fetch() do
      client
      |> WeChat.MiniProgram.SubscribeMessage.send(openid, template_id, data, %{
        # data 是渲染后的槽位字段；深链判定读的是逻辑键（wish_id/event_id），
        # 逻辑键在 page_context 里（merge 后同键逻辑值优先——槽位不带这些键名）。
        page: notification_page(:wechat, template_key, Map.merge(data, page_context))
      })
      |> parse_wechat_envelope()
    end
  end

  defp request_notification(
         :tt,
         _config,
         token,
         openid,
         template_id,
         data,
         template_key,
         page_context
       ) do
    "https://open.douyin.com"
    |> req()
    |> Req.post(
      url: "/api/notification/v2/subscription/notify_user/",
      headers: [{"access-token", token}],
      json: %{
        open_id: openid,
        msg_id: template_id,
        page: notification_page(:tt, template_key, Map.merge(data, page_context)),
        data: data
      }
    )
    |> case do
      {:ok, %Req.Response{status: 200, body: %{"err_no" => 0}}} -> :ok
      response -> parse_platform_failure(response)
    end
  end

  defp request_notification(
         :xhs,
         %{notification_path: path},
         token,
         openid,
         template_id,
         data,
         template_key,
         page_context
       ) do
    "https://miniapp.xiaohongshu.com"
    |> req()
    |> Req.post(
      url: path,
      headers: [{"access-token", token}],
      json: %{
        open_id: openid,
        template_id: template_id,
        page: notification_page(:xhs, template_key, Map.merge(data, page_context)),
        data: data
      }
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

  # 官方《获取不限制的小程序二维码》（doc/DC164497，2026-09-25 已核对原文）：
  # appid/access_token 为公共 query 参数；body 带 scene/page/width（width 必填，
  # 280–1280px）；成功响应 Content-Type: image/png，body 即图片字节流；
  # 错误响应为 JSON {success:false, code, msg}（Req 解码为 map 由
  # parse_platform_failure 提错）。
  defp request_code(:xhs, %{qrcode_path: path} = config, token, scene) do
    "https://miniapp.xiaohongshu.com"
    |> req()
    |> Req.post(
      url: path,
      params: [appid: config.appid, access_token: token],
      json: %{scene: scene, page: @code_page, width: 430}
    )
    |> case do
      {:ok, %Req.Response{status: 200, body: body}} when is_binary(body) ->
        {:ok, body}

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
        # 微信 jscode2session 成功响应 content-type 为 text/plain（平台怪癖,
        # #99 真机实证）——Req 按 content-type 不解码,binary body 先手动 JSON
        # 解码;非 JSON binary 保持原样交 parse_session 兜底。
        case parse_session(platform, maybe_decode_json(body)) do
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

  # xhs 两步（官方文档证据见 @endpoints 注释）：先换 access_token（POST
  # /api/rmp/token，进程级缓存，见 @xhs_token_cache_key），再带 access_token
  # + code 换会话。
  defp xhs_code2session(config, code) do
    endpoint = @endpoints.xhs

    with_xhs_token(endpoint, config, fn access_token ->
      fetch_xhs_session(endpoint, config, access_token, code)
    end)
  end

  # xhs API 调用公共入口：取缓存 token 执行；410101（应用访问令牌不匹配——
  # 缓存 token 被外部签发/后台换发顶掉）作废缓存、取新 token 重试一次；
  # 二次失败原样上抛（不重试风暴）。
  defp with_xhs_token(endpoint, config, fun) do
    case fetch_xhs_access_token(endpoint, config) do
      {:ok, access_token} ->
        case fun.(access_token) do
          {:error, {:code2session_rejected, 410_101}} ->
            retry_with_fresh_token(endpoint, config, fun)

          {:error, {:platform_rejected, 410_101, _msg}} ->
            retry_with_fresh_token(endpoint, config, fun)

          other ->
            other
        end

      {:error, _} = error ->
        error
    end
  end

  defp retry_with_fresh_token(endpoint, config, fun) do
    invalidate_xhs_token_cache()

    with {:ok, fresh_token} <- fetch_xhs_access_token(endpoint, config) do
      fun.(fresh_token)
    end
  end

  @doc false
  def invalidate_xhs_token_cache do
    :persistent_term.erase(@xhs_token_cache_key)
    :ok
  end

  defp fetch_xhs_access_token(endpoint, config) do
    now = System.monotonic_time(:millisecond)

    case :persistent_term.get(@xhs_token_cache_key, nil) do
      {access_token, expires_at}
      when is_binary(access_token) and expires_at - now > @xhs_token_refresh_margin_ms ->
        {:ok, access_token}

      _ ->
        refresh_xhs_access_token(endpoint, config, now)
    end
  end

  # 官方《获取应用调用凭证》（doc/DC010382）：POST /api/rmp/token，JSON 体
  # {appid, secret}；成功响应 data.access_token + data.expire_in（秒）。
  defp refresh_xhs_access_token(endpoint, config, now) do
    endpoint.base_url
    |> req()
    |> Req.post(
      url: endpoint.token_path,
      json: %{appid: config.appid, secret: config.secret}
    )
    |> case do
      {:ok, %Req.Response{status: 200, body: body}} ->
        case parse_xhs_envelope(body) do
          {:ok, %{"access_token" => access_token} = data} when is_binary(access_token) ->
            expire_in =
              case data["expire_in"] do
                seconds when is_integer(seconds) and seconds > 0 -> seconds
                _ -> 7_200
              end

            :persistent_term.put(@xhs_token_cache_key, {access_token, now + expire_in * 1000})
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
    # 官方《code2Session》（doc/DC414670，2026-09-25 已核对原文）：
    # GET /api/rmp/session，app_id/access_token/code 全部放 query。
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
            # 官方《code2Session》（doc/DC414670）：data.openid；open_id 是
            # 早期社区样本写法，留作防御兜底（任一命中即可）。
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

  # 微信边缘错误可能返回非 JSON（text/plain 错误页等；Req 按 content-type
  # 不解码 → binary body）或未知形状——兜底防 FunctionClauseError 击穿登录链
  # (#99 真机实证)。日志只打形状与错误码:session_key 红线不变(成功形状已被
  # 上面子句捕获,能走到这里的 body 必不含 session_key)。
  defp parse_session(:wechat, body) do
    Logger.warning("[code2session] wechat unexpected body: #{unexpected_body_desc(body)}")
    {:error, :code2session_bad_response}
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

  defp parse_session(:tt, body) do
    Logger.warning("[code2session] tt unexpected body: #{unexpected_body_desc(body)}")
    {:error, :code2session_bad_response}
  end

  # 异常 body 的脱敏描述——只暴露形状与平台错误码,永不打 session_key 值。
  defp unexpected_body_desc(body) when is_map(body) do
    "keys=#{inspect(Map.keys(body))} errcode=#{inspect(Map.get(body, "errcode"))} " <>
      "errmsg=#{inspect(Map.get(body, "errmsg"))}"
  end

  defp unexpected_body_desc(body) when is_binary(body) do
    "binary #{byte_size(body)}B: #{inspect(String.slice(body, 0, 120))}"
  end

  defp unexpected_body_desc(body), do: inspect(body)

  # text/plain 的 JSON 手动解码（微信怪癖,见 single_call_code2session 注释）;
  # 非 JSON binary 原样返回（parse_session 兜底打日志）。
  defp maybe_decode_json(body) when is_binary(body) do
    case Jason.decode(body) do
      {:ok, decoded} when is_map(decoded) -> decoded
      _ -> body
    end
  end

  defp maybe_decode_json(body), do: body

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

  算法：Base64(session_key) 为密钥的 AES-CBC + PKCS7。wechat/tt 严格
  AES-128（密钥恒 16 字节）；xhs 官方《开放数据校验与解密》（doc/DC591932）
  算法字段写 AES-128-CBC、却注明 AESKey 为 24 字节（自相矛盾）——以官方
  Java 示例为准：cipher 取密钥实际长度（16/24/32 → AES-128/192/256），
  填充自行去除并允许 1–32 冗余。
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
         {:ok, plaintext} <- decrypt_ciphertext(platform, key, iv_bytes, ciphertext),
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

  # wechat/tt：严格 AES-128-CBC + PKCS7（官方 session_key 恒 16 字节）
  defp decrypt_ciphertext(platform, key, iv, ciphertext) when platform in [:wechat, :tt] do
    aes_128_cbc_decrypt(key, iv, ciphertext)
  end

  # xhs：以官方 Java 示例为准（doc/DC591932 文档字段自相矛盾的取舍见
  # decrypt_phone 注释）——cipher 按密钥实际长度选，填充自行去除
  defp decrypt_ciphertext(:xhs, key, iv, ciphertext) when byte_size(iv) == 16 do
    with {:ok, cipher} <- xhs_aes_cipher(byte_size(key)) do
      plaintext =
        :crypto.crypto_one_time(cipher, key, iv, ciphertext, encrypt: false, padding: :none)

      xhs_unpad(plaintext)
    end
  rescue
    _ -> :error
  end

  defp decrypt_ciphertext(:xhs, _key, _iv, _ciphertext), do: :error

  defp xhs_aes_cipher(16), do: {:ok, :aes_128_cbc}
  defp xhs_aes_cipher(24), do: {:ok, :aes_192_cbc}
  defp xhs_aes_cipher(32), do: {:ok, :aes_256_cbc}
  defp xhs_aes_cipher(_), do: :error

  # 官方 Java 示例口径：末位字节 n 为填充长度，1 ≤ n ≤ 32 即去除
  # （非标准 PKCS7 边界的容差；非法 n 走 phone_decrypt_failed）
  defp xhs_unpad(plaintext) when byte_size(plaintext) > 0 do
    pad = :binary.last(plaintext)

    if pad >= 1 and pad <= 32 and pad <= byte_size(plaintext) do
      {:ok, binary_part(plaintext, 0, byte_size(plaintext) - pad)}
    else
      :error
    end
  end

  defp xhs_unpad(_), do: :error

  defp aes_128_cbc_decrypt(key, iv, ciphertext)
       when byte_size(key) == 16 and byte_size(iv) == 16 do
    # 显式 padding 选项：boolean 形式在 OTP 27+ 对非块对齐输入会静默截断；
    # 微信/抖音规范为 AES-128-CBC + PKCS7（xhs 走 decrypt_ciphertext(:xhs, …)）。
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
