defmodule Cgc2046.Repo.Migrations.AddDescriptionToWorkspaces do
  @moduledoc """
  #1226：工作台门面文案（description）+ 创建工作台申请的同名可选字段。

  两列均可空、无默认、无索引：description 是自由文本（长度治理在展示层与审计
  截断），查询面不按它过滤。workspace_applications.description 仅在 approve 时
  透传为 workspace.description；purpose（申请目的）保持独立，不落工作台。
  """
  use Ecto.Migration

  def change do
    alter table(:workspaces) do
      add(:description, :text)
    end

    alter table(:workspace_applications) do
      add(:description, :text)
    end
  end
end
