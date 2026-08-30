defmodule Cgc2046.Repo.Migrations.AddCurrentRevisionIdToCourses do
  use Ecto.Migration

  @doc """
  role-agent-journeys-v2 S6（R29）：课程当前 published 版本引用。

  - `courses.current_revision_id`：教研发布步经 Courses 发布端口
    `bind_revision_for_publish/3` 写入（唯一写入口 `:bind_current_revision`）；
    nil = 从未经教研流程发布的存量课程（公开 courseMap 回退草稿读面）。
  - 纯 uuid 无 FK：与 resource snapshot 一致（Courses→Curriculum 跨域引用，
    引用完整性由发布事务内的端口写入保证，无级联删除语义——revision 恒不删）。

  CONTRIBUTING §4：幂等（add_if_not_exists）+ 可逆（显式 down）。
  """
  def up do
    alter table(:courses) do
      add_if_not_exists :current_revision_id, :uuid
    end
  end

  def down do
    alter table(:courses) do
      remove_if_exists :current_revision_id, :uuid
    end
  end
end
