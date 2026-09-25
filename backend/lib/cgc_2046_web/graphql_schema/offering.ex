defmodule Cgc2046Web.GraphqlSchema.Offering do
  @moduledoc """
  Offering 治理域（U1/U2 平台治理：Event / Course 治理读写面）GraphQL 面：
  query / mutation 字段；类型在 `Offering.Types`，域内 helper 在 `Offering.Helpers`。
  """

  use Absinthe.Schema.Notation

  import_types(Cgc2046Web.GraphqlSchema.Offering.Types)

  import Cgc2046Web.GraphqlSchema.Helpers
  import Cgc2046Web.GraphqlSchema.Offering.Helpers

  alias Cgc2046.AdminList

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

  object :offering_queries do
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

  object :offering_mutations do
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
end
