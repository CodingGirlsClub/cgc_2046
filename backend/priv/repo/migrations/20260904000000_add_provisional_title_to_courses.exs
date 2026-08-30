defmodule Cgc2046.Repo.Migrations.AddProvisionalTitleToCourses do
  use Ecto.Migration

  @doc """
  role-agent-journeys-v2 S3（R21/AE1 零输入草稿）：

  - `courses.provisional_title`：零输入草稿标记——create 缺省 title 时 domain
    生成临时占位标题（未命名课程 <hex8>）并置 true；设置真实标题即清除；
    launch 命名门拦截占位标题课程发布。存量行恒有真实标题，default false 即正确值。

  CONTRIBUTING §4：幂等（add_if_not_exists）+ 可逆（显式 down）。
  """
  def up do
    alter table(:courses) do
      add_if_not_exists :provisional_title, :boolean, null: false, default: false
    end
  end

  def down do
    alter table(:courses) do
      remove_if_exists :provisional_title, :boolean
    end
  end
end
