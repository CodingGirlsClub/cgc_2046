defmodule Cgc2046Web.GraphqlSchema do
  use Absinthe.Schema

  require Logger
  require Ash.Query
  require Ash.Expr

  alias Cgc2046.AdminList

  # ── #607 治理操作 metadata 读面白名单（唯一真源；加键只改本表）──────────────
  #
  # `admin_action_logs.metadata` 是自由 map 且**含 PII**（admin_promote / owner_reassign /
  # owner_invitation_cancel 的 email；application_reject 的 rejection_reason 自由文本），
  # 故 `/admin/audit` 读面按 action 分组投影，**不整列透传**：
  #
  #   - 只收录显式点名的 action；未收录（含未来新 action）一律 nil——没有默认透传兜底；
  #   - 表内不得出现 PII 键（email 类 / rejection_reason / 任意自由文本）；
  #   - `value_before` / `value_after` 自身也是自由 map（`InitiativeRule.value` 无约束、
  #     `upsertInitiativeRule` 收任意 JSON 对象）→ 同一条标准下沉一层，见
  #     `@rule_value_whitelist`；被省略的键由 `value_*_omitted` 显式标出，不静默截断。
  #
  # 新增可展示 action：键名落在 `admin_action_metadata` 既有字段（rule_key / locked /
  # locked_before / value_before / value_after）内 → 只加表项即可，投影逻辑与前端键序
  # 都不用动；形状不同的 action 需另立 GraphQL object（本表是可见性清单，不是形状引擎）。
  @admin_action_metadata_whitelist %{
    initiative_rule_update: ~w(rule_key locked locked_before value_before value_after)
  }

  # U1 治理写变更投影（offering）：闭集标量 → 每列 value_before / value_after 分列。
  # **不收自由文本**（description / venue / price_tiers 等不进 metadata），不复用
  # rule 族的 JSON 槽——形状不同另立 object（`admin_offering_change_metadata`）。
  # 表是行级可见性清单：只有 admin_event_update / admin_course_update 落表的行才
  # 投影；其余 action（含 launch/close/cancel）投影 nil（默认拒不破）。
  # Course 无 deposit_enabled（Event-only 槽位）→ 该 action 少两列。
  @offering_change_scalars ~w(title visibility capacity pricing_enabled deposit_enabled)
  @admin_offering_change_metadata_whitelist %{
    admin_event_update: @offering_change_scalars,
    admin_course_update: @offering_change_scalars -- ["deposit_enabled"]
  }

  # U1 治理 update mutation 的输入闭集（R5 标准元数据全集里治理面的可编辑子集：
  # 标题/时间/容量/截止/定价与押金槽位/visibility/venue）。
  # slug 在内——R7 的「已发布锁死」必须经同一 action 守卫落稳定 code
  # （event_slug_locked / course_slug_locked）；教研内容（curriculum_enabled /
  # curriculum_requirements / price_tiers / workflow_run_id 一类）不在治理面输入，
  # 仍只能走各自既有路径。字段名须与 input_object 的键一致（map_input/2 取键）。
  @admin_event_update_fields [
    :title,
    :slug,
    :description,
    :visibility,
    :capacity,
    :registration_deadline,
    :starts_at,
    :ends_at,
    :venue,
    :pricing_enabled,
    :deposit_enabled
  ]
  @admin_course_update_fields [
    :title,
    :slug,
    :description,
    :visibility,
    :capacity,
    :registration_deadline,
    :starts_at,
    :ends_at,
    :pricing_enabled
  ]

  # 二级白名单：rule_key → 该规则 value map 可出面的键（次序 = 界面渲染次序）。
  # 四项规则值都是治理设置（押金开关与金额分 / 年龄门槛 / 成班阈值 / 截止小时数），
  # 本身非敏感；未收录的 rule_key 投影为空 + omitted=true。
  @rule_value_whitelist %{
    "deposit" => ~w(enabled amount_cents refundable_on_check_in),
    "age_gate" => ~w(min_age),
    "min_participants" => ~w(count),
    "deadline_rule" => ~w(hours_before_start)
  }

  use AshGraphql,
    domains: [
      Cgc2046.Admission,
      Cgc2046.Courses,
      Cgc2046.Curriculum,
      Cgc2046.Events,
      Cgc2046.Accounts,
      Cgc2046.Learning,
      Cgc2046.Payments,
      Cgc2046.Reconciliation,
      Cgc2046.Sponsorship,
      Cgc2046.Workflows
    ],
    generate_sdl_file: "priv/graphql/schema.graphql",
    auto_generate_sdl_file?: true

  query do
    @desc "Placeholder query until the first resource is added"
    field :ping, :string do
      resolve(fn _, _, _ ->
        {:ok, "pong"}
      end)
    end

    @desc "角色权限矩阵（#66 Rbac）：五角色 × 八能力，对齐前端权限表（需登录；#1 能力接口：abilities 为通用列表）"
    field :permission_matrix, :permission_matrix_payload do
      resolve(fn _, _, %{context: context} ->
        with_actor(context, fn _actor ->
          roles =
            Cgc2046.Accounts.Rbac.matrix()
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

    @desc "当前登录用户的掩码手机号（仅本人；未绑定返回 null；前 6 后 4 中间 ****，明文不出 GraphQL 面）"
    field :my_phone, :string do
      resolve(fn _, _, %{context: context} ->
        with_actor(context, fn actor ->
          {:ok, Cgc2046.Accounts.PhoneNumber.mask(actor.phone)}
        end)
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

    @desc "当前用户 confirmed 课程报名的学习 run 进度（非成员可读；event 报名不走 objective 学习不返回，已取消课程除外）"
    field :my_learning_runs, non_null(list_of(non_null(:my_learning_run))) do
      resolve(fn _, _, %{context: context} ->
        with_actor(context, &Cgc2046.Learning.Runs.my_learning_runs/1)
      end)
    end

    # #355 P1-3：详情页「已报名」态数据源——actor 在目标活动/课程上的活跃报名
    # （pending/payment_pending/confirmed，语义同 MCP discover_offerings.
    # my_enrollment；读取真源 Enrollment.active_enrollments_by_offering，带
    # actor 走 read policy 本人锚定）。匿名 → null（公开详情页可匿名访问，
    # 不落 unauthorized——否则整文档 errors 拖死匿名 getEvent/getCourse）。
    @desc "当前用户在目标活动/课程上的活跃报名（pending/payment_pending/confirmed；无报名或未登录为 null）"
    field :my_enrollment, :enrollment do
      arg(:kind, non_null(:string), description: "event | course")
      arg(:offering_id, non_null(:id))

      resolve(fn _, args, %{context: context} ->
        with_actor(context, fn actor -> resolve_my_enrollment(actor, args) end,
          on_nil: fn _context -> {:ok, nil} end
        )
      end)
    end

    @desc "公开课程地图(U7/R10):issue key/标题/kind/goal 一行;匿名可读,不露 checklist"
    field :course_map, :course_map do
      arg(:slug, non_null(:string))

      resolve(fn _, args, _ ->
        Cgc2046.Courses.CourseProjection.map_by_slug(args[:slug])
      end)
    end

    @desc "公开 Initiative 活动页投影；匿名可读，统一跨租户计数口径"
    field :public_initiative, :public_initiative do
      arg(:slug, non_null(:string))

      resolve(fn _, %{slug: slug}, _ ->
        case Cgc2046.Initiatives.Public.get_by_slug(slug) do
          {:ok, payload} -> {:ok, payload}
          {:error, :not_found} -> {:ok, nil}
          {:error, _} -> {:error, [message: "failed to load public initiative", code: "invalid"]}
        end
      end)
    end

    @desc "公开 Initiative 列表；匿名可读"
    field :public_initiatives, non_null(list_of(non_null(:public_initiative_card))) do
      resolve(fn _, _, _ ->
        case Cgc2046.Initiatives.Public.list() do
          {:ok, rows} -> {:ok, rows}
          {:error, _} -> {:error, [message: "failed to load public initiatives", code: "invalid"]}
        end
      end)
    end

    @desc "当前用户的课程学习详情（U7 抽屉数据：课程地图 + 本人记录合成；恒 actor 视角无他人面）"
    field :course_learning_detail, :course_learning_detail do
      arg(:course_id, non_null(:id))

      resolve(fn _, args, %{context: context} ->
        with_actor(context, fn actor ->
          Cgc2046.Courses.CourseProjection.learning_detail(actor, args[:course_id])
        end)
      end)
    end

    @desc "当前用户可读的已发布课程内容（chapter + typed materials；不含原始 WorkflowRun）"
    field :course_content, :course_content do
      arg(:course_id, non_null(:id))

      resolve(fn _, %{course_id: course_id}, %{context: context} ->
        with_actor(context, fn actor ->
          Cgc2046.Courses.CourseProjection.content(actor, course_id)
        end)
      end)
    end

    @desc "Tutor/Owner/Admin 课程草稿（不向 learner 暴露；无权/课程不存在统一 null，不泄露存在性）"
    field :course_draft, :course_draft do
      arg(:course_id, non_null(:id))

      resolve(fn _, %{course_id: course_id}, %{context: context} ->
        with_actor(context, fn actor ->
          Cgc2046.Courses.CourseProjection.draft(actor, course_id)
        end)
      end)
    end

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

    @desc "Tutor/Owner/Admin 课程学习聚合（不含 learner evidence）"
    field :course_learning_analytics, :course_learning_analytics do
      arg(:course_id, non_null(:id))

      resolve(fn _, %{course_id: course_id}, %{context: context} ->
        with_actor(context, fn actor ->
          case Cgc2046.Courses.Course
               |> Ash.Query.for_read(:get_by_id, %{id: course_id})
               |> Ash.read_one(authorize?: false) do
            {:ok, %{} = course} ->
              if Cgc2046.Accounts.Rbac.staff?(actor, course.workspace_id) do
                {:ok, Cgc2046.Learning.Analytics.for_course(course)}
              else
                {:ok, nil}
              end

            _ ->
              {:ok, nil}
          end
        end)
      end)
    end

    @desc "当前用户在某工作台的 MCP 工具调用活动流（plan 020 U2.1；policy：workspace 成员 + 仅本人；params 摘要级不返回）"
    field :my_workspace_tool_calls, non_null(list_of(non_null(:workspace_tool_call))) do
      arg(:workspace_id, non_null(:id))
      arg(:first, :integer)

      resolve(fn _, args, %{context: context} ->
        # args 只含调用方提供的键（first 可缺省）——不能用固定键 pattern match。
        # 018：first 封顶（与 AdminList.paginate 共用上限），防无界全表导出
        with_actor(context, fn actor ->
          resolve_my_workspace_tool_calls(
            actor,
            args[:workspace_id],
            min(args[:first] || 50, AdminList.max_first())
          )
        end)
      end)
    end

    # ── SpeakerInvitation（E-4 #49）──

    @desc "邀请卡片（Speaker 着陆页，无需登录）：token 公开校验，返回邀请主题/时间 + Event 公开信息 + viewerIsInviter；无效/过期/已用 token 统一错误，不泄露其它邀请"
    field :speaker_invitation_card, :speaker_invitation_card do
      arg(:token, non_null(:string))

      resolve(fn _, %{token: token}, %{context: context} ->
        case Cgc2046.Events.SpeakerInvitations.card(token, context[:actor]) do
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
              # 内部 reason 不透传客户端（#241 F9，SecurityReview 遗留）
              Logger.warning("[speaker_invitations] list_for_event failed: #{inspect(reason)}")
              {:error, [message: "invalid request", code: "invalid"]}
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
          fn q, args -> AdminList.maybe_user_search(q, args[:search]) end,
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
          fn q, args -> AdminList.maybe_workspace_search(q, args[:search]) end,
          admin_result(Cgc2046.Accounts.Workspace, Cgc2046.Accounts),
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
          fn q, args -> AdminList.maybe_status_filter(q, args[:status]) end,
          admin_result(Cgc2046.Accounts.WorkspaceApplication, Cgc2046.Accounts)
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
          |> map_error(context, :read, Cgc2046.Accounts.WorkspaceApplication, Cgc2046.Accounts)
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
            |> AdminList.maybe_workspace_filter(args[:workspace_id])
            |> AdminList.maybe_status_filter(args[:status], :result_status)
            |> AdminList.maybe_time_range_filter(args)
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
            |> AdminList.maybe_workspace_filter(args[:workspace_id])
            |> AdminList.maybe_pending_status_filter(args[:status])
            |> AdminList.maybe_time_range_filter(args)
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
            |> AdminList.maybe_real_workspace_filter(args[:workspace_id])
            |> AdminList.maybe_signal_type_filter(args[:signal_type])
            |> AdminList.maybe_time_range_filter(args)
          end,
          admin_result(Cgc2046.Workflows.SignalLog, Cgc2046.Workflows)
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
            |> AdminList.maybe_action_filter(args[:action])
            |> AdminList.maybe_time_range_filter(args)
          end,
          admin_result(Cgc2046.Accounts.AdminActionLog, Cgc2046.Accounts)
        )
      )
    end

    @desc "平台管理员：对账扫描发现（E-10 #125；rule/entity_type 枚举过滤、workspaceId 真实列过滤，分页 first/after；entityId 必须与 entityType 成对——KTD5）"
    field :reconciliation_findings, non_null(list_of(non_null(:admin_reconciliation_finding))) do
      arg(:rule, :string)
      arg(:entity_type, :string)
      arg(:entity_id, :string)
      arg(:workspace_id, :id)
      arg(:first, :integer)
      arg(:after, :string)

      resolve(
        admin_list(
          Cgc2046.Reconciliation.Finding,
          fn q, args ->
            q
            # atom 约束字段精确过滤（非枚举值静默忽略，同 AdminList.maybe_status_filter 语义）
            |> AdminList.maybe_status_filter(args[:rule], :rule)
            |> AdminList.maybe_status_filter(args[:entity_type], :entity_type)
            |> maybe_finding_entity_id(args[:entity_id])
            |> AdminList.maybe_real_workspace_filter(args[:workspace_id])
          end,
          admin_result(Cgc2046.Reconciliation.Finding, Cgc2046.Reconciliation),
          validate: &validate_finding_entity_pair/1
        )
      )
    end

    @desc "平台管理员：倡导活动列表"
    field :list_initiatives, non_null(list_of(non_null(:admin_initiative))) do
      arg(:status, :string)
      arg(:search, :string)
      arg(:first, :integer)
      arg(:after, :string)

      resolve(fn _, args, %{context: context} ->
        with_admin(context, fn actor ->
          query =
            Cgc2046.Initiatives.Initiative
            |> Ash.Query.for_read(:read)
            |> AdminList.maybe_status_filter(args[:status])
            |> maybe_initiative_search(args[:search])
            |> AdminList.paginate(args[:first], args[:after])

          case Ash.read(query, actor: actor) do
            {:ok, initiatives} ->
              case Ash.load(initiatives, :rules, actor: actor) do
                {:ok, loaded} ->
                  {:ok, Enum.map(loaded, &admin_initiative_row/1)}

                {:error, error} ->
                  {:error,
                   to_ash_graphql_errors(
                     error,
                     context,
                     :read,
                     Cgc2046.Initiatives.Initiative,
                     Cgc2046.Initiatives
                   )}
              end

            {:error, error} ->
              {:error,
               to_ash_graphql_errors(
                 error,
                 context,
                 :read,
                 Cgc2046.Initiatives.Initiative,
                 Cgc2046.Initiatives
               )}
          end
        end)
      end)
    end

    @desc "平台管理员：倡导活动详情及四项规则"
    field :get_initiative, :admin_initiative do
      arg(:id, non_null(:id))

      resolve(fn _, %{id: id}, %{context: context} ->
        with_admin(context, fn actor ->
          case Ash.get(Cgc2046.Initiatives.Initiative, id, actor: actor) do
            {:ok, nil} ->
              {:ok, nil}

            {:ok, initiative} ->
              load_initiative_admin(initiative, actor, context)

            {:error, error} ->
              {:error,
               to_ash_graphql_errors(
                 error,
                 context,
                 :read,
                 Cgc2046.Initiatives.Initiative,
                 Cgc2046.Initiatives
               )}
          end
        end)
      end)
    end

    # ── U2 平台治理：offering（Event / Course）治理读面 ──────────────────────
    # 门控 = with_admin（非平台管理员 forbidden / 未登录 unauthorized）；读走
    # `Ash.Query.for_read(:read)` + actor 直传的标准授权——Event/Course 均
    # `global?(true)` multitenant，无 tenant 即跨租户全表读，read policy 对
    # PlatformAdmin 已放行（KTD3）。列表行不带报名计数（计数只在详情，KTD4）。

    @desc "平台管理员：跨租户活动列表（R1；status/search 过滤 + 工作台过滤 + first/after 分页，含 draft/cancelled）"
    field :list_admin_events, non_null(list_of(non_null(:admin_event))) do
      arg(:status, :string)
      arg(:search, :string)
      arg(:workspace_id, :id)
      arg(:first, :integer)
      arg(:after, :string)

      resolve(
        admin_list(
          Cgc2046.Events.Event,
          fn q, args ->
            q
            |> AdminList.maybe_status_filter(args[:status])
            |> AdminList.maybe_offering_search(args[:search])
            |> AdminList.maybe_real_workspace_filter(args[:workspace_id])
          end,
          admin_rows(Cgc2046.Events.Event, Cgc2046.Events, &admin_event_row/1)
        )
      )
    end

    @desc "平台管理员：跨租户课程列表（R1；status/search 过滤 + 工作台过滤 + first/after 分页，含 draft/cancelled）"
    field :list_admin_courses, non_null(list_of(non_null(:admin_course))) do
      arg(:status, :string)
      arg(:search, :string)
      arg(:workspace_id, :id)
      arg(:first, :integer)
      arg(:after, :string)

      resolve(
        admin_list(
          Cgc2046.Courses.Course,
          fn q, args ->
            q
            |> AdminList.maybe_status_filter(args[:status])
            |> AdminList.maybe_offering_search(args[:search])
            |> AdminList.maybe_real_workspace_filter(args[:workspace_id])
          end,
          admin_rows(Cgc2046.Courses.Course, Cgc2046.Courses, &admin_course_row/1)
        )
      )
    end

    @desc "平台管理员：活动治理详情（R3；权威报名计数 + 主理人清单 + 解除挂载来源标记；id 不存在返回 null）"
    field :get_admin_event, :admin_event_detail do
      arg(:id, non_null(:id))

      resolve(fn _, %{id: id}, %{context: context} ->
        with_admin(context, fn actor ->
          case Ash.get(Cgc2046.Events.Event, id, actor: actor, not_found_error?: false) do
            {:ok, nil} ->
              {:ok, nil}

            {:ok, event} ->
              {:ok, admin_event_detail_row(event, actor)}

            {:error, error} ->
              {:error,
               to_ash_graphql_errors(
                 error,
                 context,
                 :read,
                 Cgc2046.Events.Event,
                 Cgc2046.Events
               )}
          end
        end)
      end)
    end

    @desc "平台管理员：课程治理详情（R3；权威报名计数 + 当前版本指针 + 占位标题标记；id 不存在返回 null）"
    field :get_admin_course, :admin_course_detail do
      arg(:id, non_null(:id))

      resolve(fn _, %{id: id}, %{context: context} ->
        with_admin(context, fn actor ->
          case Ash.get(Cgc2046.Courses.Course, id, actor: actor, not_found_error?: false) do
            {:ok, nil} ->
              {:ok, nil}

            {:ok, course} ->
              {:ok, admin_course_detail_row(course)}

            {:error, error} ->
              {:error,
               to_ash_graphql_errors(
                 error,
                 context,
                 :read,
                 Cgc2046.Courses.Course,
                 Cgc2046.Courses
               )}
          end
        end)
      end)
    end

    @desc "Owner/Admin：挂载前预览 Initiative 四项规则的值与锁态（#596）；非本台 Owner/Admin 一律 forbidden"
    field :initiative_mount_preview, :initiative_mount_preview do
      arg(:workspace_id, non_null(:id))
      arg(:initiative_id, non_null(:id))

      resolve(fn _, args, %{context: context} ->
        with_actor(context, fn actor ->
          case Cgc2046.Initiatives.RulePreview.get(
                 args[:initiative_id],
                 actor,
                 args[:workspace_id]
               ) do
            {:ok, preview} -> {:ok, initiative_mount_preview_row(preview)}
            {:error, :forbidden} -> {:error, [message: "forbidden", code: "forbidden"]}
            {:error, :not_found} -> {:error, [message: "initiative not found", code: "not_found"]}
            {:error, _} -> {:error, [message: "failed to load initiative rules", code: "invalid"]}
          end
        end)
      end)
    end

    @desc "活动主理人列表；主理人或所属 Workspace Owner/Admin 可读"
    field :event_moderators, non_null(list_of(non_null(:event_moderator))) do
      arg(:workspace_id, non_null(:id))
      arg(:event_id, non_null(:id))

      resolve(fn _, args, %{context: context} ->
        with_actor(context, fn actor ->
          case Cgc2046.Events.Moderators.list(args[:event_id], args[:workspace_id], actor) do
            {:ok, rows} -> {:ok, rows}
            {:error, :forbidden} -> {:error, [message: "forbidden", code: "forbidden"]}
            {:error, _} -> {:error, [message: "event not found", code: "not_found"]}
          end
        end)
      end)
    end
  end

  mutation do
    @desc "账号密码登录（plan 002 U2：login 含 @ 走邮箱，否则手机号归一化；token 经 httpOnly cookie 交付）"
    field :sign_in, :sign_in_result do
      arg(:login, non_null(:string))
      arg(:password, non_null(:string))

      middleware(Cgc2046Web.Plugs.RateLimit,
        key_path: [:login],
        normalize: &Cgc2046.Accounts.WebAuthFlow.normalize_login/1
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
             :ok <- Cgc2046.Accounts.WebAuthFlow.check_phone_code_request_limits(context, phone) do
          Cgc2046.Accounts.WebAuthFlow.request_phone_code(phone, purpose)
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
             :ok <- Cgc2046.Accounts.WebAuthFlow.check_phone_code_verify_limits(context, phone) do
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
        if Cgc2046.Integrations.Wechat.WebOAuth.configured?() do
          with :ok <- Cgc2046.Accounts.WebAuthFlow.check_wechat_login_start_limits(context) do
            Cgc2046.Accounts.WebAuthFlow.start_wechat_login(args[:next])
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
        with :ok <- Cgc2046.Accounts.WebAuthFlow.check_wechat_callback_limits(context) do
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

            {:error, reason} ->
              # 防枚举：客户端只收统一错误；服务端只记白名单分类，原始
              # code/token/身份值与下游 error struct 均不得进入日志。
              summary = Cgc2046.Accounts.WebAuthFlow.summarize_wechat_sign_in_failure(reason)
              Logger.warning("[wechat_web sign_in] failed: #{inspect(summary)}")

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
             :ok <- Cgc2046.Accounts.WebAuthFlow.check_wechat_bind_limits(context, phone) do
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

    @desc "手机号注册（验证码 + 密码；httpOnly cookie 交付 token，自动登录）"
    field :sign_up_with_phone, :sign_up_with_phone_payload do
      arg(:input, non_null(:sign_up_with_phone_input))

      resolve(fn _, %{input: %{phone: raw_phone, code: code, password: password}}, ctx ->
        context = ctx.context

        with {:ok, phone} <- Cgc2046.Accounts.PhoneNumber.normalize(raw_phone),
             :ok <- Cgc2046.Accounts.WebAuthFlow.check_phone_code_verify_limits(context, phone) do
          Cgc2046.Accounts.WebAuthFlow.sign_up_with_phone(phone, code, password, context)
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

    @desc "请求发送密码重置邮件（无论邮箱是否存在都返回统一成功结果）"
    field :request_password_reset, :request_password_reset_result do
      arg(:email, non_null(:string))

      middleware(
        Cgc2046Web.Plugs.RateLimit,
        key_path: [:email],
        normalize: &Cgc2046.Accounts.WebAuthFlow.normalize_email/1
      )

      resolve(fn _, %{email: email}, %{context: context} ->
        email = Cgc2046.Accounts.WebAuthFlow.normalize_email(email)

        case Cgc2046.Accounts.WebAuthFlow.check_password_reset_request_limits(context, email) do
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
              Cgc2046.Accounts.WebAuthFlow.classify_password_reset_error(error, context)

            other ->
              Cgc2046.Accounts.WebAuthFlow.report_password_reset_failure(other)
          end
        rescue
          error ->
            Cgc2046.Accounts.WebAuthFlow.report_password_reset_failure(error)
        catch
          kind, reason ->
            Cgc2046.Accounts.WebAuthFlow.report_password_reset_failure({kind, reason})
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
        catch
          # Elixir rescue 不抓 exit（如依赖进程缺失 noproc）——缺此分支则
          # 登录失败穿透至 Absinthe/Plug 500 且无统一文案，防枚举语义被绕过。
          :exit, _ ->
            {:error, message: "Platform sign in failed", code: "authentication_failed"}
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
          case Cgc2046.Accounts.MiniprogramCode.generate(workspace_id, actor, platform) do
            {:ok, result} ->
              {:ok, result}

            {:error, :forbidden} ->
              {:error, message: "Forbidden", code: "forbidden"}

            {:error, :invalid_platform} ->
              {:error, message: "Invalid platform", code: "invalid_platform"}

            {:error, :daily_quota_exhausted} ->
              {:error, message: "Daily quota exhausted", code: "daily_quota_exhausted"}

            # 锁超时/死锁（#621）：BusinessError 原样出面（message 逐字 + 独立 code），
            # 不落下面 code_generation_failed 兜底——可自愈并发冲突不是"生成失败"。
            {:error, %Cgc2046.Errors.BusinessError{code: code, message: message}} ->
              {:error, message: message, code: code}

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

          not Cgc2046.Accounts.MiniprogramCode.valid_scene?(scene) ->
            {:error, message: "Invalid scene", code: "invalid_scene"}

          true ->
            actor = context[:actor]

            # #217 旁路读取（A 类·凭证即凭据）：一次性小程序 scene 码经
            # code_for_scene 校验（scene + 未过期精确匹配）换得 invitation_id，
            # Ash.get 直读定位（Invitation read policy 是 inviter/Owner-Admin
            # 视角，受邀者被拒成 not_found 到不了 action）；随后 for_update 带
            # actor 走 accept_miniprogram 的 actor_present 门禁，before_action
            # scene 复验（已用/过期 → invalid_or_expired_scene）。
            with {:ok, code} <- Cgc2046.Accounts.MiniprogramCode.code_for_scene(scene),
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
          # TokenCredential.fetch 以 extra_filter: [id: id] 保留双因子，nil 塌缩为
          # :invalid_token，由调用方映射回 accept_not_found_errors（not_found 语义）。
          with {:ok, invitation} <-
                 Cgc2046.Accounts.TokenCredential.fetch(Cgc2046.Accounts.Invitation, token,
                   id: id
                 ),
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
          case Cgc2046.Notifications.Consent.grant(actor.id, platform, template_key) do
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

    @desc "绑定/换绑当前用户手机号（验证码 purpose=CHANGE_PHONE 验新号；仅本人；目标号已被他人占用即拒绝，不做自助合并）"
    field :update_my_phone, :user do
      arg(:phone, non_null(:string))
      arg(:code, non_null(:string))

      resolve(fn _, %{phone: raw_phone, code: code}, %{context: context} ->
        with_actor(context, fn actor ->
          with {:ok, phone} <- Cgc2046.Accounts.PhoneNumber.normalize(raw_phone),
               :ok <- Cgc2046.Accounts.WebAuthFlow.check_phone_code_verify_limits(context, phone),
               :ok <-
                 Cgc2046.Accounts.PhoneVerificationCode.consume_valid(phone, code, :change_phone) do
            Cgc2046.Accounts.WebAuthFlow.update_my_phone(actor, phone, context)
          else
            {:error, :invalid} ->
              {:error, message: "Invalid phone number", code: "invalid_phone"}

            {:error, :rate_limited} ->
              {:error, message: "Too many requests. Try again later.", code: "rate_limited"}

            {:error, :invalid_code} ->
              {:error, message: "Invalid or expired code", code: "invalid_or_expired_code"}

            {:error, :code_not_available} ->
              {:error, message: "Invalid or expired code", code: "invalid_or_expired_code"}
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

    @desc "拒绝首公里接入邀请（每次登录弹直到明确拒绝；幂等保留首次拒绝时间戳，仅本人）"
    field :dismiss_onboarding_invitation, :user do
      resolve(fn _, _, %{context: context} ->
        with_actor(context, fn actor ->
          case Ash.update(actor, %{},
                 action: :dismiss_onboarding_invitation,
                 actor: actor
               ) do
            {:ok, user} ->
              load_profile(user, actor, context, :dismiss_onboarding_invitation)

            {:error, error} ->
              {:error, to_ash_graphql_errors(error, context, :dismiss_onboarding_invitation)}
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

    # ── 高风险支付操作两段确认（web 面 R15/R17/R18；编排在
    #    Cgc2046Web.PaymentConfirmation，复用 Mcp.PendingOperation/Confirmation，
    #    confirm 段分派到同名 MCP 工具的 execute_confirmed/2，domain 的
    #    CAS/审计/worker 路径不变）──

    @desc "管理员单笔退款（R15）：第一段——建 pending 并返回后端生成的确认摘要（不落业务库）；confirmOperation 确认后真正执行"
    field :refund_order, :pending_operation_confirmation do
      arg(:id, non_null(:id))

      resolve(fn _, %{id: id}, %{context: context} ->
        with_actor(context, fn actor ->
          actor
          |> Cgc2046Web.PaymentConfirmation.request_refund(id)
          |> pending_confirmation_payload()
        end)
      end)
    end

    @desc "退款失败重试（R17）：第一段——refund_failed 单建 pending（不落业务库）；confirmOperation 确认后重入退款链"
    field :retry_refund, :pending_operation_confirmation do
      arg(:id, non_null(:id))

      resolve(fn _, %{id: id}, %{context: context} ->
        with_actor(context, fn actor ->
          actor
          |> Cgc2046Web.PaymentConfirmation.request_retry_refund(id)
          |> pending_confirmation_payload()
        end)
      end)
    end

    @desc "免缴（R18）：第一段——payment_pending 报名建 pending（不落业务库）；confirmOperation 确认后跳过支付直接确认"
    field :waive_payment, :pending_operation_confirmation do
      arg(:id, non_null(:id))

      resolve(fn _, %{id: id}, %{context: context} ->
        with_actor(context, fn actor ->
          actor
          |> Cgc2046Web.PaymentConfirmation.request_waive(id)
          |> pending_confirmation_payload()
        end)
      end)
    end

    @desc "确认并执行 pending 操作（仅本人、pending 且未过期；effect 失败 pending 回滚可重试）"
    field :confirm_operation, :operation_resolution do
      arg(:pending_id, non_null(:id))

      resolve(fn _, %{pending_id: pending_id}, %{context: context} ->
        with_actor(context, fn actor ->
          case Cgc2046.Mcp.Confirmation.confirm(actor, pending_id) do
            {:ok, %{pending_id: id, status: status}} ->
              {:ok, %{pending_id: id, status: status, errors: []}}

            {:error, message} ->
              {:ok,
               %{
                 pending_id: nil,
                 status: nil,
                 errors: [
                   mutation_error_payload(
                     message,
                     Cgc2046.Mcp.Confirmation.confirm_failed_code()
                   )
                 ]
               }}
          end
        end)
      end)
    end

    @desc "取消 pending 操作（仅本人、pending；取消后不执行，过期自动失效）"
    field :cancel_operation, :operation_resolution do
      arg(:pending_id, non_null(:id))

      resolve(fn _, %{pending_id: pending_id}, %{context: context} ->
        with_actor(context, fn actor ->
          case Cgc2046.Mcp.Confirmation.cancel(actor, pending_id) do
            {:ok, %{pending_id: id, status: status}} ->
              {:ok, %{pending_id: id, status: status, errors: []}}

            {:error, message} ->
              {:ok,
               %{
                 pending_id: nil,
                 status: nil,
                 errors: [
                   mutation_error_payload(
                     message,
                     Cgc2046.Mcp.Confirmation.cancel_failed_code()
                   )
                 ]
               }}
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
                   Cgc2046.Events
                 )
             }}
        end
      end)
    end

    @desc "Owner/Admin 重发邀请/重新生成链接：旧链接即刻作废，新明文 token 仅经 plainToken 返回一次；有邮箱的同时异步发出新邮件（尽力而为，不承诺送达）"
    field :resend_speaker_invitation, :resend_speaker_invitation_payload do
      arg(:id, non_null(:id))

      resolve(fn _, %{id: id}, %{context: context} ->
        with_actor(context, fn actor ->
          case Ash.get(Cgc2046.Events.SpeakerInvitation, id, authorize?: false) do
            {:ok, %Cgc2046.Events.SpeakerInvitation{} = invitation} ->
              case Cgc2046.Events.SpeakerInvitation.resend(invitation, actor) do
                {:ok, updated, plain_token} ->
                  {:ok, %{result: updated, plain_token: plain_token, errors: []}}

                {:error, error} ->
                  {:ok,
                   %{
                     result: nil,
                     plain_token: nil,
                     errors:
                       to_ash_graphql_errors(
                         error,
                         context,
                         :resend_invitation,
                         Cgc2046.Events.SpeakerInvitation,
                         Cgc2046.Events
                       )
                   }}
              end

            _ ->
              # id 不存在：与 AshGraphql NotFound 映射同形（message/code），不泄露存在性
              {:ok,
               %{
                 result: nil,
                 plain_token: nil,
                 errors: [%{message: "could not be found", code: "not_found"}]
               }}
          end
        end)
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
          # #217 旁路读取（B 类·action 层授权）：read policy 仅 Owner/Admin/
          # PlatformAdmin 视角，Speaker 本人非成员读不到自己的邀请，故 get
          # 直读定位；随后 for_update(:save_materials) 带 actor 走 action
          # policy（speaker_user_id == actor.id 本人 或 Owner/Admin 兜底）。
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
          # #217 旁路读取（B 类·action 层授权）：同 save_speaker_materials——
          # get 直读定位，for_update(:complete_speaking) 带 actor 走 action
          # policy（Speaker 本人 或 Owner/Admin 兜底）。
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

    @desc "平台管理员：创建倡导活动草稿"
    field :create_initiative, :admin_initiative_payload do
      arg(:input, non_null(:admin_initiative_input))

      resolve(fn _, %{input: input}, %{context: context} ->
        with_admin(context, fn actor ->
          attrs =
            input
            |> map_input([
              :name,
              :slug,
              :hashtag,
              :description,
              :window_starts_at,
              :window_ends_at
            ])
            |> Map.put(:created_by, actor.id)

          Cgc2046.Initiatives.Initiative
          |> Ash.Changeset.for_create(:create, attrs)
          |> Ash.create(actor: actor)
          |> initiative_mutation_result(context)
        end)
      end)
    end

    @desc "平台管理员：更新倡导活动元数据"
    field :update_initiative, :admin_initiative_payload do
      arg(:id, non_null(:id))
      arg(:input, non_null(:admin_initiative_input))

      resolve(fn _, %{id: id, input: input}, %{context: context} ->
        with_admin(context, fn actor ->
          with {:ok, initiative} <- Ash.get(Cgc2046.Initiatives.Initiative, id, actor: actor) do
            initiative
            |> Ash.Changeset.for_update(
              :update,
              map_input(input, [
                :name,
                :slug,
                :hashtag,
                :description,
                :window_starts_at,
                :window_ends_at
              ])
            )
            |> Ash.update(actor: actor)
            |> initiative_mutation_result(context)
          else
            {:error, error} ->
              {:error,
               to_ash_graphql_errors(
                 error,
                 context,
                 :update,
                 Cgc2046.Initiatives.Initiative,
                 Cgc2046.Initiatives
               )}
          end
        end)
      end)
    end

    @desc "平台管理员：设置倡导活动状态为进行中"
    field :open_initiative, :admin_initiative_payload do
      arg(:id, non_null(:id))
      resolve(initiative_status_mutation(:open))
    end

    @desc "平台管理员：结束倡导活动"
    field :close_initiative, :admin_initiative_payload do
      arg(:id, non_null(:id))
      resolve(initiative_status_mutation(:close))
    end

    @desc "平台管理员：中止倡导活动（级联取消挂载中仍开放的场次，已付报名全额退款）"
    field :cancel_initiative, :admin_initiative_payload do
      arg(:id, non_null(:id))
      resolve(initiative_status_mutation(:cancel))
    end

    # ── U1 平台治理：offering（Event / Course）治理写 ────────────────────────
    # 门控 = with_admin（非平台管理员 forbidden / 未登录 unauthorized）+ 治理
    # mutation 内 actor 直传的标准授权——复用同一资源 action，slug 锁、命名门、
    # prep 门、状态机 CAS、信号链与留痕挂接全部零复刻（R4/R5/R7/R9）。

    @desc "平台管理员：发布活动（draft → open；同工作台 launch action 语义）"
    field :admin_launch_event, :admin_event_payload do
      arg(:id, non_null(:id))
      resolve(offering_status_mutation(Cgc2046.Events.Event, :launch, Cgc2046.Events))
    end

    @desc "平台管理员：结束活动（open → closed；发 event.ended 信号）"
    field :admin_close_event, :admin_event_payload do
      arg(:id, non_null(:id))
      resolve(offering_status_mutation(Cgc2046.Events.Event, :close, Cgc2046.Events))
    end

    @desc "平台管理员：取消活动（open → cancelled；报名/退款按既有取消链路异步处理）"
    field :admin_cancel_event, :admin_event_payload do
      arg(:id, non_null(:id))
      resolve(offering_status_mutation(Cgc2046.Events.Event, :cancel, Cgc2046.Events))
    end

    @desc "平台管理员：编辑活动元数据（R5 标准元数据全集；slug 锁与教研内容不放行）"
    field :admin_update_event, :admin_event_payload do
      arg(:id, non_null(:id))
      arg(:input, non_null(:admin_event_update_input))

      resolve(
        offering_update_mutation(
          Cgc2046.Events.Event,
          @admin_event_update_fields,
          Cgc2046.Events
        )
      )
    end

    @desc "平台管理员：发布课程（draft → open；同工作台 launch action 语义）"
    field :admin_launch_course, :admin_course_payload do
      arg(:id, non_null(:id))
      resolve(offering_status_mutation(Cgc2046.Courses.Course, :launch, Cgc2046.Courses))
    end

    @desc "平台管理员：结束课程（open → closed；发 course.ended 信号）"
    field :admin_close_course, :admin_course_payload do
      arg(:id, non_null(:id))
      resolve(offering_status_mutation(Cgc2046.Courses.Course, :close, Cgc2046.Courses))
    end

    @desc "平台管理员：取消课程（open → cancelled；报名/退款按既有取消链路异步处理）"
    field :admin_cancel_course, :admin_course_payload do
      arg(:id, non_null(:id))
      resolve(offering_status_mutation(Cgc2046.Courses.Course, :cancel, Cgc2046.Courses))
    end

    @desc "平台管理员：编辑课程元数据（R5 标准元数据全集；slug 锁与教研内容不放行）"
    field :admin_update_course, :admin_course_payload do
      arg(:id, non_null(:id))
      arg(:input, non_null(:admin_course_update_input))

      resolve(
        offering_update_mutation(
          Cgc2046.Courses.Course,
          @admin_course_update_fields,
          Cgc2046.Courses
        )
      )
    end

    @desc "平台管理员：创建或更新倡导活动规则；value_json 为 JSON 对象字符串"
    field :upsert_initiative_rule, :admin_initiative_rule_payload do
      arg(:initiative_id, non_null(:id))
      arg(:key, non_null(:string))
      arg(:value_json, non_null(:string))
      arg(:locked, non_null(:boolean))

      resolve(fn _, args, %{context: context} ->
        with_admin(context, fn actor ->
          with {:ok, key} <- rule_key(args[:key]),
               {:ok, value} <- decode_rule_json(args[:value_json]),
               {:ok, _initiative} <-
                 Ash.get(Cgc2046.Initiatives.Initiative, args[:initiative_id], actor: actor),
               {:ok, existing} <- get_initiative_rule(args[:initiative_id], key, actor) do
            result =
              if existing do
                existing
                |> Ash.Changeset.for_update(:update, %{value: value, locked: args[:locked]})
                |> Ash.update(actor: actor)
              else
                Cgc2046.Initiatives.InitiativeRule
                |> Ash.Changeset.for_create(:create, %{
                  initiative_id: args[:initiative_id],
                  key: key,
                  value: value,
                  locked: args[:locked]
                })
                |> Ash.create(actor: actor)
              end

            case result do
              {:ok, rule} ->
                {:ok, %{result: admin_rule_row(rule), errors: []}}

              {:error, error} ->
                {:ok,
                 %{
                   result: nil,
                   errors:
                     mutation_errors(
                       error,
                       context,
                       :update,
                       Cgc2046.Initiatives.InitiativeRule,
                       Cgc2046.Initiatives
                     )
                 }}
            end
          else
            {:error, error} when is_exception(error) ->
              {:ok,
               %{
                 result: nil,
                 errors:
                   mutation_errors(
                     error,
                     context,
                     :read,
                     Cgc2046.Initiatives.InitiativeRule,
                     Cgc2046.Initiatives
                   )
               }}

            {:error, message} when is_binary(message) ->
              {:ok, %{result: nil, errors: [%{message: message, code: "invalid_input"}]}}
          end
        end)
      end)
    end

    field :assign_event_moderator, :event_moderator_payload do
      arg(:workspace_id, non_null(:id))
      arg(:event_id, non_null(:id))

      # #537：锚语义放宽（域层 resolve 后落 UUID，存储不变）。ID 标量对
      # email / CGC 编号原样放行（string 标量，无格式校验）。
      arg(:user_id, non_null(:id), description: "被指派用户锚：邮箱 / CGC 编号 / 用户 ID 任一精确匹配")

      resolve(fn _, args, %{context: context} ->
        with_actor(context, fn actor ->
          case Cgc2046.Events.Moderators.assign(
                 args[:event_id],
                 args[:workspace_id],
                 args[:user_id],
                 actor
               ) do
            {:ok, record} ->
              {:ok, %{result: record, errors: []}}

            {:error, :forbidden} ->
              {:ok, %{result: nil, errors: [%{message: "forbidden", code: "forbidden"}]}}

            {:error, %Ash.Error.Invalid{} = error} ->
              {:ok,
               %{
                 result: nil,
                 errors:
                   mutation_errors(
                     error,
                     context,
                     :create,
                     Cgc2046.Events.EventModerator,
                     Cgc2046.Events
                   )
               }}

            # #537 三锚点解析错误（user_not_found / user_anchor_ambiguous）：
            # 域函数直返的 BusinessError 不在 Ash.Error.Invalid 容器里，单独
            # 映射进 payload errors——code 直达前端 i18n（graphql_schema.ex
            # 顶层 {:error, message:, code:} 同款先例）。
            {:error, %Cgc2046.Errors.BusinessError{code: code, message: message}} ->
              {:ok, %{result: nil, errors: [%{message: message, code: code}]}}

            {:error, _} ->
              {:ok,
               %{result: nil, errors: [%{message: "failed to assign moderator", code: "invalid"}]}}
          end
        end)
      end)
    end

    field :remove_event_moderator, :event_moderator_payload do
      arg(:workspace_id, non_null(:id))
      arg(:moderator_id, non_null(:id))

      resolve(fn _, args, %{context: context} ->
        with_actor(context, fn actor ->
          case Cgc2046.Events.Moderators.remove(args[:moderator_id], args[:workspace_id], actor) do
            :ok ->
              {:ok, %{result: nil, errors: []}}

            {:error, :forbidden} ->
              {:ok, %{result: nil, errors: [%{message: "forbidden", code: "forbidden"}]}}

            {:error, _} ->
              {:ok,
               %{result: nil, errors: [%{message: "moderator not found", code: "not_found"}]}}
          end
        end)
      end)
    end

    # 押金核销（U5/KTD4；R6、R11）：主理人 / Owner·Admin / 平台管理员按 6 位核销码
    # 核销 confirmed 报名的到场。授权与「码无效 / 已核销」判定全在域层
    # （Admission.Attendance policy + before_action），本 resolver 只做
    # actor 门控与 payload 形状映射（同 assign_event_moderator 先例）。
    field :check_in_enrollment, :check_in_enrollment_payload do
      arg(:event_id, non_null(:id))
      arg(:code, non_null(:string), description: "6 位核销码（扫码 URL 预填或手输）")
      arg(:method, non_null(:string), description: "核销方式：scan | manual")

      resolve(fn _, args, %{context: context} ->
        with_actor(context, fn actor ->
          case Cgc2046.Admission.Attendance.check_in(
                 args[:event_id],
                 args[:code],
                 args[:method],
                 actor
               ) do
            {:ok, attendance} ->
              {:ok,
               %{
                 enrollment_id: attendance.enrollment_id,
                 checked_in_at: attendance.checked_in_at,
                 method: to_string(attendance.method),
                 deposit_refund: deposit_refund_state(attendance.enrollment_id),
                 errors: []
               }}

            {:error, error} ->
              {:ok,
               %{
                 enrollment_id: nil,
                 checked_in_at: nil,
                 method: nil,
                 deposit_refund: nil,
                 errors:
                   to_ash_graphql_errors(
                     error,
                     context,
                     :check_in,
                     Cgc2046.Admission.Attendance,
                     Cgc2046.Admission
                   )
               }}
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
    # calculation 字段（target_title/starts_at/venue）：手写 object
    # （generate_object? false）不挂 AshGraphql 的 resolve_calculation，默认
    # MapGet 只读原字段——alias 查询时值落在
    # calculations[{:__ash_graphql_calculation__, alias}] 而原字段保持
    # NotLoaded，DateTime 序列化直接崩溃（review F5，存量 target_title
    # 同类一并修）。alias 感知 resolve：alias 时读 AshGraphql 的加载槽，
    # 无 alias 时 calculations map 优先、原字段兜底（Ash 双写）。
    field(:target_title, :string) do
      resolve(fn parent, _args, %{definition: definition} ->
        {:ok, enrollment_calc_value(parent, definition, :target_title)}
      end)
    end

    # 日程化旅程 P2a：目标供给物的开始时间与场地文本（无则 null）
    field(:starts_at, :datetime) do
      resolve(fn parent, _args, %{definition: definition} ->
        {:ok, enrollment_calc_value(parent, definition, :starts_at)}
      end)
    end

    field(:venue, :string) do
      resolve(fn parent, _args, %{definition: definition} ->
        {:ok, enrollment_calc_value(parent, definition, :venue)}
      end)
    end

    # U2：目标报名截止（同 starts_at/venue 的 alias 感知 calculation resolve）
    field(:registration_deadline, :datetime) do
      resolve(fn parent, _args, %{definition: definition} ->
        {:ok, enrollment_calc_value(parent, definition, :registration_deadline)}
      end)
    end

    # U3：目标缴费模式 free/pricing/deposit（码卡与取消规则的模式感知文案用）
    field(:payment_mode, :string) do
      resolve(fn parent, _args, %{definition: definition} ->
        {:ok, enrollment_calc_value(parent, definition, :payment_mode)}
      end)
    end

    # 押金快照金额（#696）：报名提交时物化的 submission_payload 键，与 createOrder
    # 押金单实付金额同源——/orders/new 披露行的金额源；定价/免费报名 nil（展示面
    # 走「金额待定」，绝不 ¥0）。
    field(:deposit_amount_cents, :integer) do
      resolve(fn parent, _args, %{definition: definition} ->
        {:ok, enrollment_calc_value(parent, definition, :deposit_amount_cents)}
      end)
    end

    # KTD5 出示门控：仅 actor 即报名人且报名 confirmed 才返回核销码，其余
    # （pending/payment_pending/终态/Owner/Admin/PlatformAdmin/匿名）一律 null。
    # Enrollment read policy 允许 Owner/Admin/PlatformAdmin 读列表，policy 层
    # 不能承担字段可见性——字段级 resolve 门控是唯一闸。parent 双形态：
    # myEnrollment 白名单 payload map / Ash record。
    field(:check_in_code, :string, description: "6 位核销码（仅本人 confirmed 报名可见；course 报名恒 null）") do
      resolve(fn parent, _args, %{context: context} ->
        with_actor(
          context,
          fn actor ->
            {:ok,
             if check_in_code_visible?(parent, actor) do
               enrollment_value(parent, :check_in_code)
             end}
          end,
          on_nil: fn _context -> {:ok, nil} end
        )
      end)
    end
  end

  # U7(#180/KD8):issue 级进度,旧 manual-steps 字段(completedManualSteps/
  # totalManualSteps/currentStepTitle)与 manual_steps_compat 派生已删——
  # 直接替换不留兼容层(AGENTS.md);currentIssueId 供抽屉/扩展联动。
  # S8（ADR-0011）：objective 口径（RunProjection 薄壳 Runs.learning_state）
  object :my_learning_run do
    field(:run_id, non_null(:id))
    field(:enrollment_id, non_null(:id))
    field(:target_title, :string)
    field(:status, non_null(:string))
    field(:stale_revision, non_null(:boolean))
    field(:progress, non_null(:learning_progress))
    field(:next_action, :learning_next_action)
    field(:course_id, non_null(:id))
  end

  # U7(#180/R11)→S8（ADR-0011）：学员视角课程学习详情（objective 口径，
  # Runs.learning_state 薄壳）。与公开地图（issue_map, goal-only）不同面，
  # 本查询仅登录 actor 本人可见（恒 actor,无他人视角）。
  # S8（ADR-0011）：objective 口径学习详情（Runs.learning_state 薄壳投影）。
  # 破坏性变更有意（登录面一次性切换）：issue/checklist/story 学习语义删除。
  object :course_learning_detail do
    field(:course_id, non_null(:id))
    field(:title, non_null(:string))
    field(:slug, :string)
    field(:run, :learning_run_summary)
    field(:revision_number, :integer)
    field(:stale_revision, non_null(:boolean))
    field(:review_queue, non_null(list_of(non_null(:learning_review_queue_entry))))
    field(:objectives, non_null(list_of(non_null(:learning_objective_state))))
    field(:next_action, :learning_next_action)
    field(:progress, :learning_progress)
  end

  # S9（R45）：复习到期队列（needs_review 恒立即到期 / 里程碑按序消费）
  object :learning_review_queue_entry do
    field(:objective_id, non_null(:string))
    field(:due_at, non_null(:datetime))
    field(:milestone_days, :integer)
    field(:needs_review, non_null(:boolean))
  end

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

  object :course_content do
    field(:course_id, non_null(:id))
    field(:title, non_null(:string))
    field(:description, :string)
    field(:revision_number, :integer)
    field(:published_at, :datetime)
    field(:content, non_null(:json_string))
  end

  object :course_draft do
    field(:course_id, non_null(:id))
    field(:title, non_null(:string))
    field(:version, :integer)
    field(:prep_state, :string)
    field(:updated_at, :datetime)
    field(:content, :json_string)
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

  object :course_learning_analytics do
    field(:run_stats, non_null(:course_learning_run_stats))
    field(:objectives, non_null(list_of(non_null(:course_learning_objective_stats))))
    field(:drop_off, non_null(:course_learning_drop_off))
    field(:generated_at, non_null(:datetime))
  end

  object :course_learning_run_stats do
    field(:total_runs, non_null(:integer))
    field(:active_runs, non_null(:integer))
    field(:completed_runs, non_null(:integer))
    field(:completion_rate, :float)
  end

  object :course_learning_objective_stats do
    field(:objective_id, non_null(:string))
    field(:title, non_null(:string))
    field(:required, non_null(:boolean))
    field(:mastered, non_null(:integer))
    field(:developing, non_null(:integer))
    field(:needs_review, non_null(:integer))
    field(:unassessed, non_null(:integer))
    field(:total_attempts, non_null(:integer))
    field(:qualifying_passes, non_null(:integer))
    field(:low_confidence_attempts, non_null(:integer))
    field(:pass_rate, :float)
    field(:last_activity_at, :datetime)
  end

  object :course_learning_drop_off do
    field(:stale_run_count, non_null(:integer))
  end

  object :learning_run_summary do
    field(:id, non_null(:id))
    field(:status, non_null(:string))
    field(:revision_id, :id)
    field(:revision_number, :integer)
  end

  # objective id/title 非全局唯一（课程内容内字符串 id）——Apollo 缓存必须
  # keyFields: false（§B#22，跨课程/跨 run 串掌握态事故先例）
  object :learning_objective_state do
    field(:id, non_null(:string))
    field(:title, non_null(:string))
    field(:required, non_null(:boolean))
    field(:issue_id, :string)
    field(:prereq_ids, non_null(list_of(non_null(:string))))
    field(:mastery, non_null(:string))
    field(:ever_mastered, non_null(:boolean))
    field(:locked, non_null(:boolean))
    field(:missing_prereq_ids, non_null(list_of(non_null(:learning_prereq_ref))))
    field(:attempt_count, non_null(:integer))
    field(:last_attempt_at, :datetime)
  end

  object :learning_prereq_ref do
    field(:id, non_null(:string))
    field(:title, :string)
  end

  object :learning_next_action do
    field(:kind, non_null(:string))
    field(:objective_id, non_null(:string))
    field(:reason, non_null(:string))
  end

  # S8：objective 口径（mastered_required/total_required/complete；R39 完成
  # = 必修全 ever_mastered，needs_review 不倒退）
  object :learning_progress do
    field(:mastered_required, non_null(:integer))
    field(:total_required, non_null(:integer))
    field(:complete, non_null(:boolean))
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
    value(:register)
    value(:change_phone)
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

  @desc "手机号注册结果（email 可空——无邮箱手机号用户，同 phone code 登录 result）"
  object :sign_up_with_phone_user do
    field(:id, non_null(:id))
    field(:email, :string)
    field(:is_platform_admin, non_null(:boolean))
  end

  object :sign_up_with_phone_payload do
    field(:result, :sign_up_with_phone_user)
    field(:errors, list_of(:mutation_error))
  end

  input_object :sign_up_with_phone_input do
    field(:phone, non_null(:string))
    field(:code, non_null(:string))
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

  # ── 高风险支付操作两段确认（web 面；payload 式错误同 accept_invitation_result 先例）──

  object :pending_operation_confirmation do
    @desc "refundOrder/retryRefund/waivePayment 第一段返回：pendingId + 后端生成的确认摘要；errors 为业务错误（未建 pending）"
    field(:pending_id, :id)
    field(:summary, :string)
    field(:errors, non_null(list_of(non_null(:mutation_error))))
  end

  object :operation_resolution do
    @desc "confirmOperation/cancelOperation 返回：status = confirmed | cancelled；errors 为业务错误"
    field(:pending_id, :id)
    field(:status, :string)
    field(:errors, non_null(list_of(non_null(:mutation_error))))
  end

  # ── SpeakerInvitation（E-4 #49；record 类型由 AshGraphql 自动生成 :speaker_invitation，
  # 此处只定义卡片/输入/payload 类型；token_hash 已 hide_fields）──

  object :speaker_invitation_card do
    @desc "token 公开卡片：邀请主题/时间 + Event 公开信息（D2 白名单，不泄露其它邀请）"
    field(:status, non_null(:string))
    field(:topic, :string)
    field(:scheduled_at, :datetime)

    @desc "当前登录用户是否为发出人（匿名为 false；不泄露 invitedBy）"
    field(:viewer_is_inviter, non_null(:boolean))
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

  object :resend_speaker_invitation_payload do
    @desc "resendSpeakerInvitation 返回：result 为邀请记录；plainToken 新明文仅此一次"
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

  # Ash action 错误 → AshGraphql.Error 结构化顶层 error（message/code/fields）。
  # 复用 AshGraphql.Errors.to_errors（自动生成 mutation 同款映射），与 sign_up 的
  # 错误协议一致；只取最小形状字段，避免 vars/short_message 等内部字段进响应。
  # domain 默认 Accounts（历史调用方均属此域）；其它域的资源（如 Cgc2046.Mcp.Token）须显式传入。
  defp to_ash_graphql_errors(
         error,
         context,
         action,
         resource \\ Cgc2046.Accounts.User,
         domain \\ Cgc2046.Accounts
       ) do
    error
    |> AshGraphql.Errors.to_errors(context, domain, resource, action)
    |> Enum.map(fn mapped ->
      mapped
      |> Map.take([:message, :code])
      |> Map.put(:fields, format_error_fields(mapped[:fields]))
    end)
  end

  # `MutationError.fields` 是 SDL 的 `[String!]`；域层 fields 允许两种形态：
  # 裸字段名（atom，如 `:pricing_enabled`）与 `{字段名, 值}`（如
  # `event_id: <uuid>`，见 RuleInheritance.pricing_conflict_error/1）。值可能是
  # 裸 SQL 行里的原始 16 字节 UUID（非 canonical 字符串），直接进 `[String!]`
  # 会在 Absinthe 序列化处炸，故统一规范化成 `name` / `name=value` 字符串
  # （#595 D4a：fields 语义 = name=value，前端按 `event_id=<uuid>` 反查挂载场）。
  defp format_error_fields(nil), do: []

  defp format_error_fields(fields) when is_list(fields),
    do: fields |> Enum.map(&format_error_field/1) |> Enum.reject(&is_nil/1)

  defp format_error_fields(field), do: format_error_fields([field])

  defp format_error_field({name, value}),
    do: "#{format_error_field_name(name)}=#{format_error_value(value)}"

  defp format_error_field(name) when is_atom(name), do: format_error_field_name(name)
  # 裸值也走 format_error_value/1：16 字节 binary 同样要规范化成 canonical UUID，
  # 否则裸值形态会绕过规范化、以非法 UTF-8 进 `[String!]`（F7）。
  defp format_error_field(value) when is_binary(value), do: format_error_value(value)

  # 无法识别的形态（map / 三元组 / 数字 …）不塞进 `[String!]`，但也不能静默丢：
  # 丢了等于 #595 刚建立的「拒绝路径可定位」在下一个新错误形态上无声退化（A4）。
  defp format_error_field(other) do
    Logger.warning("[graphql] dropped unrecognized error field shape: #{inspect(other)}")
    nil
  end

  defp format_error_field_name(name) when is_atom(name), do: Atom.to_string(name)
  defp format_error_field_name(name) when is_binary(name), do: name
  defp format_error_field_name(name), do: inspect(name)

  defp format_error_value(<<_::128>> = raw), do: Ecto.UUID.load!(raw)
  defp format_error_value(value) when is_binary(value), do: value
  defp format_error_value(value) when is_atom(value), do: Atom.to_string(value)
  defp format_error_value(value) when is_integer(value), do: Integer.to_string(value)
  defp format_error_value(value), do: inspect(value)

  # 两段确认第一段结果 → pending_operation_confirmation payload：业务错误进
  # payload errors（与自动 mutation 同通道，前端按 code 查文案），不抛顶层 error
  defp pending_confirmation_payload({:ok, %{pending_id: pending_id, summary: summary}}),
    do: {:ok, %{pending_id: pending_id, summary: summary, errors: []}}

  defp pending_confirmation_payload({:error, %{message: message, code: code}}),
    do: {:ok, %{pending_id: nil, summary: nil, errors: [mutation_error_payload(message, code)]}}

  # 手写 payload 的最小 mutation_error 形状（decide_speaker_invitation 同款先例）
  defp mutation_error_payload(message, code), do: %{message: message, code: code}

  # SpeakerInvitation 决策（accept/decline）的 SDL adapter：领域编排在
  # `Events.SpeakerInvitation.decide/3`（token 即凭据定位 + action 复验）；
  # 此处只映射 payload 形状——无效 token 与已用/过期同形返回 payload errors
  # （不防枚举），未登录走 unauthorized 顶层 error。
  defp decide_speaker_invitation(%{context: context}, token, action) do
    case Cgc2046.Events.SpeakerInvitation.decide(context[:actor], token, action) do
      {:ok, invitation} ->
        {:ok, %{result: invitation, errors: []}}

      {:error, :unauthorized} ->
        {:error, unauthorized_error()}

      {:error, :invalid_token} ->
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

      {:error, error} ->
        speaker_invitation_action_result({:error, error}, context, action)
    end
  end

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
           Cgc2046.Events
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
           domain: Cgc2046.Accounts
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

  # #116 R10a：治理操作留痕（actor_id 可空 = 系统/CLI）
  object :admin_action_log do
    field(:id, non_null(:id))
    field(:actor_id, :id)
    field(:action, non_null(:string))
    field(:target_type, non_null(:string))
    field(:target_id, non_null(:id))
    field(:result, non_null(:string))
    field(:inserted_at, non_null(:datetime))

    field(:metadata, :admin_action_metadata,
      description:
        "治理 metadata 白名单投影（#607）；未收录的 action 或形状不完整的历史行（#587 之前）" <>
          "为 null（不整列透传，且行级降级不打挂列表）。raw metadata 仅 /ops/admin（AshAdmin）可见"
    ) do
      # 显式 resolver：默认 resolver 会直接读 `log.metadata` 原始列（透传），必须挡掉
      resolve(fn log, _, _ -> {:ok, admin_action_metadata(log)} end)
    end

    field(:offering_change, :admin_offering_change_metadata,
      description:
        "offering 治理写的变更投影（U1）：admin_event_update / admin_course_update 落表的行才有值，" <>
          "其余 action（含 launch/close/cancel）为 null。闭集标量的前后值分列，不收自由文本"
    ) do
      resolve(fn log, _, _ -> {:ok, admin_offering_change_metadata(log)} end)
    end
  end

  # #607：metadata 白名单投影（非原始 metadata 列）。白名单表见模块顶部
  # `@admin_action_metadata_whitelist` / `@rule_value_whitelist`。
  # `value_*_json` 是 JSON 对象字符串，键序 = 二级白名单次序（前端直接按序渲染）。
  object :admin_action_metadata do
    field(:rule_key, non_null(:string),
      description: "规则键：deposit | age_gate | min_participants | deadline_rule"
    )

    field(:locked, non_null(:boolean), description: "变更后锁定态")

    field(:locked_before, :boolean, description: "变更前锁定态；:create（新建规则）无前值 → null")

    field(:value_before_json, :json_string,
      description: "变更前规则值 JSON 对象字符串；:create 无前值 → null（null ⇔ 新建）"
    )

    field(:value_after_json, non_null(:json_string),
      description: "变更后规则值 JSON 对象字符串（有投影 ⇒ 该侧必在；形状不全的行整行不投影）"
    )

    field(:value_before_omitted, non_null(:boolean),
      description: "true = 变更前 value 含白名单外键，已被省略（界面以 … 标出）"
    )

    field(:value_after_omitted, non_null(:boolean),
      description: "true = 变更后 value 含白名单外键，已被省略（界面以 … 标出）"
    )
  end

  # U1：offering 治理写的变更投影（闭集标量前后值分列，非 rule 族 JSON 槽）。
  # 白名单表见模块顶部 `@admin_offering_change_metadata_whitelist`；Course 行无
  # deposit 两列（该资源无此属性）。全列可空——读者从「哪些列有值」看变更面。
  object :admin_offering_change_metadata do
    description("offering 治理写（admin_event_update / admin_course_update）的变更前后值投影")

    field(:title_before, :string, description: "变更前标题；该属性未变更 → null")
    field(:title_after, :string, description: "变更后标题；该属性未变更 → null")
    field(:visibility_before, :string, description: "变更前可见性（public | workspace）")
    field(:visibility_after, :string, description: "变更后可见性（public | workspace）")
    field(:capacity_before, :integer, description: "变更前报名名额上限；nil 表示不限")
    field(:capacity_after, :integer, description: "变更后报名名额上限；nil 表示不限")
    field(:pricing_enabled_before, :boolean, description: "变更前定价槽位")
    field(:pricing_enabled_after, :boolean, description: "变更后定价槽位")
    field(:deposit_enabled_before, :boolean, description: "变更前押金槽位（Event-only；Course 恒 null）")
    field(:deposit_enabled_after, :boolean, description: "变更后押金槽位（Event-only；Course 恒 null）")
  end

  # U2 治理读面：offering（Event / Course）行与详情两组投影（KTD3/KTD4）——
  #   行（admin_event / admin_course）：listAdminEvents / listAdminCourses 用。
  #     跨租户定位与生命周期按钮所需的最小集（带 workspace_id，前端用既有
  #     workspaces 数据映射名称）；**不带报名计数**——计数需要按场现取，属于
  #     开弹窗/展开详情那一次取数（KTD4）。
  #   详情（admin_event_detail / admin_course_detail）：get 查询用 = 行字段 +
  #     处置与排查字段（权威报名计数、主理人、挂载来源标记 / 版本指针）。
  object :admin_event do
    field(:id, non_null(:id))
    field(:workspace_id, non_null(:id))
    field(:title, non_null(:string))
    field(:slug, :string)
    field(:status, non_null(:string), description: "draft | open | closed | cancelled")
    field(:visibility, non_null(:string), description: "public | workspace")
    field(:capacity, :integer, description: "报名名额上限；nil 表示不限")
    field(:registration_deadline, :datetime)
    field(:starts_at, :datetime)
    field(:ends_at, :datetime)
    field(:pricing_enabled, non_null(:boolean))
    field(:deposit_enabled, non_null(:boolean))
    field(:deposit_amount_cents, :integer)
    field(:inserted_at, non_null(:datetime))
    field(:updated_at, non_null(:datetime))
  end

  object :admin_event_detail do
    field(:id, non_null(:id))
    field(:workspace_id, non_null(:id))
    field(:title, non_null(:string))
    field(:slug, :string)
    field(:description, :string)
    field(:status, non_null(:string), description: "draft | open | closed | cancelled")
    field(:visibility, non_null(:string), description: "public | workspace")
    field(:capacity, :integer, description: "报名名额上限；nil 表示不限")
    field(:registration_deadline, :datetime)
    field(:starts_at, :datetime)
    field(:ends_at, :datetime)
    @desc "结构化场地 JSON 串（country/province/city/district；nil = 线上或未定）"
    field(:venue, :json_string)
    field(:pricing_enabled, non_null(:boolean))
    field(:deposit_enabled, non_null(:boolean))
    field(:deposit_amount_cents, :integer)

    @desc """
    权威已确认报名笔数（KTD4：按本场现取 `Enrollment.status == confirmed` 行数，
    不读 events.confirmed_count 展示投影——该列自述可能滞后一拍）。
    nil = 计数不可用（现取失败）；界面必须按不可用态呈现并禁用依赖它的入口，
    不得当 0。0 表示真实无已确认报名（免费场零计数）。
    """
    field(:confirmed_count, :integer)

    @desc """
    权威待付报名笔数（KTD4：`Enrollment.status == payment_pending` 行数）。
    关定价/关押金槽位的后果披露与 200 笔批量免缴上限判定都以此数为准；nil 语义
    同 confirmedCount（不可用，非 0）。
    """
    field(:payment_pending_count, :integer)

    @desc "主理人清单（平台管理员读面不要求本台成员身份）；nil = 清单加载失败（不阻断详情主读）"
    field(:moderators, list_of(non_null(:event_moderator)))

    @desc "解除挂载来源标记 JSON（事件被 detach 后仍留在场上的锁死值来自哪个 Initiative）；nil = 无标记。公开面不暴露（治理详情专属）"
    field(:detached_rule_provenance, :json_string)

    field(:inserted_at, non_null(:datetime))
    field(:updated_at, non_null(:datetime))
  end

  object :admin_course do
    field(:id, non_null(:id))
    field(:workspace_id, non_null(:id))
    field(:title, non_null(:string))
    @desc "标题是否为系统生成的临时占位（未命名课程）；发布前置门，治理列表据此标黄"
    field(:provisional_title, non_null(:boolean))
    field(:slug, :string)
    field(:status, non_null(:string), description: "draft | open | closed | cancelled")
    field(:visibility, non_null(:string), description: "public | workspace")
    field(:capacity, :integer, description: "报名名额上限；nil 表示不限")
    field(:registration_deadline, :datetime)
    field(:starts_at, :datetime)
    field(:ends_at, :datetime)
    field(:pricing_enabled, non_null(:boolean))
    field(:inserted_at, non_null(:datetime))
    field(:updated_at, non_null(:datetime))
  end

  object :admin_course_detail do
    field(:id, non_null(:id))
    field(:workspace_id, non_null(:id))
    field(:title, non_null(:string))
    @desc "标题是否为系统生成的临时占位（未命名课程）；发布前置门，治理列表据此标黄"
    field(:provisional_title, non_null(:boolean))
    field(:slug, :string)
    field(:description, :string)
    field(:status, non_null(:string), description: "draft | open | closed | cancelled")
    field(:visibility, non_null(:string), description: "public | workspace")
    field(:capacity, :integer, description: "报名名额上限；nil 表示不限")
    field(:registration_deadline, :datetime)
    field(:starts_at, :datetime)
    field(:ends_at, :datetime)
    field(:pricing_enabled, non_null(:boolean))

    @desc """
    权威已确认报名笔数（KTD4：按本课现取 `Enrollment.status == confirmed` 行数，
    不读 courses.confirmed_count 展示投影）。nil = 计数不可用（现取失败），
    不得当 0；0 表示真实无已确认报名。
    """
    field(:confirmed_count, :integer)

    @desc "权威待付报名笔数（KTD4：`Enrollment.status == payment_pending` 行数）；nil 语义同 confirmedCount"
    field(:payment_pending_count, :integer)

    field(:inserted_at, non_null(:datetime))
    field(:updated_at, non_null(:datetime))
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

  object :admin_initiative do
    field(:id, non_null(:id))
    field(:name, non_null(:string))
    field(:slug, non_null(:string))
    field(:hashtag, :string)
    field(:description, :string)
    field(:window_starts_at, :datetime)
    field(:window_ends_at, :datetime)
    field(:status, non_null(:string))
    field(:created_by, non_null(:id))
    field(:inserted_at, non_null(:datetime))
    field(:updated_at, non_null(:datetime))

    field :public_stats, :public_initiative do
      resolve(fn initiative, _, _ ->
        case Cgc2046.Initiatives.Public.get_by_slug(initiative.slug) do
          {:ok, stats} -> {:ok, stats}
          _ -> {:ok, nil}
        end
      end)
    end

    field(:rules, non_null(list_of(non_null(:admin_initiative_rule))))

    @desc """
    平台管理员：该 Initiative 的挂载场全量清单（#595 影响预览 / 事后核对）。

    门控继承父 query（listInitiatives / getInitiative 均经 with_admin），
    不加独立 gate；不分页、不过滤 visibility，理由见
    Cgc2046.Initiatives.Mounts 的 moduledoc。

    附挂读面：可空。加载失败返回 nil（并落日志），不阻断规则的详情主读——
    同 public_stats 先例（附挂信息不阻断主读）；前端据此区分「空清单」与
    「清单加载失败」两种状态，不把失败伪装成 0 场。
    """
    field :mounted_events, list_of(non_null(:admin_initiative_mounted_event)) do
      resolve(fn initiative, _, _ ->
        case Cgc2046.Initiatives.Mounts.list(initiative.id) do
          {:ok, rows} ->
            {:ok, rows}

          {:error, reason} ->
            Logger.error("[admin_initiative.mountedEvents] load failed: #{inspect(reason)}")
            {:ok, nil}
        end
      end)
    end
  end

  object :admin_initiative_mounted_event do
    @desc "Event / Workspace id 与 Initiative 真值一致；status ∈ draft | open | closed | cancelled"
    field(:id, non_null(:id))
    field(:initiative_id, non_null(:id))
    field(:slug, non_null(:string))
    field(:title, non_null(:string))
    field(:status, non_null(:string))
    field(:starts_at, :datetime)
    field(:registration_deadline, :datetime)
    @desc "结构化场地 JSON 串（country/province/city/district；nil = 线上或未定）"
    field(:venue, :json_string)
    field(:workspace_id, non_null(:id))
    field(:workspace_name, non_null(:string))
    @desc "展示投影 events.confirmed_count（权威计数在名额账本，可能滞后一拍）"
    field(:confirmed_count, non_null(:integer))
    field(:pricing_enabled, non_null(:boolean))
    field(:deposit_enabled, non_null(:boolean))
    field(:deposit_amount_cents, :integer)
    field(:min_age, :integer)
    field(:min_participants, :integer)
  end

  object :admin_initiative_rule do
    field(:id, non_null(:id))
    field(:initiative_id, non_null(:id))
    field(:key, non_null(:string))
    field(:value_json, non_null(:string))
    field(:locked, non_null(:boolean))
    field(:inserted_at, non_null(:datetime))
    field(:updated_at, non_null(:datetime))
  end

  object :initiative_mount_preview do
    field(:initiative_id, non_null(:id))
    field(:name, non_null(:string))
    field(:slug, non_null(:string))
    field(:status, non_null(:string))
    field(:rules, non_null(list_of(non_null(:initiative_rule_preview))))
    field(:missing_rules, non_null(list_of(non_null(:string))))
  end

  # value_json 与 AdminInitiativeRule 同口径（JSON 字符串 + locked 布尔）：
  # 手写客户端复用既有 JSON.parse(rule.valueJson) 解析模式
  object :initiative_rule_preview do
    field(:key, non_null(:string))
    field(:value_json, non_null(:string))
    field(:locked, non_null(:boolean))
  end

  input_object :admin_initiative_input do
    field(:name, :string)
    field(:slug, :string)
    field(:hashtag, :string)
    field(:description, :string)
    field(:window_starts_at, :datetime)
    field(:window_ends_at, :datetime)
  end

  # U1 治理 update 输入（键集 = `@admin_event_update_fields` / `@admin_course_update_fields`；
  # 未提供的字段不落 changeset——map_input/2 只取存在的键）
  input_object :admin_event_update_input do
    field(:title, :string)
    field(:slug, :string)
    field(:description, :string)
    field(:visibility, :string)
    field(:capacity, :integer)
    field(:registration_deadline, :datetime)
    field(:starts_at, :datetime)
    field(:ends_at, :datetime)
    field(:venue, :json_string)
    field(:pricing_enabled, :boolean)
    field(:deposit_enabled, :boolean)
  end

  input_object :admin_course_update_input do
    field(:title, :string)
    field(:slug, :string)
    field(:description, :string)
    field(:visibility, :string)
    field(:capacity, :integer)
    field(:registration_deadline, :datetime)
    field(:starts_at, :datetime)
    field(:ends_at, :datetime)
    field(:pricing_enabled, :boolean)
  end

  object :admin_initiative_payload do
    field(:result, :admin_initiative)
    field(:errors, list_of(:mutation_error))
  end

  # U1：治理写 payload 回**资源本体**（Event/Course 既有 GraphQL 类型）——前端
  # 写成功后即可就地更新行，亦可按 KTD4 单一取数契约重取治理投影。
  object :admin_event_payload do
    description("治理写（Event）结果信封：result + errors，形状同 adminInitiativePayload")

    field(:result, :event)
    field(:errors, list_of(:mutation_error))
  end

  object :admin_course_payload do
    description("治理写（Course）结果信封：result + errors，形状同 adminInitiativePayload")

    field(:result, :course)
    field(:errors, list_of(:mutation_error))
  end

  object :admin_initiative_rule_payload do
    field(:result, :admin_initiative_rule)
    field(:errors, list_of(:mutation_error))
  end

  # #537 回显平铺：displayName → memberNumber fallback 链的数据面（nullable；
  # member_number 由 uuid 确定性现算恒非空，display_name 可空）
  object :event_moderator do
    field(:id, non_null(:id))
    field(:workspace_id, non_null(:id))
    field(:event_id, non_null(:id))
    field(:user_id, non_null(:id))
    field(:assigned_by, :id)
    field(:assigned_at, non_null(:datetime))
    field(:user_display_name, :string)
    field(:user_member_number, :string)
    field(:assigned_by_display_name, :string)
    field(:assigned_by_member_number, :string)
  end

  object :event_moderator_payload do
    field(:result, :event_moderator)
    field(:errors, list_of(:mutation_error))
  end

  # U5/KTD4 核销 payload：成功返回到场事实（enrollment_id / checked_in_at / method），
  # 失败（码无效 / 已核销）三者皆为 null 且 errors 携带领域 code（前端按 code 查文案）。
  # 退款侧状态（押金已发起 / 已在退还中 / 已退，KTD6 分派）随 U6 落地后在此扩展。
  object :check_in_enrollment_payload do
    @desc "被核销的报名（失败为 null）"
    field(:enrollment_id, :id)

    @desc "核销时间（失败为 null）"
    field(:checked_in_at, :datetime)

    @desc "核销方式：scan / manual（失败为 null）"
    field(:method, :string)

    @desc """
    本次核销的押金退款侧事实（KTD6），成功路径只可能返回：
    - null：该报名没有押金单（免费/定价场报名，或押金制之前建的存量报名）→ 本次核销不产生退款；
    - refunding：本次核销已发起全额退款，或押金已在退还中（幂等重入不重复退；refund_failed 归一为 refunding）；
    - refunded：押金已退。
    forfeited 不会出现在成功路径——押金已没收时核销本身失败，走 errors 的 deposit_already_forfeited。
    前端据此决定是否显示「押金退款已发起」，不再只看事件是不是押金场。
    """
    field(:deposit_refund, :string)

    field(:errors, list_of(:mutation_error))
  end

  object :public_initiative do
    field(:id, non_null(:id))
    field(:name, non_null(:string))
    field(:slug, non_null(:string))
    field(:hashtag, :string)
    field(:description, :string)
    field(:window_starts_at, :datetime)
    field(:window_ends_at, :datetime)
    field(:status, non_null(:string))
    field(:city_count, non_null(:integer))
    field(:event_count, non_null(:integer))
    field(:confirmed_count, non_null(:integer))
    field(:qualified_event_count, non_null(:integer))
    field(:cities, non_null(list_of(non_null(:public_initiative_city))))
  end

  object :public_initiative_card do
    field(:id, non_null(:id))
    field(:name, non_null(:string))
    field(:slug, non_null(:string))
    field(:hashtag, :string)
    field(:description, :string)
    field(:window_starts_at, :datetime)
    field(:window_ends_at, :datetime)
    field(:status, non_null(:string))
  end

  object :public_initiative_city do
    field(:city, non_null(:string))
    field(:events, non_null(list_of(non_null(:public_initiative_event))))
  end

  object :public_initiative_event do
    field(:id, non_null(:id))
    field(:slug, non_null(:string))
    field(:title, non_null(:string))
    field(:status, non_null(:string))
    field(:visibility, non_null(:string))
    field(:starts_at, :datetime)
    field(:ends_at, :datetime)
    field(:registration_deadline, :datetime)
    field(:venue, :json_string)
    field(:confirmed_count, non_null(:integer))
    field(:min_participants, :integer)
    field(:qualification_status, :string)
    field(:archived, non_null(:boolean))
    field(:qualification_badge, non_null(:string))
    field(:short_by, :integer)

    # 参与条件披露（#627）：缴费槽三态 + 押金明细 + 年龄门槛存在性 + 收费金额锚。
    # 全部来自 Event 已物化快照列（`Initiatives.Public` 的裸 SQL 投影），不暴露规则表。
    field(:payment_mode, non_null(:string))
    field(:deposit, non_null(:public_initiative_deposit))
    field(:min_age, :integer)
    field(:price_range_min_cents, :integer)
  end

  @desc "公开页押金明细（#627）：金额缺失/非正时 amountCents 为 null，enabled 仍 true——绝不显示 ¥0"
  object :public_initiative_deposit do
    field(:enabled, non_null(:boolean))
    field(:amount_cents, :integer)
    field(:refundable_on_check_in, :boolean)
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

  # #355 P1-3：myEnrollment 解析。kind 白名单解析（event | course）后委托
  # Enrollment 活跃报名共享读取面；读取失败按无报名降级（附挂信息不阻断详情
  # 主读，与 MCP discover_offerings 同纪律）。status 原子显式 to_string——
  # 手写 :enrollment object 无 ash_graphql 生成查询的枚举转换层。
  defp resolve_my_enrollment(actor, %{kind: kind, offering_id: offering_id}) do
    case parse_offering_kind(kind) do
      {:ok, kind_atom} ->
        {event_ids, course_ids} =
          if kind_atom == :event, do: {[offering_id], []}, else: {[], [offering_id]}

        enrollment =
          actor
          |> Cgc2046.Admission.Enrollment.active_enrollments_by_offering(event_ids, course_ids)
          |> Map.get({kind_atom, offering_id})

        {:ok, enrollment && my_enrollment_payload(enrollment)}

      :error ->
        {:error, [message: "invalid kind (expected event | course)", code: "invalid_input"]}
    end
  end

  defp parse_offering_kind("event"), do: {:ok, :event}
  defp parse_offering_kind("course"), do: {:ok, :course}
  defp parse_offering_kind(_other), do: :error

  defp my_enrollment_payload(enrollment) do
    %{
      id: enrollment.id,
      workspace_id: enrollment.workspace_id,
      event_id: enrollment.event_id,
      course_id: enrollment.course_id,
      user_id: enrollment.user_id,
      status: to_string(enrollment.status),
      approval_deadline: enrollment.approval_deadline,
      rejection_reason: enrollment.rejection_reason,
      check_in_code: enrollment.check_in_code,
      inserted_at: enrollment.inserted_at
    }
  end

  # id / is_platform_admin 可空：update 失败时承载错误 payload（errors 非空、业务字段为 nil），
  # 与 admin 面其它 mutation 的 payload 式错误通道一致。
  object :admin_user_payload do
    field(:id, :id)
    field(:email, :string)
    field(:is_platform_admin, :boolean)
    field(:errors, list_of(:mutation_error))
  end

  # ── Platform Admin Dashboard Phase 5：resolver helpers ─────────────────

  # actor 门控组合子（PR-E）：nil → unauthorized_error()（on_nil 可覆盖——消费方：
  # me 的 auth_uncertain 分支与 myEnrollment 匿名→null），ok → fun.(actor)。
  # 19 处 case context[:actor] 标准门收敛于此，错误契约单点（未登录统一
  # unauthorized message/code）。
  defp with_actor(context, fun, opts \\ []) do
    on_nil = Keyword.get(opts, :on_nil, fn _context -> {:error, unauthorized_error()} end)

    case context[:actor] do
      nil -> on_nil.(context)
      actor -> fun.(actor)
    end
  end

  defp maybe_initiative_search(query, nil), do: query
  defp maybe_initiative_search(query, ""), do: query

  defp maybe_initiative_search(query, search) do
    Ash.Query.filter(query, contains(name, ^search) or contains(slug, ^search))
  end

  defp load_initiative_admin(initiative, actor, context) do
    case Ash.load(initiative, :rules, actor: actor) do
      {:ok, loaded} ->
        {:ok, admin_initiative_row(loaded)}

      {:error, error} ->
        {:error,
         to_ash_graphql_errors(
           error,
           context,
           :read,
           Cgc2046.Initiatives.Initiative,
           Cgc2046.Initiatives
         )}
    end
  end

  defp admin_initiative_row(initiative) do
    %{
      id: initiative.id,
      name: initiative.name,
      slug: initiative.slug,
      hashtag: initiative.hashtag,
      description: initiative.description,
      window_starts_at: initiative.window_starts_at,
      window_ends_at: initiative.window_ends_at,
      status: to_string(initiative.status),
      created_by: initiative.created_by,
      inserted_at: initiative.inserted_at,
      updated_at: initiative.updated_at,
      rules:
        if(is_list(initiative.rules), do: Enum.map(initiative.rules, &admin_rule_row/1), else: [])
    }
  end

  defp admin_rule_row(rule) do
    %{
      id: rule.id,
      initiative_id: rule.initiative_id,
      key: to_string(rule.key),
      value_json: Jason.encode!(rule.value),
      locked: rule.locked,
      inserted_at: rule.inserted_at,
      updated_at: rule.updated_at
    }
  end

  # ── U2 治理读面：offering（Event / Course）行与详情投影 ────────────────────
  # 行 = 列表用最小集（`admin_event` / `admin_course` 的字段全集，SDL 与投影
  # 一一对应）；详情 = 行 ⊕ 处置/排查字段。计数按场现取（KTD4），不入行投影。

  defp admin_event_row(event) do
    %{
      id: event.id,
      workspace_id: event.workspace_id,
      title: event.title,
      slug: event.slug,
      status: to_string(event.status),
      visibility: to_string(event.visibility),
      capacity: event.capacity,
      registration_deadline: event.registration_deadline,
      starts_at: event.starts_at,
      ends_at: event.ends_at,
      pricing_enabled: event.pricing_enabled,
      deposit_enabled: event.deposit_enabled,
      deposit_amount_cents: event.deposit_amount_cents,
      inserted_at: event.inserted_at,
      updated_at: event.updated_at
    }
  end

  defp admin_event_detail_row(event, actor) do
    Map.merge(admin_event_row(event), %{
      description: event.description,
      venue: event.venue,
      confirmed_count:
        offering_enrollment_count(:event_id, event.id, event.workspace_id, :confirmed),
      payment_pending_count:
        offering_enrollment_count(:event_id, event.id, event.workspace_id, :payment_pending),
      moderators: admin_event_moderators(event, actor),
      detached_rule_provenance: event.detached_rule_provenance
    })
  end

  # 主理人清单（U2）：走 `Moderators.list/3` 的读面（平台管理员分支已放行），
  # 不另起直读 EventModerator 的第二条读序；失败返回 nil（Logger 留痕）——
  # 附挂信息不阻断详情主读，且「空清单」与「清单加载失败」在 SDL 上可区分
  # （同 admin_initiative.mountedEvents 先例）。
  defp admin_event_moderators(event, actor) do
    case Cgc2046.Events.Moderators.list(event.id, event.workspace_id, actor) do
      {:ok, rows} ->
        rows

      {:error, reason} ->
        Logger.error("[get_admin_event.moderators] load failed: #{inspect(reason)}")
        nil
    end
  end

  defp admin_course_row(course) do
    %{
      id: course.id,
      workspace_id: course.workspace_id,
      title: course.title,
      provisional_title: course.provisional_title,
      slug: course.slug,
      status: to_string(course.status),
      visibility: to_string(course.visibility),
      capacity: course.capacity,
      registration_deadline: course.registration_deadline,
      starts_at: course.starts_at,
      ends_at: course.ends_at,
      pricing_enabled: course.pricing_enabled,
      inserted_at: course.inserted_at,
      updated_at: course.updated_at
    }
  end

  defp admin_course_detail_row(course) do
    Map.merge(admin_course_row(course), %{
      description: course.description,
      confirmed_count:
        offering_enrollment_count(:course_id, course.id, course.workspace_id, :confirmed),
      payment_pending_count:
        offering_enrollment_count(:course_id, course.id, course.workspace_id, :payment_pending)
    })
  end

  # KTD4 权威报名计数：按 offering 现取 `Enrollment` 行数（`status` 分列），
  # **不读** `events.confirmed_count` / `courses.confirmed_count` 展示投影
  # （自述可能滞后一拍）。filter 形状与工作台侧批量免缴披露（update_event /
  # update_course 的 payment_pending_count）逐字同源——治理面披露的数字与
  # 写面 200 笔上限判定的数字必须来自同一口径。
  #
  # 查询失败返回 nil（= SDL 的 nil「计数不可用」），**不回退 0**：0 是「确实
  # 没有」的事实，不可用与 0 混同会让界面骗人（KTD4 不落假值）。
  defp offering_enrollment_count(offering_field, offering_id, workspace_id, status) do
    Cgc2046.Admission.Enrollment
    |> Ash.Query.filter(^[{offering_field, offering_id}])
    |> Ash.Query.filter(status == ^status)
    |> Ash.count(authorize?: false, tenant: workspace_id)
    |> case do
      {:ok, count} ->
        count

      {:error, error} ->
        Logger.error(
          "[admin_offering_detail.enrollment_count] #{offering_field}/#{status} failed: " <>
            inspect(error)
        )

        nil
    end
  end

  # KTD5：`entity_id` 必须与 `entity_type` 成对。Finding.entity_id 混装 uuid
  # （event/course/enrollment…）与 oban_job 数字串，单用 entity_id 不是自解释的
  # 维数，还会跨实体类型误命中同号行——缺配对直接拒绝（不静默全表扫）。
  # 空串按未提供处理（同各 maybe_* 组合子的 "" 分支）。
  defp validate_finding_entity_pair(args) do
    if is_binary(args[:entity_id]) and args[:entity_id] != "" and
         args[:entity_type] in [nil, ""] do
      {:error, [message: "entity_id requires entity_type", code: "invalid_input"]}
    else
      :ok
    end
  end

  defp maybe_finding_entity_id(query, nil), do: query
  defp maybe_finding_entity_id(query, ""), do: query

  defp maybe_finding_entity_id(query, entity_id) do
    Ash.Query.filter(query, entity_id == ^entity_id)
  end

  # #607：治理 metadata → 白名单投影（`admin_action_log.metadata` 字段的唯一出口）。
  # 白名单表在模块顶部（`@admin_action_metadata_whitelist` / `@rule_value_whitelist`）。
  #
  # 返回 nil = 该 action 未收录（**没有默认透传兜底**：未来新 action 不加表即不可见），
  # 或该行形状不完整（见 `projectable_metadata?/1`：行级降级，不打挂整条查询）。
  # 键名取 jsonb 读回的字符串形态（写侧是 atom 键，落库/读回后一律字符串，
  # 实证见 test/cgc_2046/initiatives/rule_propagation_test.exs 的「规则变更审计含值前后」）。
  defp admin_action_metadata(%{action: action, metadata: metadata}) when is_map(metadata) do
    case Map.get(@admin_action_metadata_whitelist, action) do
      nil ->
        nil

      keys ->
        # 表即清单：顶层键一律经白名单 Map.take，未收录的键结构上进不来
        projected = Map.take(metadata, keys)

        if projectable_metadata?(projected) do
          rule_key = projected["rule_key"]

          {value_before, before_omitted?} =
            project_rule_value(rule_key, projected["value_before"])

          {value_after, after_omitted?} = project_rule_value(rule_key, projected["value_after"])

          %{
            rule_key: rule_key,
            locked: projected["locked"],
            locked_before: projected["locked_before"],
            # JsonString scalar 出参自行 JSON 编码（`serialize(&Jason.encode!/1)`），故这里
            # 交**原始投影**（OrderedObject | nil）；预先 encode 成字符串会被 scalar 二次
            # 编码，客户端 JSON.parse 一次只能拿到字符串而不是对象。
            value_before_json: value_before,
            value_after_json: value_after,
            value_before_omitted: before_omitted?,
            value_after_omitted: after_omitted?
          }
        else
          nil
        end
    end
  end

  defp admin_action_metadata(_log), do: nil

  # U1：offering 治理写 → 闭集标量前后值投影（`adminActionLog.offeringChange` 的唯一出口）。
  # 白名单表在模块顶部 `@admin_offering_change_metadata_whitelist`；键名同样取 jsonb
  # 读回的字符串形态。
  #
  # 返回 nil = 该 action 未收录（launch/close/cancel 等：行本身仍可见，只是没有变更
  # 投影），或该行一条 `*_after` 键都没有（如只改了自由文本属性——写面只为真变更的属性
  # 落键，全空对象会假装「有一条变更」）。
  defp admin_offering_change_metadata(%{action: action, metadata: metadata})
       when is_map(metadata) do
    case Map.get(@admin_offering_change_metadata_whitelist, action) do
      nil ->
        nil

      scalars ->
        projected =
          Map.take(metadata, Enum.flat_map(scalars, &["#{&1}_before", "#{&1}_after"]))

        if Enum.any?(scalars, &Map.has_key?(projected, "#{&1}_after")) do
          # 键名 → Absinthe 字段名（atom 在 object 声明处编译期存在；值侧标量门：
          # 非标量一律 nil——闭集字段类型固定，嵌套结构只可能是写面 bug，不透传）
          Map.new(projected, fn {key, value} ->
            {String.to_existing_atom(key), offering_change_scalar(value)}
          end)
        end
    end
  end

  defp admin_offering_change_metadata(_log), do: nil

  defp offering_change_scalar(value)
       when is_binary(value) or is_number(value) or is_boolean(value) or is_nil(value),
       do: value

  defp offering_change_scalar(_value), do: nil

  # #607 形状门：只有带**完整** #607 元数据形状的行才投影，否则整行落 nil（界面显示「—」）。
  # 两条理由：
  #   1. `value_after_json` 是 non_null。历史行没有 value_after——#587 之前的写面只落
  #      `%{initiative_id, rule_key, locked}`（见 origin/main 的 initiative_rule_metadata/2），
  #      线上存量行仍是这个形状。照常投影会让 Absinthe 非空违例把**整条列表查询**打挂
  #      （/admin/audit 整页 loadFailed，一行坏数据毁一页）；审计面要的是行级降级。
  #   2. 「前值 null ⇔ 新建」只有在完整形状下才成立；否则会把「这条没记前值」误报成「新建」，
  #      而审计面**不许撒谎**。
  defp projectable_metadata?(m) do
    is_map(m["value_after"]) and
      (is_nil(m["value_before"]) or is_map(m["value_before"])) and
      (is_nil(m["locked_before"]) or is_boolean(m["locked_before"])) and
      is_boolean(m["locked"]) and
      is_binary(m["rule_key"])
  end

  # 规则值 map → 二级白名单子集。返回 {投影, 是否发生省略}：
  #   - 键序 = `@rule_value_whitelist` 次序（Jason.OrderedObject 保序），前端直接按序渲染，
  #     故 web 层不需要再抄一份键名清单；
  #   - **标量门**：键名命中但值是嵌套结构（自由 map / list）也不出面——否则「按白名单投影」
  #     只到键名一层，嵌套内容会原样带出（键名白名单约束不了内容）；
  #   - 第二个返回值让「省略」可见（界面标 …），取证面不静默截断。
  defp project_rule_value(rule_key, value) when is_map(value) do
    allowed = Map.get(@rule_value_whitelist, rule_key, [])

    {scalars, nested?} =
      for(key <- allowed, Map.has_key?(value, key), do: {key, Map.get(value, key)})
      |> Enum.split_with(fn {_key, v} ->
        is_boolean(v) or is_number(v) or is_binary(v) or is_nil(v)
      end)

    omitted? = nested? != [] or Enum.any?(value, fn {key, _} -> key not in allowed end)

    {Jason.OrderedObject.new(scalars), omitted?}
  end

  # nil = 该侧无值（:create 的新建侧）；无白名单 rule_key 时也走这里（投影为空）。
  defp project_rule_value(_rule_key, _value), do: {nil, false}

  # #596 挂载前预览：RulePreview 返回规则原始值（MCP 面直接用 map），GraphQL 面
  # 按既有 AdminInitiativeRule 口径转 value_json 字符串
  defp initiative_mount_preview_row(preview) do
    %{
      initiative_id: preview.initiative_id,
      name: preview.name,
      slug: preview.slug,
      status: preview.status,
      rules:
        Enum.map(preview.rules, fn rule ->
          %{key: rule.key, value_json: Jason.encode!(rule.value), locked: rule.locked}
        end),
      missing_rules: preview.missing_rules
    }
  end

  defp initiative_mutation_result({:ok, initiative}, _context),
    do: {:ok, %{result: admin_initiative_row(initiative), errors: []}}

  defp initiative_mutation_result({:error, error}, context) do
    {:ok,
     %{
       result: nil,
       errors:
         mutation_errors(
           error,
           context,
           :update,
           Cgc2046.Initiatives.Initiative,
           Cgc2046.Initiatives
         )
     }}
  end

  defp mutation_errors(error, context, action, resource, domain) do
    to_ash_graphql_errors(error, context, action, resource, domain)
    |> List.wrap()
    |> Enum.map(fn error ->
      %{
        message: error[:message] || error.message || "invalid request",
        code: error[:code] || "invalid",
        # #595：拒绝路径要能定位到具体场/工作台，fields 不再丢弃
        # （规范化在 to_ash_graphql_errors/5，本处只透传）。
        fields: error[:fields] || []
      }
    end)
  end

  defp initiative_status_mutation(action) do
    fn _, %{id: id}, %{context: context} ->
      with_admin(context, fn actor ->
        with {:ok, initiative} <- Ash.get(Cgc2046.Initiatives.Initiative, id, actor: actor) do
          initiative
          |> Ash.Changeset.for_update(action, %{})
          |> Ash.update(actor: actor)
          |> initiative_mutation_result(context)
        else
          {:error, error} ->
            {:ok,
             %{
               result: nil,
               errors:
                 mutation_errors(
                   error,
                   context,
                   action,
                   Cgc2046.Initiatives.Initiative,
                   Cgc2046.Initiatives
                 )
             }}
        end
      end)
    end
  end

  # ── U1 治理写 resolver（Event / Course 共用同一对工厂）─────────────────────
  # with_admin 门控 → Ash.get（multitenant global 资源，无 tenant 跨租户定位）→
  # for_update + Ash.update（actor 直传、标准授权，无 authorize?: false 旁路）——
  # 与 initiative_status_mutation/1 同形：守卫/信号链/留痕全部由 action 本体承担。
  defp offering_status_mutation(resource, action, domain) do
    fn _, %{id: id}, %{context: context} ->
      with_admin(context, fn actor ->
        with {:ok, offering} <- Ash.get(resource, id, actor: actor) do
          offering
          |> Ash.Changeset.for_update(action, %{})
          |> Ash.update(actor: actor)
          |> offering_mutation_result(resource, action, domain, context)
        else
          {:error, error} ->
            {:ok,
             %{result: nil, errors: mutation_errors(error, context, action, resource, domain)}}
        end
      end)
    end
  end

  defp offering_update_mutation(resource, fields, domain) do
    fn _, %{id: id, input: input}, %{context: context} ->
      with_admin(context, fn actor ->
        with {:ok, offering} <- Ash.get(resource, id, actor: actor) do
          offering
          |> Ash.Changeset.for_update(:update, map_input(input, fields))
          |> Ash.update(actor: actor)
          |> offering_mutation_result(resource, :update, domain, context)
        else
          {:error, error} ->
            {:ok,
             %{result: nil, errors: mutation_errors(error, context, :update, resource, domain)}}
        end
      end)
    end
  end

  defp offering_mutation_result({:ok, offering}, _resource, _action, _domain, _context),
    do: {:ok, %{result: offering, errors: []}}

  defp offering_mutation_result({:error, error}, resource, action, domain, context) do
    {:ok, %{result: nil, errors: mutation_errors(error, context, action, resource, domain)}}
  end

  defp decode_rule_json(value) when is_binary(value) do
    case Jason.decode(value) do
      {:ok, decoded} when is_map(decoded) -> {:ok, decoded}
      {:ok, _} -> {:error, "rule value must be a JSON object"}
      {:error, _} -> {:error, "rule value_json must be valid JSON"}
    end
  end

  defp get_initiative_rule(initiative_id, key, actor) do
    Cgc2046.Initiatives.InitiativeRule
    |> Ash.Query.for_read(:read)
    |> Ash.Query.filter(initiative_id == ^initiative_id and key == ^key)
    |> Ash.read_one(actor: actor)
  end

  # key 白名单单源 = InitiativeRule.rule_keys()；未知 key → {:error, "invalid rule key"}
  # （else 分支映射为 code invalid_input 的 payload error），不做 String.to_existing_atom。
  defp rule_key(key) when is_binary(key) do
    case Enum.find(Cgc2046.Initiatives.InitiativeRule.rule_keys(), &(Atom.to_string(&1) == key)) do
      nil -> {:error, "invalid rule key"}
      key_atom -> {:ok, key_atom}
    end
  end

  # admin 门控：非 platform_admin → forbidden（与 Phase 1 PlatformAdminPlug 同语义）。
  # 未登录 → unauthorized。通过后执行 fun(actor)。
  defp with_admin(context, fun) do
    actor = context[:actor]

    cond do
      Cgc2046.Accounts.Policies.PlatformAdmin.platform_admin?(actor) ->
        fun.(actor)

      is_nil(actor) ->
        {:error, unauthorized_error()}

      true ->
        {:error, [message: "forbidden", code: "forbidden"]}
    end
  end

  # admin 列表 resolver 工厂：with_admin 门控 → args 校验 → for_read → filter →
  # pre_read → paginate → read → post_read。一处接线顺序，N 个 query 声明式复用
  # （leverage）；gate/validate/filter/paginate 顺序只在此验证（locality）。
  # my_workspace_applications 不用此构造器：gate 是 applicant 非 platform_admin，形状不同。
  defp admin_list(resource, filter_fn, post_fn, opts \\ []) do
    pre_read = Keyword.get(opts, :pre_read, fn q -> q end)

    # 成对/互斥类 args 约束（如 KTD5 entity_id 必须与 entity_type 成对）：门控之后、
    # 触库之前校验，返回 :ok | {:error, absinthe_error}；默认无约束。
    validate = Keyword.get(opts, :validate, fn _args -> :ok end)

    fn _, args, %{context: context} ->
      with_admin(context, fn actor ->
        with :ok <- validate.(args) do
          resource
          |> Ash.Query.for_read(:read)
          |> filter_fn.(args)
          |> pre_read.()
          |> AdminList.paginate(args[:first], args[:after])
          |> Ash.read(actor: actor)
          |> post_fn.(context)
        end
      end)
    end
  end

  # admin 列表 read 结果 → map_error（统一 :read action；resource/domain 按 query 闭包）
  defp admin_result(resource, domain) do
    fn result, context -> map_error(result, context, :read, resource, domain) end
  end

  # admin 列表 read 结果 → map_error 后逐行过投影（治理读面的行投影出口）
  defp admin_rows(resource, domain, row_fun) do
    fn result, context ->
      case map_error(result, context, :read, resource, domain) do
        {:ok, records} -> {:ok, Enum.map(records, row_fun)}
        {:error, _} = error -> error
      end
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
      {:ok, Cgc2046.Offering.Readiness.evaluate(entity)}
    end
  end

  # enrollment calculation 字段的 alias 感知取值（手写 object 无 AshGraphql
  # resolve_calculation）：alias 查询读 AshGraphql 加载槽；无 alias 读
  # calculations map（Ash 加载后写入），原字段兜底。
  #
  # parent 双形态（#727 健壮化）：Ash record（calculations 键存在，未加载为 nil）
  # 与 my_enrollment 的白名单 payload map（**没有** :calculations 键）——
  # `parent.calculations` 对后者抛 KeyError（不是 nil），必须走 Map.get/3 兜底；
  # 裸 map 上计算字段取不到值即 nil（该投影不携带计算值，不是崩溃）。
  defp enrollment_calc_value(parent, %{alias: nil}, field) do
    Map.get(calculations(parent), field) || Map.get(parent, field)
  end

  defp enrollment_calc_value(parent, %{alias: field_alias}, _field) do
    Map.get(calculations(parent), {:__ash_graphql_calculation__, field_alias})
  end

  defp calculations(parent), do: Map.get(parent, :calculations) || %{}

  # checkInCode 出示门控（KTD5）：仅 actor 即报名人且报名 confirmed。
  # status 双形态：my_enrollment_payload 白名单 map 已 to_string；Ash record
  # 为 :atom（手写 object 无 ash_graphql 生成查询的枚举转换层——同
  # resolve_my_enrollment 的显式 to_string 纪律）。
  # 核销结果里的押金退款侧事实（KTD6 分派表）：读该报名**唯一活跃押金单**的
  # 状态；无押金单 → nil（本次核销不产生退款）。单次点查（核销是低频人工动作）。
  defp deposit_refund_state(enrollment_id) do
    case Cgc2046.Repo.query(
           """
           SELECT status FROM payments_orders
           WHERE enrollment_id = $1 AND order_kind = 'deposit'
             AND status IN ('paid', 'refunding', 'refunded', 'refund_failed', 'forfeited')
           ORDER BY inserted_at DESC LIMIT 1
           """,
           [Cgc2046.Repo.uuid!(enrollment_id)]
         ) do
      {:ok, %{rows: [[status]]}} ->
        case status do
          # 核销后仍是 paid 只可能是异常残留：不宣称已发起退款
          "paid" -> nil
          "refund_failed" -> "refunding"
          other -> other
        end

      _ ->
        nil
    end
  end

  defp check_in_code_visible?(parent, actor) do
    enrollment_value(parent, :user_id) == actor.id and
      enrollment_value(parent, :status) in ["confirmed", :confirmed]
  end

  defp enrollment_value(parent, field) when is_map(parent),
    do: Map.get(parent, field) || Map.get(parent, to_string(field))

  # offeringReadiness 目标可能是 Event 或 Course（原 event 优先、失败回退 course）。
  # 读取唯一真源 = Offering；**必须显式 authorize?: true**（D2 风险：Offering 默认
  # authorize?: false 会绕过 read policy，actor 感知读取退化为全量可见）。
  defp fetch_offering_by_id(id, actor) do
    case Cgc2046.Offering.fetch(:event, id, actor: actor, authorize?: true) do
      {:ok, entity} -> {:ok, entity}
      {:error, _} -> Cgc2046.Offering.fetch(:course, id, actor: actor, authorize?: true)
    end
  end
end
