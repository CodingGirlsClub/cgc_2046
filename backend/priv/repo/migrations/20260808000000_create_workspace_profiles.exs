defmodule Cgc2046.Repo.Migrations.CreateWorkspaceProfiles do
  @moduledoc """
  ADR-0004：Profile / Theme 移植为 per-workspace 租户资源。

  1. 建 `workspace_profiles` 表（workspace_id + user_id + avatar_url/location/about/skills/
     visibility/ui_theme_preference，唯一 (workspace_id, user_id)）
  2. `portfolio_items` 加 workspace_id 列（nullable 先 → 回填 → NOT NULL）
  3. 回填：每个 user 的全局 profile 字段复制到其所有 membership 的 workspace；
     portfolio_items 按 user 的所有 membership 复制成 N 条（各带对应 workspace_id）
  4. 幂等创建默认 workspace `2046`（slug=`2046`、join_policy=`open`、sponsorship_enabled=false），
     seed 六角色；owner 成员资格归属首个平台管理员（无则跳过）
  5. 回填：存量无 membership 用户 → admit 到 2046（member 角色）+ 建 WorkspaceProfile

  幂等：表/列存在守卫 + ON CONFLICT DO NOTHING（重复执行安全，沿用现有迁移风格）。

  down 可逆性声明：`add_not_null_portfolio_workspace_id` 会删除「无 membership 的
  user 的孤儿 portfolio 行」与「workspace_id IS NULL 的残留行」——这些行已物理删除，
  down 仅恢复结构（drop 列 / drop 表），不恢复数据。users 全局 profile 字段在 Phase 5
  （20260808010000_drop_user_profile_columns）单独清理，其 down 同样仅恢复结构。
  """

  use Ecto.Migration

  # 与 WorkspaceProfile 资源 identity 对齐的索引名
  @wsp_unique_index "wsp_unique_ws_user_idx"
  # 六角色模板（与 Role.role_descriptions/0 对齐；本迁移为历史迁移，不引用运行时模块）
  @design_roles [
    {"owner", "所有者：工作台管理与权限分配"},
    {"admin", "管理员：工作台日常管理与内容维护"},
    {"member", "成员：默认参与身份"},
    {"tutor", "讲师：内容与教学支持"},
    {"volunteer", "志愿者：活动与运营支持"},
    {"learner", "学员：学习与参与"}
  ]

  @default_ws_slug "2046"
  @default_ws_name "2046 社区"

  def up do
    create_workspace_profiles_table()
    add_portfolio_workspace_id()
    backfill_profiles_from_users()
    backfill_portfolio_workspace_id()
    add_not_null_portfolio_workspace_id()
    seed_default_workspace_2046()
    backfill_existing_users_to_2046()
  end

  def down do
    # 回填的用户回删：删除默认 workspace 2046 的成员资格（保留 2046 workspace 本体，
    # 避免与默认 workspace 存在性约定冲突；down 反向由后续迁移处理）。
    execute fn ->
      Ecto.Adapters.SQL.query!(
        repo(),
        """
        DELETE FROM workspace_memberships wm
        USING workspaces w
        WHERE wm.workspace_id = w.id AND w.slug = $1
        """,
        [@default_ws_slug]
      )
    end

    drop_portfolio_workspace_id()
    drop_table_if_exists(:workspace_profiles)
  end

  defp create_workspace_profiles_table do
    unless table_exists?(:workspace_profiles) do
      create table(:workspace_profiles, primary_key: false) do
        add :id, :uuid, primary_key: true, default: fragment("gen_random_uuid()")
        add :workspace_id, :uuid, null: false
        add :user_id, :uuid, null: false
        add :avatar_url, :text
        add :location, :text
        add :about, :text
        add :skills, {:array, :text}, default: []
        add :visibility, :text, null: false, default: "only_me"
        add :ui_theme_preference, :string, null: false, default: "dark"

        add :inserted_at, :utc_datetime_usec,
          null: false,
          default: fragment("(now() AT TIME ZONE 'utc')")

        add :updated_at, :utc_datetime_usec,
          null: false,
          default: fragment("(now() AT TIME ZONE 'utc')")
      end

      create unique_index(:workspace_profiles, [:workspace_id, :user_id], name: @wsp_unique_index)

      create index(:workspace_profiles, [:user_id])
    end
  end

  defp add_portfolio_workspace_id do
    unless column_exists?(:portfolio_items, :workspace_id) do
      alter table(:portfolio_items) do
        add :workspace_id, :uuid
      end
    end
  end

  defp backfill_profiles_from_users do
    execute fn ->
      # 每个 user 的全局 profile → 复制到该 user 所有 membership 的 workspace
      Ecto.Adapters.SQL.query!(
        repo(),
        """
        INSERT INTO workspace_profiles
          (id, workspace_id, user_id, avatar_url, location, about, skills, visibility,
           ui_theme_preference, inserted_at, updated_at)
        SELECT gen_random_uuid(), wm.workspace_id, wm.user_id,
               u.avatar_url, u.location, u.about, u.skills, u.visibility, u.ui_theme_preference,
               now(), now()
        FROM workspace_memberships wm
        JOIN users u ON u.id = wm.user_id
        ON CONFLICT (workspace_id, user_id) DO NOTHING
        """
      )
    end
  end

  defp backfill_portfolio_workspace_id do
    execute fn ->
      # 每条 portfolio → 复制到该 user 的所有 membership 的 workspace
      # （按 user 去重的 membership workspace 列表，避免同 user 多 membership 同 ws 重复）
      Ecto.Adapters.SQL.query!(
        repo(),
        """
        INSERT INTO portfolio_items
          (id, workspace_id, user_id, title, description, url, icon, inserted_at, updated_at)
        SELECT gen_random_uuid(), wm.workspace_id, p.user_id, p.title, p.description, p.url,
               p.icon, now(), now()
        FROM portfolio_items p
        JOIN (
          SELECT user_id, workspace_id
          FROM workspace_memberships
          GROUP BY user_id, workspace_id
        ) wm ON wm.user_id = p.user_id
        WHERE p.workspace_id IS NULL
        ON CONFLICT DO NOTHING
        """
      )
    end
  end

  defp add_not_null_portfolio_workspace_id do
    # 已有全部回填后收紧 NOT NULL；无 membership 的 user 的 portfolio 已无归属（空 ws），
    # 这些行由 backfill 前保留，此处改约束前删除孤儿（无任何 membership 的 user 的 portfolio）
    execute fn ->
      Ecto.Adapters.SQL.query!(
        repo(),
        """
        DELETE FROM portfolio_items p
        WHERE p.workspace_id IS NULL
          AND NOT EXISTS (
            SELECT 1 FROM workspace_memberships wm WHERE wm.user_id = p.user_id
          )
        """
      )

      Ecto.Adapters.SQL.query!(
        repo(),
        """
        DELETE FROM portfolio_items
        WHERE workspace_id IS NULL
        """
      )
    end

    alter table(:portfolio_items) do
      modify :workspace_id, :uuid, null: false
    end
  end

  defp seed_default_workspace_2046 do
    execute fn ->
      # 幂等创建默认 workspace
      Ecto.Adapters.SQL.query!(
        repo(),
        """
        INSERT INTO workspaces (id, slug, name, join_policy, sponsorship_enabled, inserted_at, updated_at)
        SELECT gen_random_uuid(), $1, $2, 'open', false, now(), now()
        WHERE NOT EXISTS (SELECT 1 FROM workspaces WHERE slug = $1)
        """,
        [@default_ws_slug, @default_ws_name]
      )

      # seed 六角色（ON CONFLICT 幂等）
      for {name, description} <- @design_roles do
        Ecto.Adapters.SQL.query!(
          repo(),
          """
          INSERT INTO roles (id, workspace_id, name, description, inserted_at, updated_at)
          SELECT gen_random_uuid(), w.id, $1, $2, now(), now()
          FROM workspaces w
          WHERE w.slug = $3
          ON CONFLICT (workspace_id, name) DO NOTHING
          """,
          [name, description, @default_ws_slug]
        )
      end

      # owner 成员资格归属首个平台管理员（无平台管理员则跳过）
      Ecto.Adapters.SQL.query!(
        repo(),
        """
        INSERT INTO workspace_memberships (id, workspace_id, user_id, inserted_at, updated_at)
        SELECT gen_random_uuid(), w.id, u.id, now(), now()
        FROM workspaces w
        CROSS JOIN LATERAL (
          SELECT id FROM users
          WHERE is_platform_admin = true
          ORDER BY inserted_at ASC
          LIMIT 1
        ) u
        WHERE w.slug = $1
          AND NOT EXISTS (
            SELECT 1 FROM workspace_memberships wm
            WHERE wm.workspace_id = w.id AND wm.user_id = u.id
          )
        """,
        [@default_ws_slug]
      )

      # 平台管理员 → owner 角色（membership_roles 需 workspace_id，取 membership 所属）
      Ecto.Adapters.SQL.query!(
        repo(),
        """
        INSERT INTO membership_roles (id, membership_id, role_id, workspace_id, inserted_at, updated_at)
        SELECT gen_random_uuid(), wm.id, r.id, wm.workspace_id, now(), now()
        FROM workspace_memberships wm
        JOIN workspaces w ON w.id = wm.workspace_id
        JOIN users u ON u.id = wm.user_id
        JOIN roles r ON r.workspace_id = wm.workspace_id AND r.name = 'owner'
        WHERE w.slug = $1 AND u.is_platform_admin = true
          AND NOT EXISTS (
            SELECT 1 FROM membership_roles mr
            WHERE mr.membership_id = wm.id AND mr.role_id = r.id
          )
        """,
        [@default_ws_slug]
      )
    end
  end

  defp backfill_existing_users_to_2046 do
    execute fn ->
      # 存量无 membership 用户 → admit 到 2046（member 角色）+ 建 WorkspaceProfile
      Ecto.Adapters.SQL.query!(
        repo(),
        """
        WITH ws AS (SELECT id FROM workspaces WHERE slug = $1),
        candidate AS (
          SELECT u.id AS user_id, ws.id AS workspace_id
          FROM users u CROSS JOIN ws
          WHERE NOT EXISTS (
            SELECT 1 FROM workspace_memberships wm WHERE wm.user_id = u.id
          )
        ),
        new_memberships AS (
          INSERT INTO workspace_memberships (id, workspace_id, user_id, inserted_at, updated_at)
          SELECT gen_random_uuid(), workspace_id, user_id, now(), now()
          FROM candidate
          ON CONFLICT (workspace_id, user_id) DO NOTHING
          RETURNING id, workspace_id, user_id
        ),
        member_roles AS (
          INSERT INTO membership_roles (id, membership_id, role_id, workspace_id, inserted_at, updated_at)
          SELECT gen_random_uuid(), nm.id, r.id, nm.workspace_id, now(), now()
          FROM new_memberships nm
          JOIN roles r ON r.workspace_id = nm.workspace_id AND r.name = 'member'
          ON CONFLICT DO NOTHING
        )
        INSERT INTO workspace_profiles (id, workspace_id, user_id, avatar_url, location, about,
                                        skills, visibility, ui_theme_preference, inserted_at, updated_at)
        SELECT gen_random_uuid(), nm.workspace_id, nm.user_id,
               u.avatar_url, u.location, u.about, u.skills, u.visibility, u.ui_theme_preference,
               now(), now()
        FROM new_memberships nm
        JOIN users u ON u.id = nm.user_id
        ON CONFLICT (workspace_id, user_id) DO NOTHING
        """,
        [@default_ws_slug]
      )
    end
  end

  defp table_exists?(table) do
    repo().query!(
      "SELECT 1 FROM information_schema.tables WHERE table_schema = 'public' AND table_name = $1",
      [to_string(table)]
    ).num_rows > 0
  end

  defp column_exists?(table, column) do
    repo().query!(
      "SELECT 1 FROM information_schema.columns WHERE table_schema = 'public' AND table_name = $1 AND column_name = $2",
      [to_string(table), to_string(column)]
    ).num_rows > 0
  end

  defp drop_table_if_exists(table) do
    if table_exists?(table) do
      drop table(table)
    end
  end

  defp drop_portfolio_workspace_id do
    if column_exists?(:portfolio_items, :workspace_id) do
      alter table(:portfolio_items) do
        remove :workspace_id
      end
    end
  end
end
