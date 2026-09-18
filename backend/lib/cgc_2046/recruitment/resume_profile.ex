defmodule Cgc2046.Recruitment.ResumeProfile do
  @moduledoc """
  简历档案（R9；KTD2 policy 边界）。

  一人一档：identity `[:workspace_id, :user_id]` + `:upsert` 动作（二次提交走
  `ON CONFLICT DO UPDATE`，同一行更新而非新建；跨批次复用、可更新）。`user_id`
  由 actor 强制写入（accept 通道不接受、不可伪造）。

  文件内容列同表定义（KTD3：简历走最小上传管道、文件存库）：`file_data`
  （bytea，`public?: false` + `sensitive?: true`——不出 GraphQL、不进 inspect）
  与文件名 / MIME / 大小 / 上传时间元数据；**上传校验与落库逻辑在 U2**
  （`Cgc2046.Recruitment.Upload`），本单元只落列。

  PIPL 边界（KTD2）：读 = 本人 ∪ Owner/Admin ∪ platform_admin；写 = 仅本人。
  """

  use Ash.Resource,
    data_layer: AshPostgres.DataLayer,
    extensions: [AshGraphql.Resource],
    authorizers: [Ash.Policy.Authorizer],
    domain: Cgc2046.Recruitment

  attributes do
    uuid_primary_key(:id)

    attribute(:workspace_id, :uuid,
      allow_nil?: false,
      public?: true,
      writable?: false,
      description: "所属工作台（租户）ID"
    )

    attribute(:user_id, :uuid,
      allow_nil?: false,
      public?: true,
      writable?: false,
      description: "档案所属用户 ID（创建/upsert 时由 actor 强制填充）"
    )

    attribute(:full_name, :string,
      allow_nil?: false,
      public?: true,
      writable?: true,
      description: "姓名"
    )

    attribute(:contact_email, :string,
      allow_nil?: false,
      public?: true,
      writable?: true,
      description: "联系邮箱（必填；R14 邮件保底通道的收件地址）"
    )

    attribute(:weekly_hours, :integer,
      public?: true,
      writable?: true,
      description: "每周可投入小时数"
    )

    attribute(:skills, {:array, :string},
      allow_nil?: false,
      default: [],
      public?: true,
      writable?: true,
      description: "技能多选（字符串列表）"
    )

    attribute(:file_name, :string,
      public?: true,
      writable?: true,
      description: "简历文件名（U2 上传管道写入）"
    )

    attribute(:file_content_type, :string,
      public?: true,
      writable?: true,
      description: "简历文件 MIME（PDF/Word；U2 上传管道写入）"
    )

    attribute(:file_size, :integer,
      public?: true,
      writable?: true,
      description: "简历文件字节数（原始文件；U2 上传管道写入）"
    )

    attribute(:uploaded_at, :utc_datetime,
      public?: true,
      writable?: true,
      description: "简历文件上传时间（U2 上传管道写入）"
    )

    # 文件内容本体（bytea）。public?: false + sensitive?: true = 不出 GraphQL、
    # 不进 inspect/日志；写入路径只有 U2 的校验后 force_change（不对客户端开放）
    attribute(:file_data, :binary,
      public?: false,
      sensitive?: true,
      writable?: false,
      description: "简历文件内容（bytea；≤5MB，类型/魔数校验在 U2）"
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
  end

  identities do
    # 一人一档（同 workspace 同用户）；upsert 的冲突目标
    identity(:one_per_workspace_user, [:workspace_id, :user_id])
  end

  actions do
    defaults([:read])

    # 完善/更新简历档案的统一入口（U5 暴露 `upsertResumeProfile`）：
    # 首次 = 建行，已存在 = 按 upsert_fields 更新同一行（幂等）
    create :upsert do
      primary?(true)
      accept([:full_name, :contact_email, :weekly_hours, :skills])
      upsert?(true)
      upsert_identity(:one_per_workspace_user)
      upsert_fields([:full_name, :contact_email, :weekly_hours, :skills])

      change(before_action(&put_actor_user_id/2))
    end

    update :update do
      primary?(true)
      require_atomic?(false)
      accept([:full_name, :contact_email, :weekly_hours, :skills])
    end
  end

  graphql do
    type(:resume_profile)
  end

  postgres do
    table("resume_profiles")
    repo(Cgc2046.Repo)
  end

  policies do
    # 写面：本人（user_id 由 before_action 强制 = actor，伪造他人身份不可达）
    policy action_type(:create) do
      authorize_if(actor_present())
    end

    policy action_type(:update) do
      authorize_if(expr(user_id == ^actor(:id)))
    end

    # 读面（PIPL，KTD2）：本人 ∪ Owner/Admin ∪ platform_admin
    policy action_type(:read) do
      authorize_if(expr(user_id == ^actor(:id)))
      authorize_if(Cgc2046.Accounts.Policies.WorkspaceActorIsOwnerOrAdmin)
      authorize_if(Cgc2046.Accounts.Policies.PlatformAdmin)
    end
  end

  # user_id 只能来自 actor（普通 change 在 `Ash.Changeset.for_create` 阶段跑，
  # 那时 actor 尚未注入 context，故用 before_action——范式同 PortfolioItem）
  defp put_actor_user_id(changeset, _context) do
    case changeset.context[:private][:actor] do
      %{id: user_id} ->
        Ash.Changeset.force_change_attribute(changeset, :user_id, user_id)

      _ ->
        changeset
    end
  end
end
