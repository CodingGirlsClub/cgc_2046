defmodule Cgc2046Web.GraphqlSchema.Learning do
  @moduledoc """
  Learning 读面域（U7/U8 学习抽屉与课程地图）GraphQL 面：query 字段与类型；
  resolver helper 在 `Learning.Helpers`。纯 query 域（无 mutation 字段）。
  """

  use Absinthe.Schema.Notation

  import Cgc2046Web.GraphqlSchema.Helpers
  import Cgc2046Web.GraphqlSchema.Learning.Helpers

  object :learning_queries do
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
end
