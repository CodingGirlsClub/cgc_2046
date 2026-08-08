defmodule Cgc2046.Repo.Migrations.RelaxUsersAuthAddPhone do
  @moduledoc """
  users 表放宽（Phase 1 身份基座）：

  - email / hashed_password 放宽可空（小程序手机号用户无邮箱/密码；
    password 策略注册仍强制 email——由 register action 的 require_attributes 在策略层兜底）
  - 新增 phone（明文，v1 已评审接受）+ 部分唯一索引 WHERE phone IS NOT NULL
    （phone 是小程序登录的 User 锚；NULL 不参与唯一约束，存量 web 用户不受影响）

  email 唯一索引 users_unique_email_index 保留不动。
  幂等模式复刻 20260804000000_add_invitations.exs。
  """

  use Ecto.Migration

  defp index_exists?(table, name) do
    repo()
    |> Ecto.Adapters.SQL.query!(
      "SELECT 1 FROM pg_indexes WHERE schemaname = 'public' AND tablename = $1 AND indexname = $2",
      [to_string(table), to_string(name)]
    )
    |> then(fn result -> result.num_rows > 0 end)
  end

  defp column_exists?(table, column) do
    repo()
    |> Ecto.Adapters.SQL.query!(
      "SELECT 1 FROM information_schema.columns WHERE table_schema = 'public' AND table_name = $1 AND column_name = $2",
      [to_string(table), to_string(column)]
    )
    |> then(fn result -> result.num_rows > 0 end)
  end

  def up do
    alter table(:users) do
      modify :email, :citext, null: true
      modify :hashed_password, :text, null: true
    end

    unless column_exists?(:users, :phone) do
      alter table(:users) do
        add :phone, :text
      end
    end

    # 部分唯一索引：phone IS NOT NULL 才参与（索引名对齐 AshPostgres identity 映射约定）
    unless index_exists?(:users, "users_unique_phone_index") do
      create unique_index(:users, [:phone],
               name: "users_unique_phone_index",
               where: "phone IS NOT NULL"
             )
    end
  end

  def down do
    drop_if_exists unique_index(:users, [:phone], name: "users_unique_phone_index")

    if column_exists?(:users, :phone) do
      # 回滚本迁移 == 回滚小程序特性：phone-only 用户（email IS NULL AND phone IS NOT NULL，
      # 即小程序手机号建号的用户）及其关联数据随特性一并删除——这是恢复
      # email/hashed_password NOT NULL 约束的唯一自洽语义。web 用户（email 非空）不受影响。
      #
      # 单语句 CTE 级联：references 未带 on_delete 的外键默认 NO ACTION（语句末尾才做
      # FK 校验），故同一语句内先删子表再删 users 可通过约束检查。
      # user_identities / portfolio_items 的外键是 delete_all 级联，显式删除仅为清晰。
      # tokens 无 FK（subject 为文本），按 'user?id=<uuid>' 前缀精确删除。
      repo().query!(
        """
        WITH doomed AS (
          SELECT id FROM users WHERE email IS NULL AND phone IS NOT NULL
        ),
        del_membership_roles AS (
          DELETE FROM membership_roles WHERE membership_id IN (
            SELECT id FROM workspace_memberships WHERE user_id IN (SELECT id FROM doomed)
          )
        ),
        del_memberships AS (
          DELETE FROM workspace_memberships WHERE user_id IN (SELECT id FROM doomed)
        ),
        del_profiles AS (
          DELETE FROM workspace_profiles WHERE user_id IN (SELECT id FROM doomed)
        ),
        del_join_requests AS (
          DELETE FROM join_requests WHERE user_id IN (SELECT id FROM doomed)
        ),
        del_portfolio_items AS (
          DELETE FROM portfolio_items WHERE user_id IN (SELECT id FROM doomed)
        ),
        del_identities AS (
          DELETE FROM user_identities WHERE user_id IN (SELECT id FROM doomed)
        ),
        del_tokens AS (
          DELETE FROM tokens WHERE subject IN (SELECT 'user?id=' || id::text FROM doomed)
        )
        DELETE FROM users WHERE id IN (SELECT id FROM doomed)
        """,
        []
      )

      alter table(:users) do
        remove(:phone)
      end
    end

    alter table(:users) do
      modify :email, :citext, null: false
      modify :hashed_password, :text, null: false
    end
  end
end
