defmodule Cgc2046.Accounts.WorkspaceProfile do
  @moduledoc """
  工作台成员公开资料资源（ADR-0004，per-workspace profile）。

  领域模型：Profile 为**租户资源**（CONTEXT.md §8）——头像/简介/技能/主题偏好
  按 workspace 隔离（workspace_id），同一全局 User 在不同 Workspace 持有独立档案；
  `display_name`/`email` 为全局身份字段，不属于本资源。

  - identity `(workspace_id, user_id)` 唯一：每成员每工作台至多一份档案
  - visibility 三档（public / workspace / only_me）：
    - :public 所有登录用户可读
    - :workspace **目标 workspace 成员**可读（收窄自全局 User 的"任一 workspace"语义）
    - :only_me 仅本人可读（默认，隐私优先）
  - ui_theme_preference 同挂本资源（per-workspace 主题，用户决策）

  授权（读）：
  - 本人永远可读
  - 他人按 visibility 三档（ReadWorkspaceProfileByVisibility，filter 阶段判定）
  - 匿名不可读

  写（update_profile / set_ui_theme）：仅本人（OwnWorkspaceProfile 判 user_id），
  且须为该 workspace 成员（ActorIsWorkspaceMember）。

  GraphQL 契约手写于 `Cgc2046Web.GraphqlSchema`（workspaceProfile /
  updateWorkspaceProfile / setWorkspaceTheme），本资源不自动暴露。
  """
  use Ash.Resource,
    data_layer: AshPostgres.DataLayer,
    extensions: [AshAdmin.Resource],
    authorizers: [Ash.Policy.Authorizer],
    domain: Cgc2046.Accounts

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
      description: "成员（全局用户）ID"
    )

    attribute(:avatar_url, :string,
      allow_nil?: true,
      public?: true,
      writable?: true,
      description:
        "头像 URL（per-workspace；data URL 限 image/png|jpeg|webp|gif 且 ≤2.2MB，http(s) URL 限 2048 字符）"
    )

    attribute(:location, :string,
      allow_nil?: true,
      public?: true,
      writable?: true,
      description: "所在地（per-workspace，可编辑）"
    )

    attribute(:about, :string,
      allow_nil?: true,
      public?: true,
      writable?: true,
      description: "个人简介（per-workspace，可编辑）"
    )

    attribute(:skills, {:array, :string},
      allow_nil?: true,
      default: [],
      public?: true,
      writable?: true,
      description: "技能标签列表（per-workspace，可编辑）"
    )

    attribute(:visibility, :atom,
      allow_nil?: false,
      default: :only_me,
      public?: true,
      writable?: true,
      constraints: [one_of: [:public, :workspace, :only_me]],
      description:
        "资料可见范围（三档）：public 所有登录用户可读 / workspace 该 workspace 成员可读 / only_me 仅本人可读（默认，隐私优先）"
    )

    attribute(:ui_theme_preference, :string,
      allow_nil?: false,
      default: "dark",
      public?: true,
      writable?: true,
      description: "UI 主题偏好（per-workspace）：dark（默认）/ light，服务端持久化用于跨设备同步"
    )

    create_timestamp(:inserted_at)
    update_timestamp(:updated_at)
  end

  multitenancy do
    strategy(:attribute)
    attribute(:workspace_id)

    # 允许跨租户读取（meWorkspaces / 全局视角需要），隔离由 policy 保证
    global?(true)
  end

  relationships do
    belongs_to(:workspace, Cgc2046.Accounts.Workspace, define_attribute?: false)

    belongs_to(:user, Cgc2046.Accounts.User, define_attribute?: false)

    # visibility=:workspace 共享判断：该档案所属 workspace 的成员（目标 workspace
    # 语义，区别于 User 的"任一 workspace"）。按 workspace_id 关联到成员资格，
    # 供 ReadWorkspaceProfileByVisibility 的 exists 子查询使用。
    has_many(:workspace_memberships, Cgc2046.Accounts.WorkspaceMembership,
      source_attribute: :workspace_id,
      destination_attribute: :workspace_id
    )
  end

  validations do
    # per-workspace 主题偏好仅允许 dark | light（:string + 显式 match 校验，非 unsafe atom）
    validate(match(:ui_theme_preference, ~r/^(dark|light)$/),
      message: "must be dark or light"
    )
  end

  actions do
    defaults([:read, :update])

    create :create do
      primary?(true)
      argument(:user_id, :uuid)
      change(set_attribute(:user_id, arg(:user_id)))
    end

    update :update_profile do
      description(
        "更新当前用户在该 workspace 的资料（per-workspace）：avatarUrl/location/about/skills/visibility 可选"
      )

      require_atomic?(false)

      accept([:avatar_url, :location, :about, :skills, :visibility])

      # P1-4 头像上传最小方案：data URL 限白名单 MIME + 体积上限；http(s) URL 限长度
      validate(fn changeset, _context ->
        case Ash.Changeset.get_attribute(changeset, :avatar_url) do
          nil -> :ok
          url -> validate_avatar_url(url)
        end
      end)
    end

    update :set_ui_theme do
      description("设置当前用户在该 workspace 的 UI 主题偏好（per-workspace）：仅接受 dark | light")

      require_atomic?(false)

      accept([:ui_theme_preference])
    end
  end

  # 头像校验（自 User 迁入，P1-4 最小方案保持）：base64 data URL 直存 + 类型/大小限制
  @avatar_allowed_mime ["image/png", "image/jpeg", "image/webp", "image/gif"]
  @avatar_max_data_url_bytes 3_000_000
  @avatar_max_http_url_length 2048

  defp validate_avatar_url("data:" <> rest) do
    case String.split(rest, ";", parts: 2) do
      [mime, "base64," <> _] ->
        cond do
          mime not in @avatar_allowed_mime ->
            {:error,
             field: :avatar_url,
             message:
               "avatar data URL MIME must be one of image/png, image/jpeg, image/webp, image/gif"}

          byte_size("data:" <> rest) > @avatar_max_data_url_bytes ->
            {:error, field: :avatar_url, message: "avatar data URL too large (max ~2.2MB image)"}

          true ->
            :ok
        end

      _ ->
        {:error, field: :avatar_url, message: "avatar data URL must be base64-encoded image"}
    end
  end

  defp validate_avatar_url(url) when is_binary(url) do
    cond do
      String.starts_with?(url, "http://") or String.starts_with?(url, "https://") ->
        if byte_size(url) <= @avatar_max_http_url_length do
          :ok
        else
          {:error, field: :avatar_url, message: "avatar URL too long (max 2048 chars)"}
        end

      true ->
        {:error, field: :avatar_url, message: "avatarUrl must be a data URL or http(s) URL"}
    end
  end

  defp validate_avatar_url(_),
    do: {:error, field: :avatar_url, message: "avatarUrl must be a string"}

  identities do
    identity(:unique_profile_per_workspace_user, [:workspace_id, :user_id])
  end

  postgres do
    table("workspace_profiles")
    repo(Cgc2046.Repo)

    identity_index_names(unique_profile_per_workspace_user: "wsp_unique_ws_user_idx")
  end

  policies do
    # 读取：本人永远可读；他人按 visibility 三档（filter 阶段动态构造）。
    # 匿名处理在 ReadWorkspaceProfileByVisibility.filter(nil)（返回恒假 filter），
    # 不在此处 forbid_if——避免 expr forbid 在 filter 阶段干扰 FilterCheck（#68 教训）。
    policy action_type(:read) do
      authorize_if(Cgc2046.Accounts.Policies.ReadWorkspaceProfileByVisibility)
    end

    # 写（update_profile / set_ui_theme）：仅本人（SimpleCheck 判 user_id）+ 该 workspace 成员。
    # forbid_unless OwnWorkspaceProfile 把 owner 设为必要条件（AND），否则同 policy 内
    # 两个 authorize_if 是 OR，任意成员都能改他人档案（review HIGH-1 authz bypass 修复）。
    policy action_type(:update) do
      forbid_unless(Cgc2046.Accounts.Policies.OwnWorkspaceProfile)
      authorize_if(Cgc2046.Accounts.Policies.ActorIsWorkspaceMember)
    end
  end

  admin do
    # #113 ops 面优化：导航分组 + 列表列裁剪（默认全列横向爆炸；敏感/超大字段不列出）
    resource_group(:accounts)
    table_columns([:id, :workspace_id, :user_id, :visibility, :location, :inserted_at])
  end
end
