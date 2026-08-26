defmodule Cgc2046.Repo.Migrations.AddRegisterToPhoneVerificationPurpose do
  use Ecto.Migration

  @doc """
  手机号注册（/register 邮箱 → 手机号）：phone_verification_purpose 枚举
  加 'register'。原生 PG enum 加值是纯增量（无锁表、无重写）。
  """
  def up do
    execute "ALTER TYPE phone_verification_purpose ADD VALUE IF NOT EXISTS 'register'"
  end

  def down do
    # PG 不支持 DROP VALUE；回滚由 squash baseline 重建枚举（本迁移不可逆，
    # 已加值仅影响新写入行的取值域，不回滚数据）。
    execute ""
  end
end
