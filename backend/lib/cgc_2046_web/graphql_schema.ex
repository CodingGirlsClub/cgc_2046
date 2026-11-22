defmodule Cgc2046Web.GraphqlSchema do
  use Absinthe.Schema
  import_types(Cgc2046Web.GraphqlSchema.Account)
  import_types(Cgc2046Web.GraphqlSchema.Invitation)
  import_types(Cgc2046Web.GraphqlSchema.Mcp)
  import_types(Cgc2046Web.GraphqlSchema.Initiatives)
  import_types(Cgc2046Web.GraphqlSchema.Recruitment)
  import_types(Cgc2046Web.GraphqlSchema.SpeakerInvitation)
  import_types(Cgc2046Web.GraphqlSchema.PaymentOperations)
  import_types(Cgc2046Web.GraphqlSchema.Offering)
  import_types(Cgc2046Web.GraphqlSchema.Learning)
  import_types(Cgc2046Web.GraphqlSchema.Auth)
  import_types(Cgc2046Web.GraphqlSchema.Auth.AccountSessionMutations)
  import_types(Cgc2046Web.GraphqlSchema.Auth.MiniWebLogin)
  import_types(Cgc2046Web.GraphqlSchema.AdminDashboard)
  import_types(Cgc2046Web.GraphqlSchema.Flashback)
  import_types(Cgc2046Web.GraphqlSchema.LlmGateway)
  import_types(Cgc2046Web.GraphqlSchema.LlmGatewayProviders)

  import Cgc2046Web.GraphqlSchema.Helpers

  use AshGraphql,
    domains: [
      Cgc2046.Admission,
      Cgc2046.Courses,
      Cgc2046.Curriculum,
      Cgc2046.Events,
      Cgc2046.Flashback,
      Cgc2046.Accounts,
      Cgc2046.Learning,
      Cgc2046.Notifications,
      Cgc2046.Payments,
      Cgc2046.Reconciliation,
      Cgc2046.Recruitment,
      Cgc2046.Sponsorship,
      Cgc2046.Workflows
    ],
    generate_sdl_file: "priv/graphql/schema.graphql",
    auto_generate_sdl_file?: true

  query do
    import_fields(:mini_web_login_queries)
    import_fields(:account_queries)
    import_fields(:mcp_queries)
    import_fields(:initiative_queries)

    @desc "Placeholder query until the first resource is added"
    field :ping, :string do
      resolve(fn _, _, _ ->
        {:ok, "pong"}
      end)
    end

    @desc "当前用户作为 Owner/Admin 的跨工作台待审批项（Enrollment + JoinRequest + Sponsorship）；include_expired=true 时附带已过期行（只读展示，E-8 #123）"
    field :my_pending_approvals, non_null(list_of(non_null(:pending_approval))) do
      arg(:include_expired, :boolean)

      resolve(fn _, args, %{context: context} ->
        with_actor(context, fn actor ->
          Cgc2046.PendingApprovals.list(actor,
            include_expired: args[:include_expired] || false
          )
        end)
      end)
    end

    @desc "当前用户作为 Owner/Admin 的跨工作台可操作待办总数（Enrollment + JoinRequest + Sponsorship 的 pending 且未过审批截止）；已过期不计（KTD8 口径，与 /approvals 展示含过期行存在有意差异）"
    field :pending_approvals_count, non_null(:integer) do
      resolve(fn _, _, %{context: context} ->
        with_actor(context, fn actor ->
          case Cgc2046.PendingApprovals.count_pending(actor) do
            {:ok, count} -> {:ok, count}
            {:error, reason} -> {:error, reason}
          end
        end)
      end)
    end

    import_fields(:flashback_queries)

    @desc "平台管理员：脱敏 workflow 运行元数据（不含 facts/input snapshot）"
    field :platform_workflow_audit, non_null(list_of(non_null(:platform_workflow_audit))) do
      arg(:workspace_id, :id)
      arg(:status, :string)
      arg(:started_after, :datetime)
      arg(:started_before, :datetime)

      resolve(fn _, args, %{context: context} ->
        with_admin(context, fn _actor ->
          {:ok,
           Cgc2046.Workflows.PlatformAudit.list(
             workspace_id: args[:workspace_id],
             status: args[:status],
             started_after: args[:started_after],
             started_before: args[:started_before]
           )}
        end)
      end)
    end

    import_fields(:speaker_invitation_queries)

    import_fields(:admin_dashboard_queries)

    import_fields(:offering_queries)

    import_fields(:recruitment_queries)
    import_fields(:learning_queries)
    import_fields(:llm_gateway_queries)
    import_fields(:llm_gateway_provider_queries)
  end

  mutation do
    import_fields(:learning_mutations)
    import_fields(:auth_mutations)
    import_fields(:auth_account_session_mutations)
    import_fields(:mini_web_login_mutations)
    import_fields(:invitation_mutations)

    @desc "记录一次小程序订阅消息授权并增加一个可用次数"
    field :grant_mini_program_notification_consent, :integer do
      arg(:platform, non_null(:string))
      arg(:template_key, non_null(:string))

      # #930：与登录拆桶——grant 本来就要求登录，按账号计（原「IP + 平台」桶与登录共用，
      # 1 次登录 + 1 次三模板订阅就吃掉 4/5，再登录即 Too many requests）
      resolve(fn _, %{platform: platform, template_key: template_key}, %{context: context} ->
        with_actor(context, fn actor ->
          key = Cgc2046Web.Plugs.RateLimit.build_key("rate:notification-consent:actor", actor.id)

          with :ok <- Cgc2046Web.Plugs.RateLimit.check(key, limit: :notification_consent_actor),
               {:ok, remaining} <-
                 Cgc2046.Notifications.Consent.grant(actor.id, platform, template_key) do
            {:ok, remaining}
          else
            :error ->
              {:error, message: "Too many requests. Try again later.", code: "rate_limited"}

            {:error, :invalid_platform} ->
              {:error, message: "Invalid platform", code: "invalid_platform"}

            {:error, _} ->
              {:error, message: "Consent grant failed", code: "consent_grant_failed"}
          end
        end)
      end)
    end

    import_fields(:account_mutations)
    import_fields(:mcp_mutations)

    import_fields(:payment_operation_mutations)

    import_fields(:speaker_invitation_mutations)

    import_fields(:admin_dashboard_mutations)

    import_fields(:offering_mutations)

    import_fields(:flashback_mutations)
    import_fields(:flashback_wish_mutations)
    import_fields(:recruitment_mutations)
    import_fields(:llm_gateway_mutations)
    import_fields(:llm_gateway_provider_mutations)
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

  object :platform_workflow_audit do
    field(:id, non_null(:id))
    field(:workspace_id, non_null(:id))
    field(:definition_type, non_null(:string))
    field(:status, non_null(:string))
    field(:started_at, :datetime)
    field(:finished_at, :datetime)
    field(:inserted_at, non_null(:datetime))
    field(:error_summary, :string)
  end

  # 持 token 的邀请接口限流：validate/accept 均吃明文 token 参数，按 IP+token 计，
  # 5 次/15 分钟（复用 RateLimit plug，与 sign_in/sign_up 同档位）。
  # token 为 256-bit 强随机，枚举不成立；此为已知 token 被滥用探测时的加固。
  # arity-3：Absinthe 的 middleware callback 是 arity-3（schema.middleware(mw, field, object)），
  # arity-2 不会被框架调用。
  def middleware(middleware, %{identifier: :validate_invitation}, _object),
    do: [{Cgc2046Web.Plugs.RateLimit, key_path: [:token]} | middleware]

  def middleware(middleware, _field, _object), do: middleware
end
