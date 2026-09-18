defmodule Cgc2046.Recruitment.VolunteerApplication do
  @moduledoc """
  志愿者申请（R8；KTD2 policy 边界）。

  约束「同一批次同一申请人限一份申请」（AE2）：identity `[:user_id, :cohort_id]`，
  同批换职位也拒（职位不是唯一键的一部分）；rejected/canceled 后本批结束、
  下一批可换职位再申——换批次即换行，不重置语义。`user_id` 由 actor 强制
  写入（accept 通道不接受、不可伪造）。

  职位为**代码枚举**（`event_moderator | tutor | coach`，KTD4），不建职位表；
  职责/要求文案走 i18n（U7/U10）。

  段位状态机 `submitted → interview → training → assigned`（任一审核段可
  `rejected`〔必带原因〕/ `canceled`）在 U3 落成 update actions（含 workflow
  run 集成与状态守卫）；本单元只声明 status 列、拒绝原因与分配列，
  以及 KTD2 的 policy 边界（段位流转限 Owner/Admin ∪ platform_admin）。
  """

  use Ash.Resource,
    data_layer: AshPostgres.DataLayer,
    extensions: [AshGraphql.Resource],
    authorizers: [Ash.Policy.Authorizer],
    domain: Cgc2046.Recruitment

  # 段位（R12 状态图）与职位（R8，KTD4；与 RBAC 角色同名不同义）
  @statuses [:submitted, :interview, :training, :assigned, :rejected, :canceled]
  @positions [:event_moderator, :tutor, :coach]

  attributes do
    uuid_primary_key(:id)

    attribute(:workspace_id, :uuid,
      allow_nil?: false,
      public?: true,
      writable?: false,
      description: "所属工作台（租户）ID（KTD2：所有倡导活动都在 2046 台）"
    )

    attribute(:user_id, :uuid,
      allow_nil?: false,
      public?: true,
      writable?: false,
      description: "申请人 ID（创建时由 actor 强制填充，不可代他人提交）"
    )

    attribute(:cohort_id, :uuid,
      allow_nil?: false,
      public?: true,
      writable?: true,
      description: "申请批次 ID"
    )

    attribute(:position, :atom,
      allow_nil?: false,
      public?: true,
      writable?: true,
      constraints: [one_of: @positions],
      description: "职位：event_moderator | tutor | coach（枚举，不建表）"
    )

    attribute(:city, :string,
      public?: true,
      writable?: true,
      description: "申请城市（Tutor 可远程）"
    )

    attribute(:heard_about_us, :string,
      public?: true,
      writable?: true,
      description: "如何得知我们"
    )

    attribute(:has_internal_referrer, :boolean,
      allow_nil?: false,
      default: false,
      public?: true,
      writable?: true,
      description: "是否有内部推荐人"
    )

    attribute(:message, :string,
      public?: true,
      writable?: true,
      description: "留言（选填）"
    )

    attribute(:status, :atom,
      allow_nil?: false,
      default: :submitted,
      public?: true,
      writable?: false,
      constraints: [one_of: @statuses],
      description: "段位（R12 状态图；流转 action 在 U3）"
    )

    attribute(:rejection_reason, :string,
      public?: true,
      writable?: true,
      description: "拒绝原因（状态转 rejected 时必填；写入在 U3 的流转 action）"
    )

    attribute(:assigned_event_id, :uuid,
      public?: true,
      writable?: true,
      description: "分配的场次 ID（可空；项目分配时写入）"
    )

    attribute(:assignment_note, :string,
      public?: true,
      writable?: true,
      description: "分配备注（如 Tutor 的课程任务；不建任务实体）"
    )

    attribute(:assigned_at, :utc_datetime,
      public?: true,
      writable?: true,
      description: "分配时间"
    )

    create_timestamp(:inserted_at)
    update_timestamp(:updated_at)
  end

  multitenancy do
    strategy(:attribute)
    attribute(:workspace_id)
    global?(true)
  end

  relationships do
    belongs_to(:workspace, Cgc2046.Accounts.Workspace, define_attribute?: false)
    belongs_to(:user, Cgc2046.Accounts.User, define_attribute?: false)

    belongs_to(:cohort, Cgc2046.Recruitment.RecruitmentCohort,
      source_attribute: :cohort_id,
      destination_attribute: :id,
      define_attribute?: false
    )

    belongs_to(:assigned_event, Cgc2046.Events.Event,
      source_attribute: :assigned_event_id,
      destination_attribute: :id,
      define_attribute?: false
    )
  end

  identities do
    # 同批一份（AE2）：换职位不重置；换批次即换行
    identity(:unique_per_cohort, [:user_id, :cohort_id])
  end

  actions do
    defaults([:read])

    create :create do
      accept([
        :cohort_id,
        :position,
        :city,
        :heard_about_us,
        :has_internal_referrer,
        :message
      ])

      # 撞同批唯一索引 → 稳定业务 code（AE2）
      error_handler({__MODULE__, :handle_write_error, []})

      change(before_action(&put_actor_user_id/2))
    end
  end

  postgres do
    table("volunteer_applications")
    repo(Cgc2046.Repo)
  end

  policies do
    # 读面：本人 ∪ Owner/Admin ∪ platform_admin（R13 管理面读全量）
    policy action_type(:read) do
      authorize_if(expr(user_id == ^actor(:id)))
      authorize_if(Cgc2046.Accounts.Policies.WorkspaceActorIsOwnerOrAdmin)
      authorize_if(Cgc2046.Accounts.Policies.PlatformAdmin)
    end

    # create 限本人：user_id 由 before_action 强制 = actor（申请人无需是台成员——
    # 项目分配时才邀请入台，R15）
    policy action_type(:create) do
      authorize_if(actor_present())
    end

    # 段位流转（含分配）限 Owner/Admin ∪ platform_admin；流转 action 在 U3
    policy action_type(:update) do
      authorize_if(Cgc2046.Accounts.Policies.WorkspaceActorIsOwnerOrAdmin)
      authorize_if(Cgc2046.Accounts.Policies.PlatformAdmin)
    end
  end

  # 同批重复申请（撞 volunteer_applications_unique_per_cohort_index）→ 稳定
  # 业务错误。按约束名分派、非 unique 冲突原样上抛（fail-closed），范式同
  # EventModerator.handle_write_error/2（#611）。
  @doc false
  def handle_write_error(_changeset, error) do
    if Cgc2046.Errors.ConstraintConflict.unique_conflict?(error) and
         Cgc2046.Errors.ConstraintConflict.constraint_named?(
           error,
           "volunteer_applications_unique_per_cohort_index"
         ) do
      Cgc2046.Errors.BusinessError.exception(
        message: "an application for this cohort already exists",
        code: "volunteer_application_already_submitted",
        fields: [:cohort_id]
      )
    else
      error
    end
  end

  # user_id 只能来自 actor（普通 change 在 for_create 阶段跑，actor 尚未注入
  # context，故用 before_action——范式同 PortfolioItem）
  defp put_actor_user_id(changeset, _context) do
    case changeset.context[:private][:actor] do
      %{id: user_id} ->
        Ash.Changeset.force_change_attribute(changeset, :user_id, user_id)

      _ ->
        changeset
    end
  end
end
