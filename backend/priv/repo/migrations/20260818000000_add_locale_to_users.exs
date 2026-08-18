defmodule Cgc2046.Repo.Migrations.AddLocaleToUsers do
  @moduledoc """
  i18n Phase 1：users.locale 界面语言偏好（BCP47 对外命名 zh-CN | en）。

  - 可空：null = 未设置（存量用户全部 null，前端协商链回退 cookie/Accept-Language/zh-CN）。
  - 合法值约束在 Ash 资源层（update_locale action 的 one_of validation），
    与 email 格式校验同层，不加 DB CHECK（Ash 单点，迁移可逆）。
  """

  use Ecto.Migration

  def up do
    alter table(:users) do
      add :locale, :text
    end
  end

  def down do
    alter table(:users) do
      remove :locale
    end
  end
end
