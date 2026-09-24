defmodule Cgc2046Web.GraphqlSchema.Recruitment do
  @moduledoc """
  招募域（Hacker Start 1024 campaign）GraphQL 面：query / mutation 字段与类型；resolver helper 在 `Recruitment.Helpers`。
  """

  use Absinthe.Schema.Notation

  import Cgc2046Web.GraphqlSchema.Helpers
  import Cgc2046Web.GraphqlSchema.Recruitment.Helpers
  alias Cgc2046.AdminList
  require Ash.Query

  object :recruitment_queries do
    # ── Recruitment（Hacker Start 1024 campaign；R10 申请侧 / R13 管理侧读面）──
    #
    # 三资源类型由 AshGraphql 从资源属性派生（`recruitment_cohort` /
    # `resume_profile` / `volunteer_application`），本段只声明读取入口与投影。
    # 简历文件内容列（`resume_profiles.file_data`，`public?: false` +
    # `sensitive?: true`）**结构上不在类型里**——GraphQL 面只投影文件名 /
    # MIME / 大小 / 上传时间元数据，文件读写走 U2 专线。
    #
    # 租户惯例（KTD2 / #104）：入口 `workspaceId` 显式 argument，不注入 tenant；
    # 内部 Ash 调用一律传 `tenant:`。管理面入口另经 with_workspace_manager 显式
    # 门控——单靠 read policy 会退化成「过滤」语义（非管理面静默只见自己的行，
    # 而非 R13 契约的 Forbidden）。

    @desc "当前 open 招募批次（公开申请页数据面，匿名可读；R10/AE12）：批次区三态中的「有批次」与「无批次」由本字段 null 区分；draft/closed 不因本字段露面"
    field :current_recruitment_cohort, :recruitment_cohort do
      arg(:workspace_id, non_null(:id))

      resolve(fn _, %{workspace_id: workspace_id}, %{context: context} ->
        Cgc2046.Recruitment.RecruitmentCohort
        |> Ash.Query.for_read(:read)
        |> Ash.Query.filter(status == :open)
        |> Ash.read_one(tenant: workspace_id, actor: context[:actor])
        |> map_error(
          context,
          :read,
          Cgc2046.Recruitment.RecruitmentCohort,
          Cgc2046.Recruitment
        )
      end)
    end

    @desc "本人简历档案（R11 第 1 步；仅本人 ∪ Owner/Admin ∪ platform_admin 可读，未建档返回 null）；不含文件内容"
    field :my_resume_profile, :resume_profile do
      arg(:workspace_id, non_null(:id))

      resolve(fn _, %{workspace_id: workspace_id}, %{context: context} ->
        with_actor(context, fn actor ->
          Cgc2046.Recruitment.ResumeProfile
          |> Ash.Query.for_read(:read)
          # file_data（≤5MB blob）不出 GraphQL 面，读路径不拖它——否则每次打开
          # 申请页都白拉 5MB；本 resolver 只投影元数据
          |> Ash.Query.deselect(:file_data)
          |> Ash.Query.filter(user_id == ^actor.id)
          |> Ash.read_one(tenant: workspace_id, actor: actor)
          |> map_error(
            context,
            :read,
            Cgc2046.Recruitment.ResumeProfile,
            Cgc2046.Recruitment
          )
        end)
      end)
    end

    @desc "本人的志愿者申请列表（申请人视角：跨批次、新→旧；含当前段位与拒绝原因）"
    field :my_volunteer_applications, non_null(list_of(non_null(:volunteer_application))) do
      arg(:workspace_id, non_null(:id))

      resolve(fn _, %{workspace_id: workspace_id}, %{context: context} ->
        with_actor(context, fn actor ->
          Cgc2046.Recruitment.VolunteerApplication
          |> Ash.Query.for_read(:read)
          |> Ash.Query.filter(user_id == ^actor.id)
          |> Ash.Query.sort(inserted_at: :desc, id: :desc)
          |> Ash.read(tenant: workspace_id, actor: actor)
          |> map_error(
            context,
            :read,
            Cgc2046.Recruitment.VolunteerApplication,
            Cgc2046.Recruitment
          )
        end)
      end)
    end

    @desc "Owner/Admin（platform_admin 穿透）招募批次全量列表（R13 批次管理：draft/closed 只在管理面可见，公开面仅 open）；无分页（批次数有限）"
    field :list_recruitment_cohorts, non_null(list_of(non_null(:recruitment_cohort))) do
      arg(:workspace_id, non_null(:id))

      resolve(fn _, %{workspace_id: workspace_id}, %{context: context} ->
        with_workspace_manager(context, workspace_id, fn actor ->
          Cgc2046.Recruitment.RecruitmentCohort
          |> Ash.Query.for_read(:read)
          |> Ash.Query.sort(inserted_at: :desc, id: :desc)
          |> Ash.read(tenant: workspace_id, actor: actor)
          |> map_error(
            context,
            :read,
            Cgc2046.Recruitment.RecruitmentCohort,
            Cgc2046.Recruitment
          )
        end)
      end)
    end

    @desc "Owner/Admin（platform_admin 穿透）招募申请列表（R13）：按批次 / 职位 / 段位过滤，分页沿用 AdminList.paginate（first 默认 50 封顶 200，after 为偏移）；非本台管理角色 forbidden"
    field :list_volunteer_applications, non_null(list_of(non_null(:volunteer_application))) do
      arg(:workspace_id, non_null(:id))
      arg(:cohort_id, :id)
      arg(:position, :string, description: "event_moderator | tutor | coach（非枚举值忽略过滤）")

      arg(:status, :string,
        description: "submitted | interview | training | assigned | rejected | canceled（非枚举值忽略过滤）"
      )

      arg(:first, :integer)
      arg(:after, :string)

      resolve(fn _, args, %{context: context} ->
        with_workspace_manager(context, args[:workspace_id], fn actor ->
          Cgc2046.Recruitment.VolunteerApplication
          |> Ash.Query.for_read(:read)
          |> maybe_cohort_filter(args[:cohort_id])
          |> AdminList.maybe_status_filter(args[:position], :position)
          |> AdminList.maybe_status_filter(args[:status])
          |> AdminList.paginate(args[:first], args[:after])
          |> Ash.read(tenant: args[:workspace_id], actor: actor)
          |> map_error(
            context,
            :read,
            Cgc2046.Recruitment.VolunteerApplication,
            Cgc2046.Recruitment
          )
        end)
      end)
    end

    @desc "Owner/Admin（platform_admin 穿透）申请详情（R13）：申请记录 + 申请人简历档案元数据（未建档为 null；文件内容不经 GraphQL 面）；非本台管理角色 forbidden"
    field :volunteer_application_detail, :volunteer_application_detail do
      arg(:workspace_id, non_null(:id))
      arg(:id, non_null(:id))

      resolve(fn _, %{workspace_id: workspace_id, id: id}, %{context: context} ->
        with_workspace_manager(context, workspace_id, fn actor ->
          resolve_volunteer_application_detail(workspace_id, id, actor, context)
        end)
      end)
    end
  end

  object :recruitment_mutations do
    # ── Recruitment（Hacker Start 1024 campaign；R11 申请侧 + R13 管理侧写面）──
    #
    # 全部走 payload（result + errors）通道：业务错误（同批已申请、批次已关闭、
    # 非法段位、拒绝未填原因、唯一 open 冲突）以稳定 code 进 errors，前端按 code
    # 查文案——与自动生成 mutation 的错误协议一致，不落顶层 error。
    # 段位/租户边界由资源 policy 兜底（create 限本人、流转限 Owner/Admin ∪
    # platform_admin）；管理面入口另经 with_workspace_manager 显式门控。

    @desc "提交志愿者申请（R11 第 2 步；登录限本人，user_id 由 actor 强制填充、不可代提交）：同批重复申请 → volunteer_application_already_submitted；批次已关闭 → volunteer_application_cohort_closed"
    field :create_volunteer_application, :volunteer_application_payload do
      arg(:workspace_id, non_null(:id))
      arg(:input, non_null(:create_volunteer_application_input))

      resolve(fn _, %{workspace_id: workspace_id, input: input}, %{context: context} ->
        with_actor(context, fn actor ->
          attrs =
            map_input(input, [
              :cohort_id,
              :position,
              :city,
              :heard_about_us,
              :has_internal_referrer,
              :message
            ])

          Cgc2046.Recruitment.VolunteerApplication
          |> Ash.Changeset.for_create(:create, attrs, tenant: workspace_id)
          |> Ash.create(tenant: workspace_id, actor: actor)
          |> recruitment_mutation_result(
            context,
            :create,
            Cgc2046.Recruitment.VolunteerApplication
          )
        end)
      end)
    end

    @desc "完善 / 更新本人简历档案（R11 第 1 步；一人一档，重复提交更新同一行；仅本人可写）；含姓名 / 联系邮箱 / 每周可投入 / 技能；文件内容经 U2 上传专线，不走本 mutation"
    field :upsert_resume_profile, :resume_profile_payload do
      arg(:workspace_id, non_null(:id))
      arg(:input, non_null(:upsert_resume_profile_input))

      resolve(fn _, %{workspace_id: workspace_id, input: input}, %{context: context} ->
        with_actor(context, fn actor ->
          attrs = map_input(input, [:full_name, :contact_email, :weekly_hours, :skills])

          Cgc2046.Recruitment.ResumeProfile
          |> Ash.Changeset.for_create(:upsert, attrs, tenant: workspace_id)
          |> Ash.create(tenant: workspace_id, actor: actor)
          |> recruitment_mutation_result(context, :upsert, Cgc2046.Recruitment.ResumeProfile)
        end)
      end)
    end

    @desc "上传本人简历文件（R9；KTD3 最小上传管道单入口，base64-over-JSON，不接 multipart）：PDF/Word，原始文件 ≤5MB，扩展名/声明 MIME/文件头魔数三者一致才收。二次上传覆盖旧文件（一人一档）。需先 upsertResumeProfile 建档——未建档 → resume_profile_not_found；类型不一致/伪装 → resume_profile_file_type_invalid；超限 → resume_profile_file_too_large；内容非 base64 或空 → resume_profile_file_content_invalid"
    field :upload_resume_file, :resume_profile_payload do
      arg(:workspace_id, non_null(:id))
      arg(:input, non_null(:upload_resume_file_input))

      resolve(fn _, %{workspace_id: workspace_id, input: input}, %{context: context} ->
        with_actor(context, fn actor ->
          attrs = map_input(input, [:file_name, :content_type, :content_base64])

          Cgc2046.Recruitment.Upload.store(workspace_id, actor, attrs)
          |> recruitment_mutation_result(context, :upload_file, Cgc2046.Recruitment.ResumeProfile)
        end)
      end)
    end

    @desc "初审通过：submitted → interview（Owner/Admin ∪ platform_admin；非法段位 → volunteer_application_invalid_transition）"
    field :advance_volunteer_application_to_interview, :volunteer_application_payload do
      arg(:workspace_id, non_null(:id))
      arg(:id, non_null(:id))

      resolve(recruitment_stage_transition(:advance_to_interview))
    end

    @desc "群面通过：interview → training（Owner/Admin ∪ platform_admin；非法段位 → volunteer_application_invalid_transition）"
    field :advance_volunteer_application_to_training, :volunteer_application_payload do
      arg(:workspace_id, non_null(:id))
      arg(:id, non_null(:id))

      resolve(recruitment_stage_transition(:advance_to_training))
    end

    @desc "训练营完成·项目分配：training → assigned（Owner/Admin ∪ platform_admin；可带场次与备注，assignedAt 由域层落）"
    field :assign_volunteer_application, :volunteer_application_payload do
      arg(:workspace_id, non_null(:id))
      arg(:id, non_null(:id))
      arg(:assigned_event_id, :id, description: "分配的目标场次 ID（可空：Tutor 可无场次）")
      arg(:assignment_note, :string, description: "分配备注（可空，如 Tutor 的课程任务）")

      resolve(recruitment_stage_transition(:assign))
    end

    @desc "拒绝申请：submitted | interview | training → rejected（Owner/Admin ∪ platform_admin）。reason 空白或缺失 → volunteer_application_rejection_reason_required（必填规则单源在域层，此处不做 schema 级拦截）"
    field :reject_volunteer_application, :volunteer_application_payload do
      arg(:workspace_id, non_null(:id))
      arg(:id, non_null(:id))
      arg(:reason, :string, description: "拒绝原因（必填；进入申请人通知）")

      resolve(recruitment_stage_transition(:reject))
    end

    @desc "取消申请：submitted | interview | training → canceled（Owner/Admin ∪ platform_admin；备注选填，与拒绝原因不同：canceled 无必填约束）"
    field :cancel_volunteer_application, :volunteer_application_payload do
      arg(:workspace_id, non_null(:id))
      arg(:id, non_null(:id))
      arg(:reason, :string, description: "取消备注（选填）")

      resolve(recruitment_stage_transition(:cancel))
    end

    @desc "创建招募批次（Owner/Admin ∪ platform_admin；初始 draft，开放走 openRecruitmentCohort）"
    field :create_recruitment_cohort, :recruitment_cohort_payload do
      arg(:workspace_id, non_null(:id))
      arg(:input, non_null(:create_recruitment_cohort_input))

      resolve(fn _, %{workspace_id: workspace_id, input: input}, %{context: context} ->
        with_workspace_manager(context, workspace_id, fn actor ->
          attrs = map_input(input, [:name, :apply_deadline_at, :starts_at, :ends_at])

          Cgc2046.Recruitment.RecruitmentCohort
          |> Ash.Changeset.for_create(:create, attrs, tenant: workspace_id)
          |> Ash.create(tenant: workspace_id, actor: actor)
          |> recruitment_mutation_result(context, :create, Cgc2046.Recruitment.RecruitmentCohort)
        end)
      end)
    end

    @desc "编辑招募批次元数据（Owner/Admin ∪ platform_admin；状态迁移不经本 mutation）"
    field :update_recruitment_cohort, :recruitment_cohort_payload do
      arg(:workspace_id, non_null(:id))
      arg(:id, non_null(:id))
      arg(:input, non_null(:update_recruitment_cohort_input))

      resolve(fn _, %{workspace_id: workspace_id, id: id, input: input}, %{context: context} ->
        with_workspace_manager(context, workspace_id, fn actor ->
          attrs = map_input(input, [:name, :apply_deadline_at, :starts_at, :ends_at])

          recruitment_cohort_update(workspace_id, id, :update, attrs, actor)
          |> recruitment_mutation_result(
            context,
            :update,
            Cgc2046.Recruitment.RecruitmentCohort
          )
        end)
      end)
    end

    @desc "开放批次：draft | closed → open（Owner/Admin ∪ platform_admin；同台已有一个 open → recruitment_cohort_open_conflict，DB 部分唯一索引兜底）"
    field :open_recruitment_cohort, :recruitment_cohort_payload do
      arg(:workspace_id, non_null(:id))
      arg(:id, non_null(:id))

      resolve(recruitment_cohort_status_mutation(:open))
    end

    @desc "关闭批次：open → closed（Owner/Admin ∪ platform_admin；关闭后不放行新申请，在途申请照常走完）"
    field :close_recruitment_cohort, :recruitment_cohort_payload do
      arg(:workspace_id, non_null(:id))
      arg(:id, non_null(:id))

      resolve(recruitment_cohort_status_mutation(:close))
    end
  end

  # ── Recruitment（Hacker Start 1024 campaign）：payload / input / 详情类型 ──
  #
  # 资源记录类型（recruitment_cohort / resume_profile / volunteer_application）
  # 由 AshGraphql 从资源属性派生，此处只声明本面自有的包装形状。
  # 简历文件内容（file_data）不在任何投影里——`public?: false` + `sensitive?`
  # 使其结构上不可达（KTD3；文件读写走 U2 专线）。

  object :volunteer_application_payload do
    @desc "招募申请 mutation 返回：result 为申请记录（失败为 null）；errors 为业务错误（code 稳定，前端按 code 查文案）"
    field(:result, :volunteer_application)
    field(:errors, non_null(list_of(non_null(:mutation_error))))
  end

  object :resume_profile_payload do
    @desc "简历档案 mutation 返回：result 为档案记录（失败为 null）；errors 为业务错误"
    field(:result, :resume_profile)
    field(:errors, non_null(list_of(non_null(:mutation_error))))
  end

  object :recruitment_cohort_payload do
    @desc "批次 mutation 返回：result 为批次记录（失败为 null）；errors 为业务错误（唯一 open 冲突为 recruitment_cohort_open_conflict）"
    field(:result, :recruitment_cohort)
    field(:errors, non_null(list_of(non_null(:mutation_error))))
  end

  object :volunteer_application_detail do
    @desc "审核面申请详情：申请记录 + 申请人简历档案元数据（未建档为 null）"
    field(:application, non_null(:volunteer_application))
    field(:resume_profile, :resume_profile)
  end

  input_object :create_volunteer_application_input do
    @desc "createVolunteerApplication 输入（R11 第 2 步；user_id 由 actor 强制填充，不接受客户端传入）"
    field(:cohort_id, non_null(:id), description: "申请批次 ID（默认当前 open 批次）")
    field(:position, non_null(:string), description: "职位：event_moderator | tutor | coach")

    field(:city, :string, description: "申请城市（Tutor 可远程）")
    field(:heard_about_us, :string, description: "如何得知我们")
    field(:has_internal_referrer, :boolean, description: "是否有内部推荐人（缺省 false）")
    field(:message, :string, description: "留言（选填）")
  end

  input_object :upsert_resume_profile_input do
    @desc "upsertResumeProfile 输入（R11 第 1 步；user_id 由 actor 强制填充）"
    field(:full_name, non_null(:string), description: "姓名")
    field(:contact_email, non_null(:string), description: "联系邮箱（R14 邮件保底通道收件地址）")
    field(:weekly_hours, :integer, description: "每周可投入小时数（选填）")
    field(:skills, list_of(non_null(:string)), description: "技能多选（字符串列表；缺省不改动）")
  end

  input_object :upload_resume_file_input do
    @desc "uploadResumeFile 输入（KTD3：base64-over-JSON；扩展名/声明 MIME/魔数三者一致才收）"
    field(:file_name, non_null(:string), description: "文件名（含扩展名：.pdf / .doc / .docx）")
    field(:content_type, non_null(:string), description: "声明的 MIME（须与扩展名同族）")

    field(:content_base64, non_null(:string),
      description: "文件内容（标准 base64；原始文件 ≤5MB，即请求体约 6.7MB，在 endpoint 8MB 闸门内）"
    )
  end

  input_object :create_recruitment_cohort_input do
    @desc "createRecruitmentCohort 输入（初始状态 draft，开放走 openRecruitmentCohort）"
    field(:name, non_null(:string), description: "批次名称（如「第 1 批」）")
    field(:apply_deadline_at, non_null(:datetime), description: "申请截止时间（UTC）")
    field(:starts_at, :datetime, description: "执行周期开始（可空）")
    field(:ends_at, :datetime, description: "执行周期结束（可空）")
  end

  input_object :update_recruitment_cohort_input do
    @desc "updateRecruitmentCohort 输入（只传要改的字段）"
    field(:name, :string)
    field(:apply_deadline_at, :datetime)
    field(:starts_at, :datetime)
    field(:ends_at, :datetime)
  end
end
