defmodule Cgc2046.Repo.Migrations.BackfillVisibilityOnlyMe do
  @moduledoc """
  visibility 三档改造（2026-08-02）：
  - 存量数据回填：旧枚举 `workspace_members` / `workspace_public` 全部回填为 `only_me`（隐私优先默认）。
    存量均为开发/验收测试账号，回填 only_me 符合"默认仅本人可见"的新语义。
  - DB 列默认值：由 `workspace_members` 改为 `only_me`（新注册用户默认仅本人可见）。

  幂等：UPDATE 重复执行结果不变；modify 默认值重复设置相同值安全。
  """

  use Ecto.Migration

  def up do
    execute(
      "UPDATE users SET visibility = 'only_me' WHERE visibility IN ('workspace_members', 'workspace_public')",
      "UPDATE users SET visibility = 'workspace_members' WHERE visibility = 'only_me'"
    )

    alter table(:users) do
      modify :visibility, :text, null: false, default: "only_me"
    end
  end

  def down do
    # 不可逆（无法区分回填前的原始值），仅恢复默认值
    alter table(:users) do
      modify :visibility, :text, null: false, default: "workspace_members"
    end
  end
end
