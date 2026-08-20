defmodule Cgc2046Web.GraphqlSchema do
  use Absinthe.Schema

  require Logger
  require Ash.Query
  require Ash.Expr

  use AshGraphql,
    domains: [Cgc2046.Api, Cgc2046.GlobalApi, Cgc2046.Payments],
    generate_sdl_file: "priv/graphql/schema.graphql",
    auto_generate_sdl_file?: true

  query do
    @desc "Placeholder query until the first resource is added"
    field :ping, :string do
      resolve(fn _, _, _ ->
        {:ok, "pong"}
      end)
    end

    @desc "角色权限矩阵（#66 Rbac）：五角色 × 七能力，对齐前端权限表（需登录；#1 能力接口：abilities 为通用列表）"
    field :permission_matrix, :permission_matrix_payload do
      resolve(fn _, _, %{context: context} ->
        with_actor(context, fn _actor ->
          roles =
            Cgc2046.Rbac.matrix()
            |> Enum.map(fn row ->
              %{
                name: to_string(row.role),
                abilities:
                  Enum.map(row.abilities, fn {name, allowed} ->
                    %{name: to_string(name), allowed: allowed}
                  end)
              }
            end)

          {:ok, %{roles: roles}}
        end)
      end)
    end

    field :offering_readiness, :offering_readiness_payload do
      arg(:id, non_null(:id))

      resolve(fn _, %{id: id}, %{context: context} ->
        with_actor(context, fn actor ->
          resolve_readiness(id, actor)
        end)
      end)
    end

    @desc "当前登录用户个人资料（#68 Profile API，需登录）：id/email/displayName/isPlatformAdmin + memberNumber/joinedAt（ADR-0004 收窄为全局身份）"
    field :me, :user do
      resolve(fn _, _, %{context: context} ->
        with_actor(
          context,
          fn actor ->
            load_profile(actor, actor, context, nil)
          end,
          on_nil: fn _ctx ->
            # #13 Finding A：token 签名有效但 user 加载失败（DB 故障 / 撤销）时
            # AuthPlug.load_actor 已标记 cgc_auth_uncertain。返回 auth_uncertain
            # 让前端保持登录态重试，而非误踢已登录用户。
            if context[:cgc_auth_uncertain] do
              {:error, message: "Auth state uncertain", code: "auth_uncertain"}
            else
              {:error, unauthorized_error()}
            end
          end
        )
      end)
    end

    @desc "当前用户在某工作台的公开资料（ADR-0004 per-workspace；按 visibility 授权）"
    field :workspace_profile, :workspace_profile do
      arg(:workspace_id, non_null(:id))

      resolve(fn _, %{workspace_id: workspace_id}, %{context: context} ->
        with_actor(context, fn actor ->
          Cgc2046.Accounts.WorkspaceProfile
          |> Ash.Query.for_read(:read)
          |> Ash.Query.filter(user_id == ^actor.id)
          |> Ash.read_one(tenant: workspace_id, actor: actor)
        end)
      end)
    end

    @desc "当前用户在某工作台的作品集条目列表（ADR-0004 per-workspace）"
    field :my_workspace_portfolio, list_of(:portfolio_item) do
      arg(:workspace_id, non_null(:id))

      resolve(fn _, %{workspace_id: workspace_id}, %{context: context} ->
        with_actor(context, fn actor ->
          Ash.read(Cgc2046.Accounts.PortfolioItem,
            action: :my_portfolio,
            tenant: workspace_id,
            actor: actor
          )
        end)
      end)
    end

    @desc "当前用户的 MCP 连接 token 列表（切片 D #44；不含明文，新→旧；policy 仅见本人）"
    field :my_mcp_tokens, list_of(:mcp_token) do
      resolve(fn _, _, %{context: context} ->
        with_actor(context, fn actor ->
          Cgc2046.Mcp.Token.list_for(actor)
        end)
      end)
    end

    @desc "当前用户作为 Owner/Admin 的跨工作台待审批项（Enrollment + JoinRequest + Sponsorship）；include_expired=true 时附带已过期行（只读展示，E-8 #123）"
    field :my_pending_approvals, non_null(list_of(non_null(:pending_approval))) do
      arg(:include_expired, :boolean)

      resolve(fn _, args, %{context: context} ->
        with_actor(context, fn actor ->
          Cgc2046.Events.PendingApprovals.list(actor,
            include_expired: args[:include_expired] || false
          )
        end)
      end)
    end

    @desc "当前用户作为 Owner/Admin 的跨工作台可操作待办总数（Enrollment + JoinRequest + Sponsorship 的 pending 且未过审批截止）；已过期不计（KTD8 口径，与 /approvals 展示含过期行存在有意差异）"
    field :pending_approvals_count, non_null(:integer) do
      resolve(fn _, _, %{context: context} ->
        with_actor(context, fn actor ->
          case Cgc2046.Events.PendingApprovals.count_pending(actor) do
            {:ok, count} -> {:ok, count}
            {:error, reason} -> {:error, reason}
          end
        end)
      end)
    end

    @desc "当前用户 confirmed 报名对应的学习 run 进度（非成员可读）"
    field :my_learning_runs, non_null(list_of(non_null(:my_learning_run))) do
      resolve(fn _, _, %{context: context} ->
        with_actor(context, &resolve_my_learning_runs/1)
      end)
    end

    @desc "公开课程地图(U7/R10):issue key/标题/kind/goal 一行;匿名可读,不露 checklist"
    field :course_map, :course_map do
      arg(:slug, non_null(:string))

      resolve(fn _, args, _ ->
        resolve_course_map(args[:slug])
      end)
    end

    @desc "当前用户的课程学习详情（U7 抽屉数据：课程地图 + 本人记录合成；恒 actor 视角无他人面）"
    field :course_learning_detail, :course_learning_detail do
      arg(:course_id, non_null(:id))

      resolve(fn _, args, %{context: context} ->
        with_actor(context, fn actor ->
          resolve_course_learning_detail(actor, args[:course_id])
        end)
      end)
    end

    @desc "当前用户在某工作台的 MCP 工具调用活动流（plan 020 U2.1；policy：workspace 成员 + 仅本人；params 摘要级不返回）"
    field :my_workspace_tool_calls, non_null(list_of(non_null(:workspace_tool_call))) do
      arg(:workspace_id, non_null(:id))
      arg(:first, :integer)

      resolve(fn _, args, %{context: context} ->
        # args 只含调用方提供的键（first 可缺省）——不能用固定键 pattern match
        with_actor(context, fn actor ->
          resolve_my_workspace_tool_calls(actor, args[:workspace_id], args[:first] || 50)
        end)
      end)
    end

    # ── SpeakerInvitation（E-4 #49）──

    @desc "邀请卡片（Speaker 着陆页，无需登录）：token 公开校验，返回邀请主题/时间 + Event 公开信息；无效/过期/已用 token 统一错误，不泄露其它邀请"
    field :speaker_invitation_card, :speaker_invitation_card do
      arg(:token, non_null(:string))

      resolve(fn _, %{token: token}, _ ->
        case Cgc2046.Events.SpeakerInvitations.card(token) do
          {:ok, card} ->
            {:ok, card}

          {:error, _reason} ->
            {:error,
             message: "invitation token is invalid, expired or already used",
             code: "invalid_token"}
        end
      end)
    end

    @desc "某 Event 的 Speaker 邀请列表（仅 Owner/Admin 或平台管理员，read policy 兜底）"
    field :speaker_invitations, non_null(list_of(non_null(:speaker_invitation))) do
      arg(:event_id, non_null(:id))

      resolve(fn _, %{event_id: event_id}, %{context: context} ->
        with_actor(context, fn actor ->
          case Cgc2046.Events.SpeakerInvitations.list_for_event(event_id, actor) do
            {:ok, invitations} ->
              {:ok, invitations}

            {:error, reason} when reason in [:forbidden, :event_not_found] ->
              {:error, [message: "event not found", code: "not_found"]}

            {:error, reason} ->
              {:error, [message: inspect(reason), code: "invalid"]}
          end
        end)
      end)
    end

    # ── Platform Admin Dashboard Phase 5：admin queries（R3-R13 数据层）──

    @desc "平台管理员：用户列表（R8；search 匹配 email/display_name，分页 first/after）"
    field :list_users, non_null(list_of(non_null(:admin_user))) do
      arg(:search, :string)
      arg(:first, :integer)
      arg(:after, :string)

      resolve(
        admin_list(
          Cgc2046.Accounts.User,
          fn q, args -> maybe_user_search(q, args[:search]) end,
          &load_membership_counts/2
        )
      )
    end

    @desc "平台管理员：工作台列表（R13；search 匹配 name/slug，分页 first/after）"
    field :list_workspaces, non_null(list_of(non_null(:admin_workspace))) do
      arg(:search, :string)
      arg(:first, :integer)
      arg(:after, :string)

      resolve(
        admin_list(
          Cgc2046.Accounts.Workspace,
          fn q, args -> maybe_workspace_search(q, args[:search]) end,
          admin_result(Cgc2046.Accounts.Workspace, Cgc2046.GlobalApi),
          pre_read: fn q -> Ash.Query.load(q, :member_count) end
        )
      )
    end

    @desc "平台管理员：工作台创建申请列表（R7；status 过滤，分页 first/after）"
    field :list_workspace_applications,
          non_null(list_of(non_null(:admin_workspace_application))) do
      arg(:status, :string)
      arg(:first, :integer)
      arg(:after, :string)

      resolve(
        admin_list(
          Cgc2046.Accounts.WorkspaceApplication,
          fn q, args -> maybe_status_filter(q, args[:status]) end,
          admin_result(Cgc2046.Accounts.WorkspaceApplication, Cgc2046.GlobalApi)
        )
      )
    end

    @desc "当前用户（申请人）的工作台创建申请列表（R7a；任何人可见自己的申请）"
    field :my_workspace_applications, non_null(list_of(non_null(:admin_workspace_application))) do
      resolve(fn _, _, %{context: context} ->
        with_actor(context, fn actor ->
          Cgc2046.Accounts.WorkspaceApplication
          |> Ash.Query.for_read(:read)
          |> Ash.Query.filter(applicant_id == ^actor.id)
          |> Ash.read(actor: actor)
          |> map_error(context, :read, Cgc2046.Accounts.WorkspaceApplication, Cgc2046.GlobalApi)
        end)
      end)
    end

    @desc "平台管理员：MCP 工具调用审计日志（R10；workspaceId 按 params JSONB 过滤，D5）"
    field :list_tool_call_logs, non_null(list_of(non_null(:admin_tool_call_log))) do
      arg(:workspace_id, :id)
      arg(:status, :string)
      arg(:inserted_after, :datetime)
      arg(:inserted_before, :datetime)
      arg(:first, :integer)
      arg(:after, :string)

      resolve(
        admin_list(
          Cgc2046.Mcp.ToolCallLog,
          fn q, args ->
            q
            |> maybe_workspace_filter(args[:workspace_id])
            |> maybe_status_filter(args[:status], :result_status)
            |> maybe_time_range_filter(args)
          end,
          admin_result(Cgc2046.Mcp.ToolCallLog, Cgc2046.Mcp)
        )
      )
    end

    @desc "平台管理员：MCP 待确认操作日志（R10；workspaceId 按 params JSONB 过滤，D5）"
    field :list_pending_operations, non_null(list_of(non_null(:admin_pending_operation))) do
      arg(:workspace_id, :id)
      arg(:status, :string)
      arg(:inserted_after, :datetime)
      arg(:inserted_before, :datetime)
      arg(:first, :integer)
      arg(:after, :string)

      resolve(
        admin_list(
          Cgc2046.Mcp.PendingOperation,
          fn q, args ->
            q
            |> maybe_workspace_filter(args[:workspace_id])
            |> maybe_pending_status_filter(args[:status])
            |> maybe_time_range_filter(args)
          end,
          admin_result(Cgc2046.Mcp.PendingOperation, Cgc2046.Mcp)
        )
      )
    end

    @desc "平台管理员：workflow 信号日志（R10；workspaceId 按真实列过滤，分页 first/after）"
    field :list_signal_logs, non_null(list_of(non_null(:admin_signal_log))) do
      arg(:workspace_id, :id)
      arg(:signal_type, :string)
      arg(:inserted_after, :datetime)
      arg(:inserted_before, :datetime)
      arg(:first, :integer)
      arg(:after, :string)

      resolve(
        admin_list(
          Cgc2046.Workflows.SignalLog,
          fn q, args ->
            q
            |> maybe_real_workspace_filter(args[:workspace_id])
            |> maybe_signal_type_filter(args[:signal_type])
            |> maybe_time_range_filter(args)
          end,
          admin_result(Cgc2046.Workflows.SignalLog, Cgc2046.Api)
        )
      )
    end

    @desc "平台管理员：治理操作留痕（#116 R10a；action 过滤，分页 first/after）"
    field :list_admin_action_logs, non_null(list_of(non_null(:admin_action_log))) do
      arg(:action, :string)
      arg(:inserted_after, :datetime)
      arg(:inserted_before, :datetime)
      arg(:first, :integer)
      arg(:after, :string)

      resolve(
        admin_list(
          Cgc2046.Accounts.AdminActionLog,
          fn q, args ->
            q
            |> maybe_action_filter(args[:action])
            |> maybe_time_range_filter(args)
          end,
          admin_result(Cgc2046.Accounts.AdminActionLog, Cgc2046.GlobalApi)
        )
      )
    end

    @desc "平台管理员：对账扫描发现（E-10 #125；rule/entity_type 枚举过滤、workspaceId 真实列过滤，分页 first/after）"
    field :reconciliation_findings, non_null(list_of(non_null(:admin_reconciliation_finding))) do
      arg(:rule, :string)
      arg(:entity_type, :string)
      arg(:workspace_id, :id)
      arg(:first, :integer)
      arg(:after, :string)

      resolve(
        admin_list(
          Cgc2046.Reconciliation.Finding,
          fn q, args ->
            q
            # atom 约束字段精确过滤（非枚举值静默忽略，同 maybe_status_filter 语义）
            |> maybe_status_filter(args[:rule], :rule)
            |> maybe_status_filter(args[:entity_type], :entity_type)
            |> maybe_real_workspace_filter(args[:workspace_id])
          end,
          admin_result(Cgc2046.Reconciliation.Finding, Cgc2046.Api)
        )
      )
    end

    # S1（advisor02）：listWorkflowRuns 不手写——WorkflowRun 资源已自动暴露同名 query
    # （list_workflow_runs: filter/sort/first/before/after，前端 web/lib/graphql/workflow.ts
    # 在用），platform_admin read policy 已解锁（Phase 2）。自动版 filter.workspaceId.eq
    # 即真实列过滤，功能与手写版等价，避免同名 field 冲突。
  end

  mutation do
    @desc "账号密码登录（plan 002 U2：login 含 @ 走邮箱，否则手机号归一化；token 经 httpOnly cookie 交付）"
    field :sign_in, :sign_in_result do
      arg(:login, non_null(:string))
      arg(:password, non_null(:string))

      middleware(Cgc2046Web.Plugs.RateLimit,
        key_path: [:login],
        normalize: &normalize_login/1
      )

      resolve(fn _, %{login: login, password: password}, _ ->
        # 分流：含 @ → email；否则按手机号归一化（同号不同写法命中同一 User 与同一限流 key）
        query =
          if String.contains?(login, "@") do
            Cgc2046.Accounts.User
            |> Ash.Query.for_read(:sign_in_with_password, %{email: login, password: password})
          else
            case Cgc2046.Accounts.PhoneNumber.normalize(login) do
              {:ok, phone} ->
                Cgc2046.Accounts.User
                |> Ash.Query.for_read(:sign_in_with_password_phone, %{
                  phone: phone,
                  password: password
                })

              {:error, :invalid} ->
                # 非法手机号格式：直接走 email 分支让其产出既有的统一认证失败错误
                # （防枚举语义不变，不新增格式错误出口）
                Cgc2046.Accounts.User
                |> Ash.Query.for_read(:sign_in_with_password, %{email: login, password: password})
            end
          end

        try do
          case Ash.read(query) do
            {:ok, [user]} ->
              {:ok,
               %{
                 id: user.id,
                 email: user.email,
                 is_platform_admin: user.is_platform_admin,
                 # token 仅用于 middleware 传递到 before_send，不暴露在响应中
                 __token__: user.__metadata__[:token]
               }}

            {:error, _error} ->
              {:error, message: "Invalid email or password", code: "authentication_failed"}
          end
        rescue
          _ -> {:error, message: "Invalid email or password", code: "authentication_failed"}
        end
      end)

      middleware(fn res, _ ->
        case res.value do
          %{__token__: token} when is_binary(token) ->
            %{res | context: Map.put(res.context, :cgc_auth_token, token)}

          _ ->
            res
        end
      end)
    end

    @desc "请求发送手机验证码（plan 002 U3；限流 phone 1/60s + 5/1h + 20/1d、IP 30/1d）"
    field :request_phone_code, :request_phone_code_result do
      arg(:phone, non_null(:string))
      arg(:purpose, non_null(:phone_code_purpose))

      resolve(fn _, %{phone: raw_phone, purpose: purpose}, %{context: context} ->
        with {:ok, phone} <- Cgc2046.Accounts.PhoneNumber.normalize(raw_phone),
             :ok <- check_phone_code_request_limits(context, phone) do
          request_phone_code(phone, purpose)
        else
          {:error, :invalid} ->
            {:error, message: "Invalid phone number", code: "invalid_phone"}

          {:error, :rate_limited} ->
            {:error, message: "Too many requests. Try again later.", code: "rate_limited"}
        end
      end)
    end

    @desc "手机验证码登录（plan 002 U3；用户不存在自动建号；token 经 httpOnly cookie 交付）"
    field :sign_in_with_phone_code, :sign_in_with_phone_code_result do
      arg(:phone, non_null(:string))
      arg(:code, non_null(:string))

      resolve(fn _, %{phone: raw_phone, code: code}, %{context: context} ->
        with {:ok, phone} <- Cgc2046.Accounts.PhoneNumber.normalize(raw_phone),
             :ok <- check_phone_code_verify_limits(context, phone) do
          sign_in_with_phone_code(phone, code, context)
        else
          {:error, :invalid} ->
            {:error, message: "Invalid phone number", code: "invalid_phone"}

          {:error, :rate_limited} ->
            {:error, message: "Too many requests. Try again later.", code: "rate_limited"}
        end
      end)

      middleware(fn res, _ ->
        case res.value do
          %{__token__: token} when is_binary(token) ->
            %{res | context: Map.put(res.context, :cgc_auth_token, token)}

          _ ->
            res
        end
      end)
    end

    @desc "发起微信扫码登录（plan 002 U4；未配置 → wechat_login_unavailable；IP 20/15min 限流）"
    field :wechat_login_start, :wechat_login_start_result do
      @desc "发起微信扫码登录(plan 002 U4);next 透传进 redirect_uri(callback 页同源校验后跳转)"
      arg(:next, :string)

      resolve(fn _, args, %{context: context} ->
        if Cgc2046.OAuth.WechatWeb.configured?() do
          with :ok <- check_wechat_login_start_limits(context) do
            start_wechat_login(args[:next])
          else
            {:error, :rate_limited} ->
              {:error, message: "Too many requests. Try again later.", code: "rate_limited"}
          end
        else
          {:error, message: "WeChat login is unavailable", code: "wechat_login_unavailable"}
        end
      end)

      # advisor02 M2：state 经 before_send 下发 httpOnly cgc_wechat_state cookie
      # 绑定发起浏览器（WechatStatePlug 读回校验）
      middleware(fn res, _ ->
        case res.value do
          %{state: state} when is_binary(state) ->
            %{res | context: Map.put(res.context, :cgc_wechat_state_set, state)}

          _ ->
            res
        end
      end)
    end

    @desc "微信扫码回调（plan 002 U4；IP 20/15min 限流）：已绑定直登，未绑定返回绑定票据"
    field :sign_in_with_wechat, :sign_in_with_wechat_result do
      arg(:code, non_null(:string))
      arg(:state, non_null(:string))

      resolve(fn _, %{code: code, state: state}, %{context: context} ->
        with :ok <- check_wechat_callback_limits(context) do
          case Cgc2046.Accounts.WechatWebSignIn.sign_in_with_wechat(state, code, context) do
            {:ok, :signed_in, user} ->
              {:ok,
               %{
                 status: :signed_in,
                 bind_ticket: nil,
                 __token__: user.__metadata__[:token]
               }}

            {:ok, :needs_binding, bind_ticket} ->
              {:ok, %{status: :needs_binding, bind_ticket: bind_ticket}}

            {:error, _reason} ->
              # 防枚举：state/code/身份命中细节不外泄
              {:error, message: "WeChat sign in failed", code: "wechat_sign_in_failed"}
          end
        else
          {:error, :rate_limited} ->
            {:error, message: "Too many requests. Try again later.", code: "rate_limited"}
        end
      end)

      middleware(fn res, _ ->
        case res.value do
          %{__token__: token} when is_binary(token) ->
            %{res | context: Map.put(res.context, :cgc_auth_token, token)}

          _ ->
            res
        end
      end)
    end

    @desc "微信扫码绑定手机号完成登录（plan 002 U4；phone 5/15min 限流）"
    field :bind_wechat_with_phone, :sign_in_with_phone_code_result do
      arg(:bind_ticket, non_null(:string))
      arg(:phone, non_null(:string))
      arg(:code, non_null(:string))

      resolve(fn _,
                 %{bind_ticket: bind_ticket, phone: raw_phone, code: code},
                 %{context: context} ->
        with {:ok, phone} <- Cgc2046.Accounts.PhoneNumber.normalize(raw_phone),
             :ok <- check_wechat_bind_limits(context, phone) do
          case Cgc2046.Accounts.WechatWebSignIn.bind_wechat_with_phone(
                 bind_ticket,
                 phone,
                 code,
                 context
               ) do
            {:ok, user} ->
              {:ok,
               %{
                 id: user.id,
                 email: user.email,
                 is_platform_admin: user.is_platform_admin,
                 __token__: user.__metadata__[:token]
               }}

            {:error, :invalid_or_expired_code} ->
              {:error, message: "Invalid or expired code", code: "invalid_or_expired_code"}

            {:error, :invalid_bind_ticket} ->
              {:error, message: "Invalid binding session", code: "invalid_bind_ticket"}

            {:error, _reason} ->
              {:error, message: "Binding failed", code: "wechat_bind_failed"}
          end
        else
          {:error, :invalid} ->
            {:error, message: "Invalid phone number", code: "invalid_phone"}

          {:error, :rate_limited} ->
            {:error, message: "Too many requests. Try again later.", code: "rate_limited"}
        end
      end)

      middleware(fn res, _ ->
        case res.value do
          %{__token__: token} when is_binary(token) ->
            %{res | context: Map.put(res.context, :cgc_auth_token, token)}

          _ ->
            res
        end
      end)
    end

    @desc "注册新用户（#60 路径 B：httpOnly cookie 交付 token，自动登录）"
    field :sign_up, :sign_up_payload do
      arg(:input, non_null(:sign_up_input))

      middleware(Cgc2046Web.Plugs.RateLimit, key_path: [:input, :email])

      resolve(fn _, %{input: %{email: email, password: password}}, %{context: context} ->
        changeset =
          Cgc2046.Accounts.User
          |> Ash.Changeset.for_create(:register_with_password, %{email: email, password: password})

        try do
          case Ash.create(changeset) do
            {:ok, user} ->
              token = user.__metadata__[:token]

              # ADR-0004 §3.5：新用户自动加入默认社区 workspace 2046（无差异标签）
              # + 建 per-workspace 档案。失败降级不阻断注册（2046 是保障而非硬依赖）。
              # 故意宽捕 rescue：入座失败不应让注册 500（user 已建，2046 是兜底），
              # 包括编程错误也一律降级为 warning 日志——后续排查依赖该日志，不静默吞掉。
              try do
                case Cgc2046.Accounts.MembershipContext.admit_to_default_workspace(user.id) do
                  {:ok, _} ->
                    :ok

                  {:error, reason} ->
                    Logger.warning("[signUp] default workspace enroll failed: #{inspect(reason)}")
                end
              rescue
                error ->
                  Logger.warning(
                    "[signUp] default workspace enroll raised: #{Exception.message(error)}"
                  )
              end

              {:ok,
               %{
                 result: %{
                   id: user.id,
                   email: user.email,
                   is_platform_admin: user.is_platform_admin
                 },
                 errors: [],
                 # token 仅用于 middleware 传递到 before_send，不暴露在响应中
                 __token__: token
               }}

            {:error, %Ash.Error.Invalid{} = error} ->
              # #86 防邮箱枚举：「邮箱已存在」的 has already been taken + fields: [:email]
              # 是可枚举信号。unique_email 冲突时返回与未知错误分支同码同形的
              # registration_failed（重复邮箱失败与其它失败不可区分）；非唯一性
              # 校验错误（格式/密码等）仍走 AshGraphql.Error 结构化透传——格式非法
              # 邮箱不可能入库，其错误不泄露存在性，且 message 可指导用户修正输入。
              if unique_email_conflict?(error) do
                {:ok, registration_failed_payload()}
              else
                {:ok,
                 %{
                   result: nil,
                   errors: to_ash_graphql_errors(error, context, :register_with_password),
                   __token__: nil
                 }}
              end

            {:error, _error} ->
              {:ok, registration_failed_payload()}
          end
        rescue
          _ ->
            {:ok, registration_failed_payload()}
        end
      end)

      middleware(fn res, _ ->
        case res.value do
          %{__token__: token} when is_binary(token) ->
            %{res | context: Map.put(res.context, :cgc_auth_token, token)}

          _ ->
            res
        end
      end)
    end

    @desc "请求发送密码重置邮件（无论邮箱是否存在都返回统一成功结果）"
    field :request_password_reset, :request_password_reset_result do
      arg(:email, non_null(:string))

      middleware(
        Cgc2046Web.Plugs.RateLimit,
        key_path: [:email],
        normalize: &normalize_email/1
      )

      resolve(fn _, %{email: email}, %{context: context} ->
        email = normalize_email(email)

        case check_password_reset_request_limits(context, email) do
          :ok ->
            strategy = AshAuthentication.Info.strategy!(Cgc2046.Accounts.User, :password)

            _ =
              AshAuthentication.Strategy.action(
                strategy,
                :reset_request,
                %{"email" => email}
              )

            {:ok, %{sent: true}}

          :error ->
            {:error, message: "Too many requests. Try again later.", code: "rate_limited"}
        end
      end)
    end

    @desc "使用一次性密码重置 token 设置新密码"
    field :reset_password, :reset_password_result do
      arg(:reset_token, non_null(:string))
      arg(:password, non_null(:string))

      middleware(Cgc2046Web.Plugs.RateLimit, key_path: [:reset_token])

      resolve(fn _, %{reset_token: reset_token, password: password}, %{context: context} ->
        params = %{
          "reset_token" => reset_token,
          "password" => password
        }

        strategy = AshAuthentication.Info.strategy!(Cgc2046.Accounts.User, :password)

        try do
          case AshAuthentication.Strategy.action(strategy, :reset, params) do
            {:ok, _user} ->
              {:ok, %{ok: true}}

            {:error, error} ->
              classify_password_reset_error(error, context)

            other ->
              report_password_reset_failure(other)
          end
        rescue
          error ->
            report_password_reset_failure(error)
        catch
          kind, reason ->
            report_password_reset_failure({kind, reason})
        end
      end)
    end

    @desc "小程序平台一键登录（N1，Phase 1）：code2session + 平台手机号锚定统一身份，token 经 httpOnly cookie 交付"
    field :sign_in_with_platform, :sign_in_with_platform_result do
      arg(:platform, non_null(:string))
      arg(:code, non_null(:string))
      arg(:phone_code, :string)
      arg(:encrypted_data, :string)
      arg(:iv, :string)

      # getPhoneNumber 计费防刷：复用既有 RateLimit（按 IP+platform 计，5 次/15 分钟）
      middleware(Cgc2046Web.Plugs.RateLimit, key_path: [:platform])

      resolve(fn _, %{platform: platform, code: code} = args, _ ->
        # phone_code/encrypted_data/iv 可空（phone_code 或 encrypted_data+iv 二选一，
        # 由 SignInPreparation.fetch_phone 校验组合）；缺键时 Map.get 得 nil 透传。
        query =
          Cgc2046.Accounts.User
          |> Ash.Query.for_read(:sign_in_with_miniprogram, %{
            platform: platform,
            code: code,
            phone_code: Map.get(args, :phone_code),
            encrypted_data: Map.get(args, :encrypted_data),
            iv: Map.get(args, :iv)
          })

        try do
          case Ash.read(query) do
            {:ok, [user]} ->
              {:ok,
               %{
                 id: user.id,
                 email: user.email,
                 is_platform_admin: user.is_platform_admin,
                 # token 仅用于 middleware 传递到 before_send，不暴露在响应中
                 __token__: user.__metadata__[:token]
               }}

            {:error, _error} ->
              {:error, message: "Platform sign in failed", code: "authentication_failed"}
          end
        rescue
          _ -> {:error, message: "Platform sign in failed", code: "authentication_failed"}
        end
      end)

      middleware(fn res, _ ->
        case res.value do
          %{__token__: token} when is_binary(token) ->
            %{res | context: Map.put(res.context, :cgc_auth_token, token)}

          _ ->
            res
        end
      end)
    end

    @desc "Owner/Admin 创建一次性工作台邀请小程序码"
    field :generate_mini_program_code, :miniprogram_code_result do
      arg(:workspace_id, non_null(:id))
      arg(:platform, non_null(:string))

      middleware(Cgc2046Web.Plugs.RateLimit, key_path: [:workspace_id])

      resolve(fn _, %{workspace_id: workspace_id, platform: platform}, %{context: context} ->
        with_actor(context, fn actor ->
          case Cgc2046.MiniprogramCode.generate(workspace_id, actor, platform) do
            {:ok, result} ->
              {:ok, result}

            {:error, :forbidden} ->
              {:error, message: "Forbidden", code: "forbidden"}

            {:error, :invalid_platform} ->
              {:error, message: "Invalid platform", code: "invalid_platform"}

            {:error, :daily_quota_exhausted} ->
              {:error, message: "Daily quota exhausted", code: "daily_quota_exhausted"}

            {:error, _} ->
              {:error, message: "Code generation failed", code: "code_generation_failed"}
          end
        end)
      end)
    end

    @desc "使用一次性小程序 scene 接受工作台邀请"
    field :admit_member_by_token, :invitation do
      arg(:scene, non_null(:string))

      middleware(Cgc2046Web.Plugs.RateLimit, key_path: [:scene])

      resolve(fn _, %{scene: scene}, %{context: context} ->
        cond do
          is_nil(context[:actor]) ->
            {:error, unauthorized_error()}

          not Cgc2046.MiniprogramCode.valid_scene?(scene) ->
            {:error, message: "Invalid scene", code: "invalid_scene"}

          true ->
            actor = context[:actor]

            with {:ok, code} <- Cgc2046.MiniprogramCode.code_for_scene(scene),
                 {:ok, invitation} <-
                   Ash.get(Cgc2046.Accounts.Invitation, code.invitation_id, authorize?: false),
                 {:ok, accepted} <-
                   invitation
                   |> Ash.Changeset.for_update(:accept_miniprogram, %{scene: scene})
                   |> Ash.update(actor: actor) do
              {:ok, accepted}
            else
              {:error, :invalid_scene} ->
                {:error, message: "Invalid scene", code: "invalid_scene"}

              {:error, :invalid_or_expired_scene} ->
                {:error,
                 message: "Invitation has already been used or scene has expired",
                 code: "invalid_or_expired_scene"}

              {:error, error} ->
                {:error,
                 to_ash_graphql_errors(
                   error,
                   context,
                   :accept_miniprogram,
                   Cgc2046.Accounts.Invitation
                 )}
            end
        end
      end)
    end

    @desc "接受邀请→建 Membership + 预授权角色入座（#96：手写 resolver 绕过 read policy 记录加载）"
    field :accept_invitation, :accept_invitation_result do
      arg(:id, non_null(:id))
      arg(:input, non_null(:accept_invitation_input))

      # 手写 field 不经过 middleware/3 回调（那是 AshGraphql 自动 mutation 的接线），
      # 与 admit_member_by_token 一致显式挂载；限流 key 与自动 mutation 相同（input.token）。
      middleware(Cgc2046Web.Plugs.RateLimit, key_path: [:input, :token])

      resolve(fn _, %{id: id, input: %{token: token}}, %{context: context} ->
        with_actor(context, fn actor ->
          # #96：AshGraphql update mutation 的 read-before-write 用 :read action 加载记录
          # （read policy 下推成 inviter_id == actor.id），受邀者被拒成 not_found，到不了
          # accept action。这里改为 id + token_hash 双因子定位 + authorize?: false 加载：
          # 两个条件都匹配才放行（token 是凭证，与 validateInvitation 信息面一致），
          # 不匹配返回 not_found，不泄露邀请存在性。accept action 的
          # authorize_if(actor_present()) 与 before_action token 复验仍完整生效。
          # token_credential_fetch 以 extra_filter: [id: id] 保留双因子，nil 塌缩为
          # :invalid_token，由调用方映射回 accept_not_found_errors（not_found 语义）。
          with {:ok, invitation} <-
                 token_credential_fetch(Cgc2046.Accounts.Invitation, token, id: id),
               {:ok, accepted} <-
                 invitation
                 |> Ash.Changeset.for_update(:accept, %{token: token})
                 |> Ash.update(actor: actor) do
            {:ok, %{result: accepted, errors: []}}
          else
            {:error, :invalid_token} ->
              {:ok, %{result: nil, errors: accept_not_found_errors(context, id)}}

            {:error, error} ->
              {:ok,
               %{
                 result: nil,
                 errors:
                   to_ash_graphql_errors(
                     error,
                     context,
                     :accept,
                     Cgc2046.Accounts.Invitation
                   )
               }}
          end
        end)
      end)
    end

    @desc "记录一次小程序订阅消息授权并增加一个可用次数"
    field :grant_mini_program_notification_consent, :integer do
      arg(:platform, non_null(:string))
      arg(:template_key, non_null(:string))

      middleware(Cgc2046Web.Plugs.RateLimit, key_path: [:platform])

      resolve(fn _, %{platform: platform, template_key: template_key}, %{context: context} ->
        with_actor(context, fn actor ->
          case Cgc2046.NotificationConsent.grant(actor.id, platform, template_key) do
            {:ok, remaining} ->
              {:ok, remaining}

            {:error, :invalid_platform} ->
              {:error, message: "Invalid platform", code: "invalid_platform"}

            {:error, _} ->
              {:error, message: "Consent grant failed", code: "consent_grant_failed"}
          end
        end)
      end)
    end

    @desc "登出：服务端撤销当前 token 并清除 httpOnly cookie（token 被偷也无法重放）"
    field :sign_out, :string do
      resolve(fn _, _, _ ->
        {:ok, "signed_out"}
      end)

      middleware(fn res, _ ->
        revoke_bearer_token(res.context)
        %{res | context: Map.put(res.context, :cgc_clear_token, true)}
      end)
    end

    @desc "更新当前用户全局显示名（ADR-0004：displayName 保留全局身份字段）"
    field :update_display_name, :user do
      arg(:display_name, non_null(:string))

      resolve(fn _, %{display_name: display_name}, %{context: context} ->
        with_actor(context, fn actor ->
          case Ash.update(actor, %{display_name: display_name},
                 action: :update_display_name,
                 actor: actor
               ) do
            {:ok, user} ->
              # member_number/joined_at 为计算属性，返回前需显式加载
              load_profile(user, actor, context, :update_display_name)

            {:error, error} ->
              {:error, to_ash_graphql_errors(error, context, :update_display_name)}
          end
        end)
      end)
    end

    @desc "更新当前用户界面语言偏好（i18n Phase 1；zh-CN | en，仅本人）"
    field :update_my_locale, :user do
      arg(:locale, non_null(:string))

      resolve(fn _, %{locale: locale}, %{context: context} ->
        with_actor(context, fn actor ->
          case Ash.update(actor, %{locale: locale},
                 action: :update_locale,
                 actor: actor
               ) do
            {:ok, user} ->
              load_profile(user, actor, context, :update_locale)

            {:error, error} ->
              {:error, to_ash_graphql_errors(error, context, :update_locale)}
          end
        end)
      end)
    end

    @desc "更新当前用户在某工作台的资料（ADR-0004 per-workspace）"
    field :update_workspace_profile, :workspace_profile do
      arg(:workspace_id, non_null(:id))
      arg(:input, non_null(:update_workspace_profile_input))

      resolve(fn _, %{workspace_id: workspace_id, input: input}, %{context: context} ->
        with_actor(context, fn actor ->
          scoped_update(
            actor,
            Cgc2046.Accounts.WorkspaceProfile,
            workspace_id,
            :update_profile,
            map_input(input),
            context
          )
        end)
      end)
    end

    @desc "设置当前用户在某工作台的 UI 主题偏好（ADR-0004 per-workspace）"
    field :set_workspace_theme, :workspace_profile do
      arg(:workspace_id, non_null(:id))
      arg(:input, non_null(:set_workspace_theme_input))

      resolve(fn _, %{workspace_id: workspace_id, input: input}, %{context: context} ->
        with_actor(context, fn actor ->
          scoped_update(
            actor,
            Cgc2046.Accounts.WorkspaceProfile,
            workspace_id,
            :set_ui_theme,
            %{ui_theme_preference: input.ui_theme_preference},
            context
          )
        end)
      end)
    end

    @desc "在某工作台创建作品集条目（ADR-0004；workspace_id 与 user_id 自动填充，防跨租户伪造）"
    field :create_portfolio_item, :portfolio_item do
      arg(:workspace_id, non_null(:id))
      arg(:input, non_null(:create_portfolio_item_input))

      resolve(fn _, %{workspace_id: workspace_id, input: input}, %{context: context} ->
        with_actor(context, fn actor ->
          attrs = map_input(input, [:title, :description, :url, :icon])

          Cgc2046.Accounts.PortfolioItem
          |> Ash.Changeset.for_create(:create, attrs)
          |> Ash.create(tenant: workspace_id, actor: actor)
        end)
      end)
    end

    @desc "更新某工作台自己的作品集条目（ADR-0004；tenant 隔离）"
    field :update_portfolio_item, :portfolio_item do
      arg(:id, non_null(:id))
      arg(:workspace_id, non_null(:id))
      arg(:input, non_null(:update_portfolio_item_input))

      resolve(fn _, %{id: id, workspace_id: workspace_id, input: input}, %{context: context} ->
        with_actor(context, fn actor ->
          attrs = map_input(input, [:title, :description, :url, :icon])

          with {:ok, item} <-
                 Cgc2046.Accounts.PortfolioItem
                 |> Ash.get(id, tenant: workspace_id, actor: actor) do
            item
            |> Ash.Changeset.for_update(:update, attrs)
            |> Ash.update(tenant: workspace_id, actor: actor)
          end
        end)
      end)
    end

    @desc "删除某工作台自己的作品集条目（ADR-0004；tenant 隔离）"
    field :delete_portfolio_item, :portfolio_item do
      arg(:id, non_null(:id))
      arg(:workspace_id, non_null(:id))

      resolve(fn _, %{id: id, workspace_id: workspace_id}, %{context: context} ->
        with_actor(context, fn actor ->
          with {:ok, item} <-
                 Cgc2046.Accounts.PortfolioItem
                 |> Ash.get(id, tenant: workspace_id, actor: actor) do
            case Ash.destroy(item, tenant: workspace_id, actor: actor) do
              :ok -> {:ok, item}
              {:error, error} -> {:error, error}
            end
          end
        end)
      end)
    end

    @desc "签发 MCP 连接 token（切片 D #44；明文仅本次经 plainToken 返回一次，库中只存 SHA256 hash）"
    field :create_mcp_token, :create_mcp_token_payload do
      arg(:name, non_null(:string))

      resolve(fn _, %{name: name}, %{context: context} ->
        with_actor(context, fn actor ->
          case Cgc2046.Mcp.Token.issue(name, actor) do
            {:ok, token, plain} ->
              {:ok, %{result: token, plain_token: plain, errors: []}}

            {:error, error} ->
              {:ok,
               %{
                 result: nil,
                 plain_token: nil,
                 errors:
                   to_ash_graphql_errors(error, context, :issue, Cgc2046.Mcp.Token, Cgc2046.Mcp)
               }}
          end
        end)
      end)
    end

    @desc "撤销 MCP 连接 token（切片 D #44；仅本人，置 revokedAt 保留审计行；他人 token 一律 not_found 不泄露存在性）"
    field :revoke_mcp_token, :mcp_token do
      arg(:id, non_null(:id))

      resolve(fn _, %{id: id}, %{context: context} ->
        with_actor(context, fn actor ->
          case Cgc2046.Mcp.Token.revoke(id, actor) do
            {:ok, revoked} ->
              {:ok, revoked}

            {:error, :not_found} ->
              # NotFound（他人 token / 不存在 id）统一塌缩，不泄露存在性。
              # 与 invalid 分支同经 AshGraphql 序列化（message/code/fields 齐备），
              # 恢复 AshGraphql 原行为的 error 结构（message "could not be found"、
              # fields ["id"]）。
              {:error,
               to_ash_graphql_errors(
                 Ash.Error.Query.NotFound.exception(
                   primary_key: %{id: id},
                   resource: Cgc2046.Mcp.Token
                 ),
                 context,
                 :revoke,
                 Cgc2046.Mcp.Token,
                 Cgc2046.Mcp
               )}

            {:error, {:invalid, error}} ->
              {:error,
               to_ash_graphql_errors(error, context, :revoke, Cgc2046.Mcp.Token, Cgc2046.Mcp)}
          end
        end)
      end)
    end

    # ── SpeakerInvitation（E-4 #49；手写 resolver 绕过 read policy 记录加载，同 accept_invitation #96 先例）──

    @desc "Owner/Admin 创建 Speaker 邀请；明文 token 仅经 plainToken 返回一次（库中只存 SHA256 哈希）"
    field :create_speaker_invitation, :create_speaker_invitation_payload do
      arg(:input, non_null(:create_speaker_invitation_input))

      resolve(fn _, %{input: input}, %{context: context} ->
        with %{workspace_id: workspace_id} <- input,
             actor when not is_nil(actor) <- context[:actor],
             {:ok, invitation, plain_token} <-
               Cgc2046.Events.SpeakerInvitation.issue(
                 map_input(input, [
                   :event_id,
                   :speaker_name,
                   :speaker_email,
                   :topic,
                   :scheduled_at,
                   :note,
                   :expires_at
                 ]),
                 actor,
                 workspace_id
               ) do
          {:ok, %{result: invitation, plain_token: plain_token, errors: []}}
        else
          %{} ->
            {:error, [message: "workspaceId is required", code: "invalid_input"]}

          nil ->
            {:error, unauthorized_error()}

          {:error, error} ->
            {:ok,
             %{
               result: nil,
               plain_token: nil,
               errors:
                 to_ash_graphql_errors(
                   error,
                   context,
                   :create_invitation,
                   Cgc2046.Events.SpeakerInvitation,
                   Cgc2046.Api
                 )
             }}
        end
      end)
    end

    @desc "Speaker 用邀请 token 接受邀请（着陆页；token 一次性，接受后失效）"
    field :accept_speaker_invitation, :speaker_invitation_action_payload do
      arg(:token, non_null(:string))

      # 手写 field 不经过 middleware/3 回调，与 admit_member_by_token 一致显式挂载；
      # 限流按 IP+token 计（5 次/15 分钟，复用 RateLimit plug）。
      middleware(Cgc2046Web.Plugs.RateLimit, key_path: [:token])

      resolve(fn _, %{token: token}, context ->
        decide_speaker_invitation(context, token, :accept_invitation)
      end)
    end

    @desc "Speaker 用邀请 token 婉拒邀请（着陆页；token 一次性，婉拒后失效）"
    field :decline_speaker_invitation, :speaker_invitation_action_payload do
      arg(:token, non_null(:string))

      middleware(Cgc2046Web.Plugs.RateLimit, key_path: [:token])

      resolve(fn _, %{token: token}, context ->
        decide_speaker_invitation(context, token, :decline_invitation)
      end)
    end

    @desc "Speaker 保存分享材料（落 WorkflowRun.facts[materials]；Speaker 本人自助或 Owner/Admin 兜底；materials 为 JSON 字符串）"
    field :save_speaker_materials, :speaker_invitation_action_payload do
      arg(:invitation_id, non_null(:id))
      arg(:materials, non_null(:json_string))

      resolve(fn _, %{invitation_id: id, materials: materials}, %{context: context} ->
        with_actor(context, fn actor ->
          case Ash.get(Cgc2046.Events.SpeakerInvitation, id, authorize?: false) do
            {:ok, invitation} when not is_nil(invitation) ->
              invitation
              |> Ash.Changeset.for_update(:save_materials, %{materials: materials},
                actor: actor,
                tenant: invitation.workspace_id
              )
              |> Ash.update(tenant: invitation.workspace_id, actor: actor)
              |> speaker_invitation_action_result(context, :save_materials)

            _ ->
              {:ok,
               %{result: nil, errors: [%{message: "invitation not found", code: "not_found"}]}}
          end
        end)
      end)
    end

    @desc "材料产出后完成邀请（Speaker 本人自助或 Owner/Admin 兜底；accepted → completed）"
    field :complete_speaker_invitation, :speaker_invitation_action_payload do
      arg(:id, non_null(:id))

      resolve(fn _, %{id: id}, %{context: context} ->
        with_actor(context, fn actor ->
          case Ash.get(Cgc2046.Events.SpeakerInvitation, id, authorize?: false) do
            {:ok, invitation} when not is_nil(invitation) ->
              invitation
              |> Ash.Changeset.for_update(:complete_speaking, %{},
                actor: actor,
                tenant: invitation.workspace_id
              )
              |> Ash.update(tenant: invitation.workspace_id, actor: actor)
              |> speaker_invitation_action_result(context, :complete_speaking)

            _ ->
              {:ok,
               %{result: nil, errors: [%{message: "invitation not found", code: "not_found"}]}}
          end
        end)
      end)
    end

    # ── Platform Admin Dashboard Phase 5：admin mutations（R9 promote/demote）──

    @desc "平台管理员：提升用户为 platform_admin（R9；仅 platform_admin 可调）"
    field :promote_user, :admin_user_payload do
      arg(:id, non_null(:id))

      resolve(fn _, %{id: id}, %{context: context} ->
        with_admin(context, fn actor ->
          with {:ok, user} <- Ash.get(Cgc2046.Accounts.User, id, actor: actor) do
            user
            |> Ash.Changeset.for_update(:set_platform_admin, %{is_platform_admin: true})
            |> Ash.update(actor: actor)
            |> map_update_result(context, :set_platform_admin)
          else
            {:error, error} ->
              {:error,
               to_ash_graphql_errors(error, context, :set_platform_admin, Cgc2046.Accounts.User)}
          end
        end)
      end)
    end

    @desc "平台管理员：降级用户 platform_admin（R9；≥1 admin 不变量由 User :demote_platform_admin action 守卫）"
    field :demote_user, :admin_user_payload do
      arg(:id, non_null(:id))

      resolve(fn _, args, %{context: context} ->
        with_admin(context, fn actor ->
          with {:ok, user} <- Ash.get(Cgc2046.Accounts.User, args[:id], actor: actor) do
            # ≥1 admin 原子判定与错误契约（last_admin_denied / not_platform_admin）
            # 全在 action 内：不变量唯一入口，resolver 仅透传为 payload errors。
            # demote_platform_admin 非 primary update action，须经 for_update
            # 构造 changeset（同 promote 调 set_platform_admin 的范式）。
            user
            |> Ash.Changeset.for_update(:demote_platform_admin, %{})
            |> Ash.update(actor: actor)
            |> map_update_result(context, :demote_platform_admin)
          else
            {:error, error} ->
              {:error,
               to_ash_graphql_errors(
                 error,
                 context,
                 :demote_platform_admin,
                 Cgc2046.Accounts.User
               )}
          end
        end)
      end)
    end
  end

  # ── RBAC 类型（#66 角色权限矩阵；原 rbac_types.ex 内联，唯一消费者为本 schema） ──

  object :ability_grant do
    field(:name, non_null(:string),
      description:
        "能力名：view_workspace / access_invite_only / list_members / manage_members / assign_roles / create_workspace"
    )

    field(:allowed, non_null(:boolean))
  end

  object :permission_matrix_row do
    field(:name, non_null(:string),
      description: "角色名：owner / admin / tutor / volunteer / learner"
    )

    field(:abilities, non_null(list_of(non_null(:ability_grant))))
  end

  object :permission_matrix_payload do
    field(:roles, non_null(list_of(non_null(:permission_matrix_row))))
  end

  object :offering_readiness_payload do
    field(:ready, non_null(:boolean))
    field(:items, non_null(list_of(non_null(:offering_readiness_item))))
  end

  object :offering_readiness_item do
    field(:key, non_null(:string))
    field(:label, non_null(:string))
    field(:ok, non_null(:boolean))
  end

  object :pending_approval do
    field(:id, non_null(:id))
    field(:kind, non_null(:string))
    field(:workspace_id, non_null(:id))
    field(:user_id, non_null(:id))
    field(:event_id, :id)
    field(:course_id, :id)
    field(:status, non_null(:string))
    field(:approval_deadline, :datetime)
    field(:expired_at, :datetime)
    field(:requester_name, :string)
    field(:workspace_name, :string)
    field(:context_title, :string)

    # E-9 #123 expired 重提链接落点字段（workspace_slug 全 kind；event_slug
    # 仅 sponsorship event 级行非空，可空供给物无 slug）
    field(:workspace_slug, :string)
    field(:event_slug, :string)

    # E-3 #48 sponsorship 行（其他 kind 为 null）
    field(:level, :string)
    field(:company_name, :string)
    field(:contact_email, :string)
    field(:tier_name, :string)
    field(:amount, :integer)
  end

  object :enrollment do
    field(:id, non_null(:id))
    field(:workspace_id, non_null(:id))
    field(:event_id, :id)
    field(:course_id, :id)
    field(:user_id, non_null(:id))
    field(:workflow_run_id, :id)
    field(:invite_batch_id, :id)
    field(:status, non_null(:string))
    field(:capacity_seq, :integer)
    field(:approved_by, :id)
    field(:approved_at, :datetime)
    field(:rejection_reason, :string)
    field(:approval_deadline, :datetime)
    field(:expired_at, :datetime)
    field(:cancelled_at, :datetime)
    field(:inserted_at, non_null(:datetime))
    field(:target_title, :string)
  end

  # U7(#180/KD8):issue 级进度,旧 manual-steps 字段(completedManualSteps/
  # totalManualSteps/currentStepTitle)与 manual_steps_compat 派生已删——
  # 直接替换不留兼容层(AGENTS.md);currentIssueId 供抽屉/扩展联动。
  object :my_learning_run do
    field(:run_id, non_null(:id))
    field(:enrollment_id, non_null(:id))
    field(:target_title, :string)
    field(:status, non_null(:string))
    field(:done_issues, non_null(:integer))
    field(:total_issues, non_null(:integer))
    field(:current_issue_id, :string)
    field(:current_issue_title, :string)
    field(:current_issue_key, :string)
    field(:course_id, :id)
  end

  # U7(#180/R11):学员视角课程学习详情(抽屉数据)。issues 含三态 + checklist
  # 逐条(与本人记录合成:evidence 摘要 + 时间)——与公开地图(issue_map,
  # goal-only)不同面,本查询仅登录 actor 本人可见(恒 actor,无他人视角)。
  object :course_learning_detail do
    field(:course_id, non_null(:id))
    field(:title, non_null(:string))
    field(:slug, :string)
    field(:goals, non_null(list_of(non_null(:string))))
    field(:issues, non_null(list_of(non_null(:learning_issue))))
    field(:progress, :learning_progress)
  end

  object :learning_issue do
    field(:key, non_null(:string))
    field(:id, non_null(:string))
    field(:title, non_null(:string))
    field(:kind, non_null(:string))
    field(:status, non_null(:string))
    field(:story, :issue_story)
  end

  object :issue_story do
    field(:as_a, :string)
    field(:given, non_null(list_of(non_null(:string))))
    field(:goal, :string)
    field(:materials, non_null(list_of(non_null(:issue_material))))
    field(:checklist, non_null(list_of(non_null(:issue_checklist_item))))
  end

  object :issue_material do
    field(:title, :string)
    field(:ref, :string)
  end

  # U7(#180/R10):公开课程地图行(goal-only,无 checklist 字段——object 面
  # 即契约:想露 checklist 必须改此 object,评审可见)。
  object :course_map do
    field(:course_id, non_null(:id))

    field(:title, non_null(:string))
    field(:slug, non_null(:string))
    field(:goals, non_null(list_of(non_null(:string))))
    field(:issues, non_null(list_of(non_null(:course_map_issue))))
  end

  object :course_map_issue do
    field(:key, non_null(:string))
    field(:id, non_null(:string))
    field(:title, non_null(:string))
    field(:kind, non_null(:string))
    field(:goal, :string)
  end

  object :issue_checklist_item do
    field(:id, non_null(:string))
    field(:text, non_null(:string))
    field(:done, non_null(:boolean))
    field(:evidence, :string)
    field(:recorded_at, :datetime)
  end

  object :learning_progress do
    field(:done_issues, non_null(:integer))
    field(:total_issues, non_null(:integer))
    field(:current_issue_id, :string)
    field(:current_issue_title, :string)
    field(:current_issue_key, :string)
  end

  object :workspace_tool_call do
    field(:id, non_null(:id))
    field(:tool, non_null(:string))
    field(:status, non_null(:string))
    field(:latency_ms, :integer)
    field(:inserted_at, non_null(:datetime))
    field(:error_message, :string)
  end

  object :miniprogram_code_result do
    field(:invitation_id, non_null(:id))
    field(:platform, non_null(:string))
    field(:scene, non_null(:string))
    field(:code_base64, non_null(:string))
    field(:expires_at, non_null(:datetime))
  end

  # ── 认证相关类型（#60 路径 B：httpOnly cookie 交付 token） ──────────────

  # 持 token 的邀请接口限流：validate/accept 均吃明文 token 参数，按 IP+token 计，
  # 5 次/15 分钟（复用 RateLimit plug，与 sign_in/sign_up 同档位）。
  # token 为 256-bit 强随机，枚举不成立；此为已知 token 被滥用探测时的加固。
  # arity-3：Absinthe 的 middleware callback 是 arity-3（schema.middleware(mw, field, object)），
  # arity-2 不会被框架调用。
  def middleware(middleware, %{identifier: :validate_invitation}, _object),
    do: [{Cgc2046Web.Plugs.RateLimit, key_path: [:token]} | middleware]

  # 注：accept_invitation 现为手写 field，RateLimit 在 field 内显式挂载
  # （手写 field 不经过 middleware/3 回调），不再需要此处的 identifier 分支。

  def middleware(middleware, _field, _object), do: middleware

  object :sign_in_result do
    field(:id, non_null(:id))
    field(:email, non_null(:string))
    field(:is_platform_admin, non_null(:boolean))
  end

  object :request_password_reset_result do
    field(:sent, non_null(:boolean))
  end

  object :reset_password_result do
    field(:ok, non_null(:boolean))
  end

  # 小程序手机号用户无邮箱 → email 可空（与 users.email 放宽一致）
  object :sign_in_with_platform_result do
    field(:id, non_null(:id))
    field(:email, :string)
    field(:is_platform_admin, non_null(:boolean))
  end

  # 手机验证码登录（plan 002 U3）：phone 用户 email 可空（同 platform result）
  object :request_phone_code_result do
    field(:sent, non_null(:boolean))
    field(:retry_after_seconds, non_null(:integer))
  end

  enum :phone_code_purpose do
    value(:login)
    value(:wechat_bind)
  end

  object :sign_in_with_phone_code_result do
    field(:id, non_null(:id))
    field(:email, :string)
    field(:is_platform_admin, non_null(:boolean))
  end

  # 微信扫码登录（plan 002 U4）
  object :wechat_login_start_result do
    field(:qr_url, non_null(:string))
    field(:state, non_null(:string))
    field(:expires_in_seconds, non_null(:integer))
  end

  object :sign_in_with_wechat_result do
    field(:status, non_null(:wechat_sign_in_status))
    field(:bind_ticket, :string)
  end

  enum :wechat_sign_in_status do
    value(:signed_in)
    value(:needs_binding)
  end

  object :sign_up_payload do
    field(:result, :sign_up_user)
    field(:errors, list_of(:mutation_error))
  end

  object :sign_up_user do
    field(:id, non_null(:id))
    field(:email, non_null(:string))
    field(:is_platform_admin, non_null(:boolean))
  end

  input_object :sign_up_input do
    field(:email, non_null(:string))
    field(:password, non_null(:string))
  end

  # ── 个人资料相关类型（ADR-0004 per-workspace）────────────────────────

  object :workspace_profile do
    @desc "per-workspace 成员公开资料（ADR-0004）"
    field(:id, non_null(:id))
    field(:workspace_id, non_null(:id))
    field(:user_id, non_null(:id))
    field(:avatar_url, :string)
    field(:location, :string)
    field(:about, :string)
    field(:skills, list_of(:string))
    field(:visibility, :string)
    field(:ui_theme_preference, non_null(:string))
  end

  object :portfolio_item do
    @desc "per-workspace 作品集条目（ADR-0004）"
    field(:id, non_null(:id))
    field(:workspace_id, non_null(:id))
    field(:title, non_null(:string))
    field(:description, :string)
    field(:url, :string)
    field(:icon, non_null(:string))
  end

  input_object :update_workspace_profile_input do
    @desc "updateWorkspaceProfile 输入（ADR-0004）：avatarUrl/location/about/skills/visibility 可选"
    field(:avatar_url, :string)
    field(:location, :string)
    field(:about, :string)
    field(:skills, list_of(:string))
    field(:visibility, :string)
  end

  input_object :set_workspace_theme_input do
    @desc "setWorkspaceTheme 输入：uiThemePreference 必填，仅 dark | light"
    field(:ui_theme_preference, non_null(:string))
  end

  input_object :create_portfolio_item_input do
    @desc "createPortfolioItem 输入：title 必填，description/url/icon 可选"
    field(:title, non_null(:string))
    field(:description, :string)
    field(:url, :string)
    field(:icon, :string)
  end

  input_object :update_portfolio_item_input do
    @desc "updatePortfolioItem 输入：title/description/url/icon 可选"
    field(:title, :string)
    field(:description, :string)
    field(:url, :string)
    field(:icon, :string)
  end

  # ── MCP 连接 token（切片 D #44；手写三入口，资源不经 AshGraphql 自动暴露）──

  object :mcp_token do
    @desc "MCP 连接 token（明文不可经此类型读回；hash 不落 GraphQL 面）"
    field(:id, non_null(:id))
    field(:name, non_null(:string))
    field(:last_used_at, :datetime)
    field(:revoked_at, :datetime)
    field(:inserted_at, non_null(:datetime))
  end

  object :create_mcp_token_payload do
    @desc "createMcpToken 返回：result 为 token 记录；plainToken 明文仅此一次"
    field(:result, :mcp_token)
    field(:plain_token, :string)
    field(:errors, list_of(:mutation_error))
  end

  # acceptInvitation 手写 resolver 的类型（#96）：与自动生成的同名同形，
  # API 形态不变（acceptInvitation(id: ID!, input: AcceptInvitationInput!): AcceptInvitationResult!）。
  input_object :accept_invitation_input do
    @desc "acceptInvitation 输入：token 为明文邀请令牌（accept 须复验）"
    field(:token, non_null(:string))
  end

  object :accept_invitation_result do
    @desc "acceptInvitation 返回：result 为已接受邀请记录；errors 为业务错误"
    field(:result, :invitation)
    field(:errors, non_null(list_of(non_null(:mutation_error))))
  end

  # ── SpeakerInvitation（E-4 #49；record 类型由 AshGraphql 自动生成 :speaker_invitation，
  # 此处只定义卡片/输入/payload 类型；token_hash 已 hide_fields）──

  object :speaker_invitation_card do
    @desc "token 公开卡片：邀请主题/时间 + Event 公开信息（D2 白名单，不泄露其它邀请）"
    field(:status, non_null(:string))
    field(:topic, :string)
    field(:scheduled_at, :datetime)
    field(:event, non_null(:speaker_invitation_card_event))
  end

  object :speaker_invitation_card_event do
    field(:id, non_null(:id))
    field(:slug, :string)
    field(:title, non_null(:string))
    field(:description, :string)
    field(:status, non_null(:string))
  end

  input_object :create_speaker_invitation_input do
    @desc "createSpeakerInvitation 输入：workspaceId + eventId + speakerName 必填，其余可选"
    field(:workspace_id, non_null(:id))
    field(:event_id, non_null(:id))
    field(:speaker_name, non_null(:string))
    field(:speaker_email, :string)
    field(:topic, :string)
    field(:scheduled_at, :datetime)
    field(:note, :string)
    field(:expires_at, :datetime)
  end

  object :create_speaker_invitation_payload do
    @desc "createSpeakerInvitation 返回：result 为邀请记录；plainToken 明文仅此一次"
    field(:result, :speaker_invitation)
    field(:plain_token, :string)
    field(:errors, non_null(list_of(non_null(:mutation_error))))
  end

  object :speaker_invitation_action_payload do
    @desc "accept/decline/saveSpeakerMaterials/completeSpeakerInvitation 返回：result + errors 两段式"
    field(:result, :speaker_invitation)
    field(:errors, non_null(list_of(non_null(:mutation_error))))
  end

  # 未登录统一错误形状（message + code），供 me / update_profile / set_ui_theme
  # 的 actor nil 分支复用——与 sign_in 的 keyword list 错误走同一序列化路径。
  defp unauthorized_error, do: [message: "unauthorized", code: "unauthorized"]

  defp normalize_email(email) do
    email
    |> to_string()
    |> String.trim()
    |> String.downcase()
  end

  # ── 手机验证码（plan 002 U3）───────────────────────────────────────────

  # 发码四窗口限流（phone 1/60s + 5/1h + 20/1d，IP 30/1d）；固定窗口 ETS
  # 同款（密码重置双限流先例），多实例连调。
  defp check_phone_code_request_limits(context, phone) do
    ip = remote_ip(context)

    phone_key = Cgc2046Web.Plugs.RateLimit.build_key("rate:phone-code:phone", phone)

    windows = [
      {"#{phone_key}:1m", 60, 1},
      {"#{phone_key}:1h", 3_600, 5},
      {"#{phone_key}:1d", 86_400, 20},
      {"rate:phone-code:ip:1d:#{ip}", 86_400, 30}
    ]

    windows
    |> Enum.reduce_while(:ok, fn {key, window, max}, :ok ->
      case Cgc2046Web.Plugs.RateLimit.check(key, window_seconds: window, max_attempts: max) do
        :ok -> {:cont, :ok}
        :error -> {:halt, {:error, :rate_limited}}
      end
    end)
  end

  # 验码双限流（phone 5/15min，IP 20/15min）
  defp check_phone_code_verify_limits(context, phone) do
    ip = remote_ip(context)

    windows = [
      {Cgc2046Web.Plugs.RateLimit.build_key("rate:phone-code-verify:phone", phone), 900, 5},
      {"rate:phone-code-verify:ip:#{ip}", 900, 20}
    ]

    windows
    |> Enum.reduce_while(:ok, fn {key, window, max}, :ok ->
      case Cgc2046Web.Plugs.RateLimit.check(key, window_seconds: window, max_attempts: max) do
        :ok -> {:cont, :ok}
        :error -> {:halt, {:error, :rate_limited}}
      end
    end)
  end

  # 发码统一响应：SendCloud 失败外的所有分支 sent: true（防枚举）；
  # deliver 失败冒泡为 sent:false + retryAfterSeconds（plan U3.4——M4 修复：
  # 此前结果被丢弃恒 sent:true，用户看到已发送但短信不存在）。
  defp request_phone_code(phone, purpose) do
    purpose_atom = phone_code_purpose_atom(purpose)

    case Cgc2046.Accounts.PhoneVerificationCode.issue(phone, purpose_atom) do
      {:ok, code, send_request_id} ->
        case deliver_phone_code(phone, code, send_request_id) do
          :ok ->
            {:ok, %{sent: true, retry_after_seconds: 60}}

          {:error, reason} ->
            Logger.warning("[request_phone_code] sms deliver failed: #{inspect(reason)}")
            {:ok, %{sent: false, retry_after_seconds: 60}}
        end

      {:error, reason} ->
        Logger.warning("[request_phone_code] issue failed: #{inspect(reason)}")
        {:error, message: "Failed to send verification code", code: "sms_send_failed"}
    end
  end

  # Absinthe enum 内部值（"login"/"wechat_bind"）→ 资源原子
  defp phone_code_purpose_atom(:login), do: :login
  defp phone_code_purpose_atom(:wechat_bind), do: :wechat_bind
  defp phone_code_purpose_atom("login"), do: :login
  defp phone_code_purpose_atom("wechat_bind"), do: :wechat_bind

  defp deliver_phone_code(phone, code, send_request_id) do
    sms = Application.get_env(:cgc_2046, :sms_sendcloud, [])

    if Cgc2046.Sms.SendCloud.configured?() do
      template_id = Keyword.fetch!(sms, :template_id)

      Cgc2046.Sms.SendCloud.send_template_sms(
        phone,
        template_id,
        %{"code" => code},
        send_request_id
      )
    else
      # dev/test：SMS 凭证缺席，Logger 出码供本地联调（prod 启动时 raise，不可达）
      Logger.warning("[request_phone_code] SMS not configured; code for #{phone}: #{code}")
      :ok
    end
  end

  defp sign_in_with_phone_code(phone, code, context) do
    case Cgc2046.Accounts.PhoneCodeSignIn.sign_in_with_phone_code(phone, code, context) do
      {:ok, user} ->
        {:ok,
         %{
           id: user.id,
           email: user.email,
           is_platform_admin: user.is_platform_admin,
           __token__: user.__metadata__[:token]
         }}

      {:error, :invalid_or_expired_code} ->
        {:error, message: "Invalid or expired code", code: "invalid_or_expired_code"}

      {:error, reason} ->
        Logger.warning("[signInWithPhoneCode] failed: #{inspect(reason)}")
        {:error, message: "Sign in failed", code: "phone_code_sign_in_failed"}
    end
  end

  # ── 微信扫码登录（plan 002 U4）─────────────────────────────────────────

  defp check_wechat_login_start_limits(context) do
    check_single_limit("rate:wechat-login-start:ip:#{remote_ip(context)}", 900, 20)
  end

  defp check_wechat_callback_limits(context) do
    check_single_limit("rate:wechat-callback:ip:#{remote_ip(context)}", 900, 20)
  end

  defp check_wechat_bind_limits(_context, phone) do
    check_single_limit(
      Cgc2046Web.Plugs.RateLimit.build_key("rate:wechat-bind:phone", phone),
      900,
      5
    )
  end

  defp check_single_limit(key, window, max) do
    case Cgc2046Web.Plugs.RateLimit.check(key, window_seconds: window, max_attempts: max) do
      :ok -> :ok
      :error -> {:error, :rate_limited}
    end
  end

  defp start_wechat_login(next) do
    # next 由 state 无关的 URL 参数透传(plan 002):嵌入 redirect_uri,微信回调原样带回;
    # 开放跳转防护在 callback 页 resolveNextTarget 同源校验,此处仅透传。
    base = Application.fetch_env!(:cgc_2046, :web_base_url) <> "/login/wechat-callback"

    redirect_uri =
      case next do
        value when is_binary(value) and value != "" ->
          # 不预编码:qr_connect_url 的 encode_query 对整个 redirect_uri 统一编码一次
          base <> "?next=" <> value

        _ ->
          base
      end

    case Cgc2046.Accounts.WechatLoginTicket.issue() do
      {:ok, %{state: state, expires_at: expires_at}} ->
        case Cgc2046.OAuth.WechatWeb.qr_connect_url(redirect_uri, state) do
          url when is_binary(url) ->
            expires_in = max(DateTime.diff(expires_at, DateTime.utc_now()), 0)
            {:ok, %{qr_url: url, state: state, expires_in_seconds: expires_in}}

          {:error, _reason} ->
            {:error, message: "WeChat login is unavailable", code: "wechat_login_unavailable"}
        end

      {:error, _reason} ->
        {:error, message: "WeChat login is unavailable", code: "wechat_login_unavailable"}
    end
  end

  defp check_password_reset_request_limits(context, email) do
    email_key = Cgc2046Web.Plugs.RateLimit.build_key("rate:password-reset:email", email)

    ip_key =
      Cgc2046Web.Plugs.RateLimit.build_key(
        "rate:password-reset:ip",
        remote_ip(context)
      )

    with :ok <-
           Cgc2046Web.Plugs.RateLimit.check(
             email_key,
             window_seconds: 3_600
           ),
         :ok <-
           Cgc2046Web.Plugs.RateLimit.check(
             ip_key,
             window_seconds: 3_600,
             max_attempts: 20
           ) do
      :ok
    end
  end

  # signIn 限流 key 归一化（plan 002 U2）：email → downcase（与 normalize_email 同）；
  # 手机号 → PhoneNumber 规范形（"138…" 与 "+86138…" 同 key，防换写法绕过限流）；
  # 非法输入原样保留（保持与认证失败路径一致的计数语义）。
  defp normalize_login(login) do
    login = to_string(login)

    if String.contains?(login, "@") do
      String.downcase(String.trim(login))
    else
      case Cgc2046.Accounts.PhoneNumber.normalize(login) do
        {:ok, phone} -> phone
        {:error, :invalid} -> login
      end
    end
  end

  defp remote_ip(%{conn: %{remote_ip: ip}}), do: ip |> :inet.ntoa() |> to_string()
  defp remote_ip(_context), do: "unknown"

  @doc false
  def password_reset_failure_telemetry(reason) do
    if revoke_failure?(reason) do
      {[:cgc2046, :password_reset, :revoke], :revoke_failed}
    else
      {[:cgc2046, :password_reset, :reset], :reset_failed}
    end
  end

  defp revoke_failure?(%Cgc2046.Accounts.PasswordResetRevocationError{}), do: true

  defp revoke_failure?(%{errors: errors}) when is_list(errors) do
    Enum.any?(errors, &revoke_failure?/1)
  end

  defp revoke_failure?(%{value: value}), do: revoke_failure?(value)
  defp revoke_failure?(%{error: error}), do: revoke_failure?(error)
  defp revoke_failure?(%{reason: reason}), do: revoke_failure?(reason)

  defp revoke_failure?(list) when is_list(list) do
    Enum.any?(list, &revoke_failure?/1)
  end

  defp revoke_failure?(_reason), do: false

  defp classify_password_reset_error(error, _context)
       when is_struct(error, AshAuthentication.Errors.InvalidToken) do
    {:error, message: "链接无效或已过期", code: "invalid_reset_token"}
  end

  defp classify_password_reset_error(%Ash.Error.Invalid{} = error, context) do
    {:error, to_ash_graphql_errors(error, context, :password_reset_with_password)}
  end

  defp classify_password_reset_error(error, _context), do: report_password_reset_failure(error)

  defp report_password_reset_failure(reason) do
    {telemetry_event, reason_category} = password_reset_failure_telemetry(reason)

    Logger.warning("password reset failed reason=#{reason_category}")

    :telemetry.execute(
      telemetry_event,
      %{count: 1},
      %{reason: reason_category, email: nil}
    )

    {:error, message: "密码重置失败，请稍后重试", code: "password_reset_failed"}
  end

  # Ash action 错误 → AshGraphql.Error 结构化顶层 error（message/code/fields）。
  # 复用 AshGraphql.Errors.to_errors（自动生成 mutation 同款映射），与 sign_up 的
  # 错误协议一致；只取最小形状字段，避免 vars/short_message 等内部字段进响应。
  # domain 默认 GlobalApi（历史调用方均属此域）；其它域的资源（如 Cgc2046.Mcp.Token）须显式传入。
  defp to_ash_graphql_errors(
         error,
         context,
         action,
         resource \\ Cgc2046.Accounts.User,
         domain \\ Cgc2046.GlobalApi
       ) do
    error
    |> AshGraphql.Errors.to_errors(context, domain, resource, action)
    |> Enum.map(&Map.take(&1, [:message, :code, :fields]))
  end

  # #86 防邮箱枚举：sign_up 的 unique_email 冲突识别。ash_postgres 把
  # users_unique_email_index（identity :unique_email）的 PG unique violation 转成
  # Ash.Error.Invalid{errors: [InvalidAttribute{field: :email, private_vars: [constraint_type: :unique]}]}。
  # 判法同 MembershipContext.unique_membership_conflict?/1（constraint_type 区分
  # 「唯一冲突」与「DB 故障」），此处再限定 field: :email——仅抹平「该邮箱已存在」
  # 这一可枚举信号，格式/密码等校验错误不受影响。
  defp unique_email_conflict?(%Ash.Error.Invalid{errors: errors}) do
    Enum.any?(errors, fn
      %Ash.Error.Changes.InvalidAttribute{field: :email, private_vars: private_vars} ->
        Keyword.get(private_vars || [], :constraint_type) == :unique

      _ ->
        false
    end)
  end

  # sign_up 通用失败 payload：重复邮箱（unique 冲突）、未知错误、rescue 三处同形
  # ——result nil + errors[{message generic, code: "registration_failed"}]，无 fields，
  # 使「邮箱已存在」与其它注册失败不可区分。
  defp registration_failed_payload do
    %{
      result: nil,
      errors: [
        %{
          message: "Registration failed. Please check your input and try again.",
          code: "registration_failed"
        }
      ],
      __token__: nil
    }
  end

  # SpeakerInvitation 决策（accept/decline）：token 即凭据——按 token_hash 定位邀请
  # （read policy 不适用：token 持有者非成员），action 内复验 token 有效/未过期/未使用
  # （统一错误，不防枚举）。无效 token 与已用/过期同形返回 payload errors。
  defp decide_speaker_invitation(%{context: context}, token, action) do
    with %{actor: actor} when not is_nil(actor) <- context,
         {:ok, invitation} <-
           token_credential_fetch(Cgc2046.Events.SpeakerInvitation, token) do
      invitation
      |> Ash.Changeset.for_update(action, %{token: token},
        actor: actor,
        tenant: invitation.workspace_id
      )
      |> Ash.update(tenant: invitation.workspace_id, actor: actor)
      |> speaker_invitation_action_result(context, action)
    else
      %{} ->
        {:error, unauthorized_error()}

      _ ->
        {:ok,
         %{
           result: nil,
           errors: [
             %{
               message: "invitation token is invalid, expired or already used",
               code: "invalid_token"
             }
           ]
         }}
    end
  end

  # 持 token 资源定位组合子（PR-E D4）：token 即凭据——sha256(hex lower) 哈希 →
  # token_hash 精确匹配 → read_one(authorize?: false)（不走 read policy）。
  # token 空/非 binary 或未命中任何记录 → {:error, :invalid_token}（nil 塌缩，不泄露
  # 存在性）；真实读错误原样上抛（流① accept_invitation 需区分 invalid_token 与
  # real error）。extra_filter 追加双因子（accept_invitation 的 [id: id]）。
  # 消费方：accept_invitation（流①）/ decide_speaker_invitation（流②）。
  defp token_credential_fetch(resource, token, extra_filter \\ :none) do
    with {:ok, hash} <- credential_hash(token) do
      filters = if extra_filter == :none, do: [], else: extra_filter

      resource
      |> Ash.Query.do_filter(filters ++ [token_hash: hash])
      |> Ash.read_one(authorize?: false)
      |> case do
        {:ok, nil} -> {:error, :invalid_token}
        result -> result
      end
    end
  end

  defp credential_hash(token) when is_binary(token) and token != "" do
    {:ok, :crypto.hash(:sha256, token) |> Base.encode16(case: :lower)}
  end

  defp credential_hash(_), do: {:error, :invalid_token}

  # SpeakerInvitation action 结果 → payload（result + errors 两段式，同 sign_up 错误协议）
  defp speaker_invitation_action_result({:ok, invitation}, _context, _action) do
    {:ok, %{result: invitation, errors: []}}
  end

  defp speaker_invitation_action_result({:error, error}, context, action) do
    {:ok,
     %{
       result: nil,
       errors:
         to_ash_graphql_errors(
           error,
           context,
           action,
           Cgc2046.Events.SpeakerInvitation,
           Cgc2046.Api
         )
     }}
  end

  # acceptInvitation 的 not_found：id+token 双因子不匹配时返回，与 AshGraphql 自动 mutation
  # 的 NotFound 映射一致（message "could not be found" / code "not_found"），复用同一序列化路径。
  defp accept_not_found_errors(context, id) do
    error =
      Ash.Error.Query.NotFound.exception(
        primary_key: %{id: id},
        resource: Cgc2046.Accounts.Invitation
      )

    to_ash_graphql_errors(error, context, :accept, Cgc2046.Accounts.Invitation)
  end

  # 把 Absinthe input map 转为 Ash attrs map（只取指定字段，忽略缺省）。
  # map_input(input, keys)：keys 内存在才放进去；
  # map_input(input)：全量取（用于 update_workspace_profile_input 的全部可选字段）。
  defp map_input(input, keys) do
    Enum.reduce(keys, %{}, fn key, acc ->
      case input do
        %{^key => value} -> Map.put(acc, key, value)
        _ -> acc
      end
    end)
  end

  defp map_input(input) do
    map_input(input, [:avatar_url, :location, :about, :skills, :visibility])
  end

  # 统一的个人资料加载：member_number/joined_at 为计算属性，获取与更新后均需显式加载。
  # 加载失败（罕见：calculation/DB 异常）经 to_ash_graphql_errors 映射，与
  # update_profile/set_ui_theme 同源——避免把 Ash 内部 stacktrace 当 string 返给客户端。
  # `action` 用于错误路径解析（与出错 mutation 的 action 对齐，nil 表示 query 侧 me）。
  defp load_profile(user, actor, context, action) do
    case Ash.load(user, [:member_number, :joined_at],
           actor: actor,
           domain: Cgc2046.GlobalApi
         ) do
      {:ok, loaded} ->
        {:ok, loaded}

      {:error, error} ->
        {:error, to_ash_graphql_errors(error, context, action)}
    end
  end

  # owner 域 read-first update 组合子（PR-E D5）：filter(user_id == ^actor.id) +
  # read_one(tenant:, actor:) → {:ok, nil} 分支错误单点（workspace_profile_not_found）
  # → for_update(action, attrs) → Ash.update(tenant:, actor:)。错误路径经
  # to_ash_graphql_errors 显式透传 resource（message/code/fields 逐字保留）。
  # 消费方：update_workspace_profile(:update_profile, map_input 全量) /
  # set_workspace_theme(:set_ui_theme, 单字段)。
  defp scoped_update(actor, resource, tenant_id, action, attrs, context) do
    case resource
         |> Ash.Query.for_read(:read)
         |> Ash.Query.filter(user_id == ^actor.id)
         |> Ash.read_one(tenant: tenant_id, actor: actor) do
      {:ok, nil} ->
        {:error,
         message: "Workspace profile not found or not accessible",
         code: "workspace_profile_not_found"}

      {:ok, profile} ->
        profile
        |> Ash.Changeset.for_update(action, attrs)
        |> Ash.update(tenant: tenant_id, actor: actor)

      {:error, error} ->
        {:error, to_ash_graphql_errors(error, context, action, resource)}
    end
  end

  # 服务端撤销当前 token：往 tokens 表对当前 jti 做 upsert，把 purpose 从 "user"
  # 覆盖成 "revocation"，下次 load_from_bearer 的 get_token 查不到 user 记录即认证失败。
  # token 由 AuthTokenContextPlug 从 Authorization header 透传进 Absinthe context。
  # 撤销失败不阻断登出：仍清 cookie 让用户侧登出成功，token 会在 7 天自然过期。
  defp revoke_bearer_token(context) do
    case context[:cgc_bearer_token] do
      token when is_binary(token) and byte_size(token) > 0 ->
        case AshAuthentication.TokenResource.Actions.revoke(Cgc2046.Accounts.Token, token, []) do
          :ok ->
            :ok

          {:error, reason} ->
            Logger.warning("signOut token revoke failed: #{inspect(reason)}")
        end

      _ ->
        :ok
    end
  end

  # ── Platform Admin Dashboard Phase 5：类型（前缀 admin_ 避免与自动类型冲突）──

  object :admin_user do
    field(:id, non_null(:id))
    field(:email, :string)
    field(:display_name, :string)
    field(:is_platform_admin, non_null(:boolean))
    field(:inserted_at, non_null(:datetime))
    # membership 概要（R8）：用户参与的工作台数
    field(:workspace_membership_count, :integer)
  end

  object :admin_workspace do
    field(:id, non_null(:id))
    field(:slug, non_null(:string))
    field(:name, non_null(:string))
    field(:join_policy, non_null(:string))
    field(:sponsorship_enabled, non_null(:boolean))
    field(:inserted_at, non_null(:datetime))
    field(:member_count, non_null(:integer))
  end

  object :admin_workspace_application do
    field(:id, non_null(:id))
    field(:applicant_id, non_null(:id))
    field(:name, non_null(:string))
    field(:slug, non_null(:string))
    field(:purpose, non_null(:string))
    field(:status, non_null(:string))
    field(:rejection_reason, :string)
    # #116 R10a：处理人/时间（approve/reject 对称四字段；pending/expired 为 null）
    field(:approved_by, :id)
    field(:approved_at, :datetime)
    field(:rejected_by, :id)
    field(:rejected_at, :datetime)
    field(:inserted_at, non_null(:datetime))
  end

  object :admin_tool_call_log do
    field(:id, non_null(:id))
    field(:user_id, non_null(:id))
    field(:tool, non_null(:string))
    field(:result_status, non_null(:string))
    field(:error_message, :string)
    field(:latency_ms, :integer)
    field(:inserted_at, non_null(:datetime))
  end

  object :admin_pending_operation do
    field(:id, non_null(:id))
    field(:user_id, non_null(:id))
    field(:tool, non_null(:string))
    field(:summary, non_null(:string))
    field(:status, non_null(:string))
    field(:inserted_at, non_null(:datetime))
  end

  object :admin_signal_log do
    field(:id, non_null(:id))
    field(:workspace_id, non_null(:id))
    field(:signal_type, non_null(:string))
    field(:inserted_at, non_null(:datetime))
  end

  # U7(#180/R10):公开课程地图。可见性硬编码 open+public(resolver 显式判定,
  # 匿名面);成员视角走管理页/工作台课程列表,不经本查询;其余 → {:ok, nil}。
  # goal-only 投影(object :course_map_issue 无 checklist 字段)。
  defp resolve_course_map(slug) do
    case Cgc2046.Events.Course
         |> Ash.Query.for_read(:get_by_slug, %{slug: slug})
         |> Ash.read_one(authorize?: false) do
      {:ok, %{} = course} ->
        if course.status == :open and course.visibility == :public do
          {:ok, build_course_map(course)}
        else
          {:ok, nil}
        end

      _ ->
        {:ok, nil}
    end
  end

  defp build_course_map(course) do
    content = Cgc2046.Events.Course.course_content(course)

    %{
      course_id: course.id,
      title: course.title,
      slug: course.slug,
      goals: content["goals"] || [],
      issues: Cgc2046.Events.Course.issue_map_rows(course)
    }
  end

  # #116 R10a：治理操作留痕（actor_id 可空 = 系统/CLI；metadata v1 不暴露，落 DB 备用）
  object :admin_action_log do
    field(:id, non_null(:id))
    field(:actor_id, :id)
    field(:action, non_null(:string))
    field(:target_type, non_null(:string))
    field(:target_id, non_null(:id))
    field(:result, non_null(:string))
    field(:inserted_at, non_null(:datetime))
  end

  # E-10 #125：对账扫描发现（rule/entity_type 为 atom 枚举的字符串形态；detail
  # v1 不暴露——对账页列只到 规则/实体/ID/workspace/首次/最近发现）
  object :admin_reconciliation_finding do
    field(:id, non_null(:id))
    field(:rule, non_null(:string))
    field(:entity_type, non_null(:string))
    field(:entity_id, non_null(:string))
    field(:workspace_id, :id)
    field(:first_seen_at, non_null(:datetime))
    field(:last_seen_at, non_null(:datetime))
    field(:inserted_at, non_null(:datetime))
  end

  # U7(#180/R11):学员视角课程学习详情(抽屉数据)。恒 actor——授权 = 学员侧
  # 三层(成员 ∪ confirmed enrollment ∪ 记忆持有者,LearnerAuthorization 同源);
  # 无他人视角可构造(查询无 user_id 参数)。无权限/无课程 → {:ok, nil}
  # (404 语义,不泄露存在性)。
  defp resolve_course_learning_detail(actor, course_id) do
    with %{} = course <-
           fetch_course_for_detail(course_id),
         :ok <-
           Cgc2046.Mcp.Tools.LearnerAuthorization.authorize(
             actor,
             course.workspace_id,
             course.id
           ) do
      content = Cgc2046.Events.Course.course_content(course)
      records = fetch_actor_records(course, actor)
      {:ok, build_course_learning_detail(course, content, records)}
    else
      _ -> {:ok, nil}
    end
  end

  defp fetch_course_for_detail(course_id) do
    Cgc2046.Events.Course
    |> Ash.Query.for_read(:get_by_id, %{id: course_id})
    |> Ash.read_one(authorize?: false)
    |> case do
      {:ok, %{} = course} -> course
      _ -> nil
    end
  end

  defp fetch_actor_records(course, actor) do
    Cgc2046.Learning.LearningRecord
    |> Ash.Query.filter(course_id == ^course.id and user_id == ^actor.id)
    |> Ash.read!(authorize?: false, tenant: course.workspace_id)
  end

  # 抽屉形状:course 元信息 + goals + issues(story 全文 + checklist 逐条与
  # 本人记录合成:done/evidence/recorded_at)+ 汇总 progress(同 myLearningRuns
  # 投影单源 LearningProgress)。
  defp build_course_learning_detail(course, content, records) do
    issues = Cgc2046.Workflows.CourseContent.issues(content)
    done_items = done_record_index(records)

    learning_issues =
      issues
      |> Enum.with_index(1)
      |> Enum.map(fn {issue, idx} ->
        checklist_items = Cgc2046.Workflows.CourseContent.checklist_item_ids(issue)

        done_count =
          Enum.count(checklist_items, &Map.has_key?(done_items, {issue["id"], &1}))

        status =
          cond do
            checklist_items != [] and done_count == length(checklist_items) -> "done"
            done_count > 0 -> "in_progress"
            true -> "todo"
          end

        %{
          key: Cgc2046.Workflows.LearningProgress.issue_key(course.slug, idx),
          id: issue["id"],
          title: issue["title"],
          kind: issue["kind"],
          status: status,
          story: issue_story(issue, done_items)
        }
      end)

    progress = Cgc2046.Workflows.LearningProgress.project_issues(content, records)

    current_issue_key =
      with issue_id when is_binary(issue_id) <- progress.current_issue_id,
           idx when is_integer(idx) <-
             Enum.find_index(issues, &(&1["id"] == progress.current_issue_id)) do
        Cgc2046.Workflows.LearningProgress.issue_key(course.slug, idx + 1)
      else
        _ -> nil
      end

    %{
      course_id: course.id,
      title: course.title,
      slug: course.slug,
      goals: content["goals"] || [],
      issues: learning_issues,
      progress: Map.put(progress, :current_issue_key, current_issue_key)
    }
  end

  # (issue_id, item_id) → done record 索引(仅 done 行;三态与 checklist 合成单源)
  defp done_record_index(records) do
    records
    |> Enum.filter(& &1.done)
    |> Map.new(fn record -> {{record.issue_id, record.item_id}, record} end)
  end

  defp issue_story(issue, done_index) do
    story = issue["story"] || %{}

    checklist =
      (story["checklist"] || [])
      |> Enum.map(fn item ->
        record = Map.get(done_index, {issue["id"], item["id"]})

        %{
          id: item["id"],
          text: item["text"],
          done: not is_nil(record),
          evidence: record && record.evidence,
          recorded_at: record && record.recorded_at
        }
      end)

    %{
      as_a: story["as_a"],
      given: List.wrap(story["given"]),
      goal: story["goal"],
      materials: List.wrap(story["materials"]),
      checklist: checklist
    }
  end

  # plan 020 U2.1：本人 MCP 工具调用活动流。
  # policy（显式判定，与 Wrapper 成员门槛同源）：workspace 成员 + 仅本人。
  # 过滤：params JSONB 内 workspace_id（键名 params["workspace_id"]，Wrapper 落库
  # 格式，assumption 1）+ user_id == actor.id；排序 inserted_at desc + id desc。
  # 非成员统一 forbidden；读取经 authorize?: false 直读（ToolCallLog 读 policy 仍
  # platform_admin 专属，本查询按成员+本人独立门控，params 摘要级不返回）。
  defp resolve_my_workspace_tool_calls(actor, workspace_id, first) do
    if Cgc2046.Accounts.MembershipContext.membership_of(actor, workspace_id) do
      ws_id = to_string(workspace_id)

      query =
        Cgc2046.Mcp.ToolCallLog
        |> Ash.Query.filter(user_id == ^actor.id)
        |> Ash.Query.filter(fragment("params->>'workspace_id' = ?", ^ws_id))
        |> Ash.Query.sort(inserted_at: :desc, id: :desc)
        |> Ash.Query.limit(first)

      case Ash.read(query, authorize?: false) do
        {:ok, logs} ->
          {:ok,
           Enum.map(logs, fn log ->
             %{
               id: log.id,
               tool: log.tool,
               status: to_string(log.result_status),
               latency_ms: log.latency_ms,
               inserted_at: log.inserted_at,
               error_message: log.error_message
             }
           end)}

        {:error, error} ->
          {:error, to_ash_graphql_errors(error, %{}, :read, Cgc2046.Mcp.ToolCallLog, Cgc2046.Mcp)}
      end
    else
      {:error, [message: "forbidden", code: "forbidden"]}
    end
  end

  defp resolve_my_learning_runs(actor) do
    case read_confirmed_enrollments(actor) do
      {:ok, enrollments} ->
        rows =
          Enum.flat_map(enrollments, fn enrollment ->
            enrollment
            |> read_learning_runs()
            |> Enum.map(&project_learning_run(&1, enrollment, actor))
            |> Enum.reject(&is_nil/1)
          end)

        {:ok, rows}

      {:error, _reason} ->
        {:ok, []}
    end
  end

  defp read_confirmed_enrollments(actor) do
    Cgc2046.Events.Enrollment
    |> Ash.Query.for_read(:my_enrollments, %{}, actor: actor)
    |> Ash.Query.filter(status == :confirmed)
    |> Ash.Query.load(:target_title)
    |> Ash.Query.limit(250)
    |> Ash.read(actor: actor)
    |> case do
      {:ok, %{results: results}} -> {:ok, results}
      {:ok, results} when is_list(results) -> {:ok, results}
      {:error, reason} -> {:error, reason}
    end
  end

  defp read_learning_runs(enrollment) do
    Cgc2046.Workflows.WorkflowRun
    |> Ash.Query.filter(input_snapshot["enrollment_id"] == ^enrollment.id)
    |> Ash.read(tenant: enrollment.workspace_id, authorize?: false)
    |> case do
      {:ok, runs} ->
        Enum.flat_map(runs, fn run ->
          if run.workspace_id != enrollment.workspace_id do
            []
          else
            case Ash.load(
                   run,
                   [definition: [:type, :node_def, steps: [:step_key, :title]]],
                   tenant: run.workspace_id,
                   authorize?: false
                 ) do
              {:ok, loaded_run} -> [loaded_run]
              {:error, _reason} -> []
            end
          end
        end)

      {:error, _reason} ->
        []
    end
  end

  defp project_learning_run(run, enrollment, actor) do
    definition = Map.get(run, :definition)

    cond do
      enrollment.user_id != actor.id ->
        nil

      not anchored_to_enrollment?(run, enrollment) ->
        nil

      run.workspace_id != enrollment.workspace_id ->
        nil

      not learning_definition?(definition) ->
        nil

      true ->
        target_title =
          if is_binary(enrollment.target_title), do: enrollment.target_title, else: nil

        # U7(#180):issue 级权威投影(course content + learning_records);
        # manual_steps_compat/旧字段派生已删(KD8),issue key 展示层派生(KTD6)
        {content, records, course} = learning_projection_sources(run, enrollment)

        Cgc2046.Workflows.LearningProgress.project(
          run.id,
          enrollment.id,
          target_title,
          run.status,
          content,
          records
        )
        |> Map.put(:course_id, enrollment.course_id)
        |> Map.put(:current_issue_key, current_issue_key(course, content, records))
    end
  end

  # U7:内容/记录/课程按 (course, user) 组装(无内容课程 → nil → 投影 0/n)。
  # course 供 issue key 派生(slug 短码);一次往返,抽屉数据同源。
  defp learning_projection_sources(run, enrollment) do
    course_id = enrollment.course_id

    if is_binary(course_id) do
      content =
        Cgc2046.Workflows.ResearchOutput
        |> Ash.Query.filter(
          key == ^Cgc2046.Workflows.ResearchOutput.course_key(course_id) and kind == :issues
        )
        |> Ash.Query.limit(1)
        |> Ash.read_one(authorize?: false, tenant: run.workspace_id)
        |> case do
          {:ok, output} -> output && output.data
          _ -> nil
        end

      records =
        if is_binary(enrollment.user_id) do
          Cgc2046.Learning.LearningRecord
          |> Ash.Query.filter(course_id == ^course_id and user_id == ^enrollment.user_id)
          |> Ash.read!(authorize?: false, tenant: run.workspace_id)
        else
          []
        end

      course =
        Cgc2046.Events.Course
        |> Ash.Query.for_read(:get_by_id, %{id: course_id})
        |> Ash.read_one(authorize?: false, tenant: run.workspace_id)
        |> case do
          {:ok, nil} -> nil
          {:ok, course} -> course
          _ -> nil
        end

      {content, records, course}
    else
      {nil, [], nil}
    end
  end

  # issue key 展示层派生(KTD6):当前 issue 在卡集中的 1 起序号 + 课程 slug 短码。
  # current_issue_id 由 records 视角派生(全 Done → nil → key nil)
  defp current_issue_key(course, content, records) do
    issues = Cgc2046.Workflows.CourseContent.issues(content)

    with %{current_issue_id: issue_id} when is_binary(issue_id) <-
           Cgc2046.Workflows.LearningProgress.project_issues(content, records),
         idx when is_integer(idx) <- Enum.find_index(issues, &(&1["id"] == issue_id)) do
      Cgc2046.Workflows.LearningProgress.issue_key(course && course.slug, idx + 1)
    else
      _ -> nil
    end
  end

  defp anchored_to_enrollment?(%{input_snapshot: input}, %{id: enrollment_id})
       when is_map(input) do
    Map.get(input, "enrollment_id") == enrollment_id or
      Map.get(input, :enrollment_id) == enrollment_id
  end

  defp anchored_to_enrollment?(_run, _enrollment), do: false

  defp learning_definition?(%{type: type}) when type in [:learning, "learning"], do: true
  defp learning_definition?(_definition), do: false

  # id / is_platform_admin 可空：update 失败时承载错误 payload（errors 非空、业务字段为 nil），
  # 与 admin 面其它 mutation 的 payload 式错误通道一致。
  object :admin_user_payload do
    field(:id, :id)
    field(:email, :string)
    field(:is_platform_admin, :boolean)
    field(:errors, list_of(:mutation_error))
  end

  # ── Platform Admin Dashboard Phase 5：resolver helpers ─────────────────

  # actor 门控组合子（PR-E）：nil → unauthorized_error()（on_nil 可覆盖——唯一消费方
  # me 的 auth_uncertain 分支），ok → fun.(actor)。19 处 case context[:actor] 标准门
  # 收敛于此，错误契约单点（未登录统一 unauthorized message/code）。
  defp with_actor(context, fun, opts \\ []) do
    on_nil = Keyword.get(opts, :on_nil, fn _context -> {:error, unauthorized_error()} end)

    case context[:actor] do
      nil -> on_nil.(context)
      actor -> fun.(actor)
    end
  end

  # admin 门控：非 platform_admin → forbidden（与 Phase 1 PlatformAdminPlug 同语义）。
  # 未登录 → unauthorized。通过后执行 fun(actor)。
  defp with_admin(context, fun) do
    actor = context[:actor]

    cond do
      Cgc2046.Policies.PlatformAdmin.platform_admin?(actor) ->
        fun.(actor)

      is_nil(actor) ->
        {:error, unauthorized_error()}

      true ->
        {:error, [message: "forbidden", code: "forbidden"]}
    end
  end

  # admin 列表 resolver 工厂：with_admin 门控 → for_read → filter → pre_read →
  # paginate → read → post_read。一处接线顺序，N 个 query 声明式复用（leverage）；
  # gate/filter/paginate 顺序只在此验证（locality）。
  # my_workspace_applications 不用此构造器：gate 是 applicant 非 platform_admin，形状不同。
  defp admin_list(resource, filter_fn, post_fn, opts \\ []) do
    pre_read = Keyword.get(opts, :pre_read, fn q -> q end)

    fn _, args, %{context: context} ->
      with_admin(context, fn actor ->
        resource
        |> Ash.Query.for_read(:read)
        |> filter_fn.(args)
        |> pre_read.()
        |> paginate(args[:first], args[:after])
        |> Ash.read(actor: actor)
        |> post_fn.(context)
      end)
    end
  end

  # admin 列表 read 结果 → map_error（统一 :read action；resource/domain 按 query 闭包）
  defp admin_result(resource, domain) do
    fn result, context -> map_error(result, context, :read, resource, domain) end
  end

  # search 模糊过滤（字段静态，search 运行时值经 ^ pin 注入）：
  # - maybe_user_search：email（ci_string）/ display_name contains OR
  # - maybe_workspace_search：name / slug contains OR
  defp maybe_user_search(query, nil), do: query
  defp maybe_user_search(query, ""), do: query

  defp maybe_user_search(query, search) do
    Ash.Query.filter(
      query,
      contains(email, ^search) or contains(display_name, ^search)
    )
  end

  defp maybe_workspace_search(query, nil), do: query
  defp maybe_workspace_search(query, ""), do: query

  defp maybe_workspace_search(query, search) do
    Ash.Query.filter(query, contains(name, ^search) or contains(slug, ^search))
  end

  # status 过滤（atom 约束字段；非枚举值静默忽略过滤——to_existing_atom 防 atom 表污染）。
  # field 参数化：WorkspaceApplication/PendingOperation 是 :status，ToolCallLog 是 :result_status。
  defp maybe_status_filter(query, status, field \\ :status)

  defp maybe_status_filter(query, nil, _field), do: query

  defp maybe_status_filter(query, status, field) do
    case String.to_existing_atom(status) do
      # keyword 整体 ^ pin：字段名运行时化（宏模板内未 pin 变量会被当字段引用）
      atom -> Ash.Query.filter(query, ^[{field, atom}])
    end
  rescue
    ArgumentError -> query
  end

  # #117 PendingOperation 状态过滤：expired 不落库（读时派生 calculation，不能下推 SQL），
  # 特判为 status == :pending and expires_at < now（与 effective_status 同语义）；
  # 其余枚举值走通用 maybe_status_filter。
  defp maybe_pending_status_filter(query, nil), do: query

  defp maybe_pending_status_filter(query, "expired") do
    now = DateTime.utc_now()
    Ash.Query.filter(query, status == :pending and expires_at < ^now)
  end

  defp maybe_pending_status_filter(query, status), do: maybe_status_filter(query, status)

  # #117 SignalLog 信号类型过滤（自由 string 精确匹配，如 "workflow.approval"；空串忽略）
  defp maybe_signal_type_filter(query, nil), do: query
  defp maybe_signal_type_filter(query, ""), do: query

  defp maybe_signal_type_filter(query, signal_type) do
    Ash.Query.filter(query, signal_type == ^signal_type)
  end

  # #117 时间范围过滤（inserted_at）：inserted_after → >=，inserted_before → <=。
  # Absinthe :datetime 标量已把 ISO8601 解析为 DateTime；nil 分支不过滤。
  defp maybe_time_range_filter(query, args) do
    query
    |> maybe_inserted_after(args[:inserted_after])
    |> maybe_inserted_before(args[:inserted_before])
  end

  defp maybe_inserted_after(query, nil), do: query

  defp maybe_inserted_after(query, dt) do
    Ash.Query.filter(query, inserted_at >= ^dt)
  end

  defp maybe_inserted_before(query, nil), do: query

  defp maybe_inserted_before(query, dt) do
    Ash.Query.filter(query, inserted_at <= ^dt)
  end

  # #116 action 过滤（AdminActionLog.action 是 atom 约束；非枚举值静默忽略过滤，
  # 与 maybe_status_filter 的 rescue 回退一致——to_existing_atom 防 atom 表污染）
  defp maybe_action_filter(query, nil), do: query

  defp maybe_action_filter(query, action) do
    case String.to_existing_atom(action) do
      atom -> Ash.Query.filter(query, action == ^atom)
    end
  rescue
    ArgumentError -> query
  end

  # D5：ToolCallLog / PendingOperation 的 workspace_id 在 params JSONB 内
  defp maybe_workspace_filter(query, nil), do: query

  defp maybe_workspace_filter(query, workspace_id) do
    # params->>'workspace_id' 是 JSONB text 提取，与 uuid 字符串比较。
    # 不显式调 expr/1（非宏函数无法处理 ^ pin）——filter/2 宏的 expression
    # 分支内部 require Ash.Expr 并解析 pin，故直接传 fragment 表达式。
    ws_id = to_string(workspace_id)
    Ash.Query.filter(query, fragment("params->>'workspace_id' = ?", ^ws_id))
  end

  # B1（advisor02）：SignalLog / WorkflowRun 有真实 workspace_id 列（非 params JSONB），
  # 用真实列过滤（区别于 maybe_workspace_filter 的 JSONB 版本）。
  defp maybe_real_workspace_filter(query, nil), do: query

  defp maybe_real_workspace_filter(query, workspace_id) do
    Ash.Query.filter(query, workspace_id == ^workspace_id)
  end

  # 分页：first 限条数（默认 50），after 为上一页已返回的条数（offset）。
  # offset 分页对 admin 内部列表足够（数据量有限），避免手写 keyset cursor
  # 的 datetime 解析复杂度；排序按 inserted_at+id 稳定。
  defp paginate(query, first, after_offset) do
    query
    |> Ash.Query.sort(inserted_at: :desc, id: :desc)
    |> Ash.Query.limit(first || 50)
    |> maybe_offset(after_offset)
  end

  defp maybe_offset(query, nil), do: query

  # B2（advisor02）：GraphQL arg(:after, :string) 声明为 string，Ash.Query.offset
  # 期望 integer——这里显式转换；非法值（非数字）rescue 回退 0（忽略分页偏移）。
  defp maybe_offset(query, offset) when is_integer(offset), do: Ash.Query.offset(query, offset)

  defp maybe_offset(query, offset) when is_binary(offset) do
    case Integer.parse(offset) do
      {n, ""} when n >= 0 -> Ash.Query.offset(query, n)
      _ -> query
    end
  end

  # Ash.read 结果 → Absinthe 结果（错误统一走 to_ash_graphql_errors）
  defp map_error(result, context, action, resource, domain) do
    case result do
      {:ok, records} -> {:ok, records}
      {:error, error} -> {:error, to_ash_graphql_errors(error, context, action, resource, domain)}
    end
  end

  # listUsers 的 membership 概要（R8）：count aggregate 子查询会被
  # WorkspaceMembership read policy 过滤（BypassReads 已知问题），
  # 故对结果集批量 load 关系后计数（admin 列表量小，可接受）。
  defp load_membership_counts({:ok, users}, _context) do
    case Ash.load(users, :workspace_memberships, authorize?: false) do
      {:ok, loaded} ->
        result =
          Enum.map(loaded, fn user ->
            %{
              id: user.id,
              email: user.email,
              display_name: user.display_name,
              is_platform_admin: user.is_platform_admin,
              inserted_at: user.inserted_at,
              workspace_membership_count: length(user.workspace_memberships || [])
            }
          end)

        {:ok, result}

      {:error, error} ->
        {:error, to_ash_graphql_errors(error, nil, :read, Cgc2046.Accounts.User)}
    end
  end

  defp load_membership_counts({:error, error}, context) do
    {:error, to_ash_graphql_errors(error, context, :read, Cgc2046.Accounts.User)}
  end

  # 更新 user 的 result → payload（result + errors）
  defp map_update_result({:ok, user}, _context, _action) do
    {:ok,
     %{
       id: user.id,
       email: user.email,
       is_platform_admin: user.is_platform_admin,
       errors: []
     }}
  end

  defp map_update_result({:error, error}, context, action) do
    {:ok,
     %{
       id: nil,
       email: nil,
       is_platform_admin: nil,
       errors: to_ash_graphql_errors(error, context, action, Cgc2046.Accounts.User)
     }}
  end

  defp resolve_readiness(id, actor) do
    with {:ok, entity} <- fetch_offering_by_id(id, actor) do
      {:ok, Cgc2046.Events.Readiness.evaluate(entity)}
    end
  end

  # offeringReadiness 目标可能是 Event 或 Course（原 event 优先、失败回退 course）。
  # 读取唯一真源 = Offering；**必须显式 authorize?: true**（D2 风险：Offering 默认
  # authorize?: false 会绕过 read policy，actor 感知读取退化为全量可见）。
  defp fetch_offering_by_id(id, actor) do
    case Cgc2046.Events.Offering.fetch(:event, id, actor: actor, authorize?: true) do
      {:ok, entity} -> {:ok, entity}
      {:error, _} -> Cgc2046.Events.Offering.fetch(:course, id, actor: actor, authorize?: true)
    end
  end
end
