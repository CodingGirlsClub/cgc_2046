defmodule Cgc2046Web.GraphqlSchema.AdminDashboard do
  @moduledoc """
  Admin Dashboard（Platform Admin Dashboard Phase 5）域 GraphQL 面：admin
  查询/治理 mutation 字段；类型在 `AdminDashboard.Types`，域内 helper 与白名单
  属性在 `AdminDashboard.Helpers`。my_workspace_applications 为用户自助面，
  字段与 admin_workspace_application 类型留在 schema（#844 放置裁决）。
  """

  use Absinthe.Schema.Notation

  import_types(Cgc2046Web.GraphqlSchema.AdminDashboard.Types)

  import Cgc2046Web.GraphqlSchema.Helpers
  import Cgc2046Web.GraphqlSchema.AdminDashboard.Helpers

  alias Cgc2046.AdminList

  object :admin_dashboard_queries do
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
  end

  object :admin_dashboard_mutations do
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
  end
end
