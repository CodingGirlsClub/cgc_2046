defmodule Cgc2046.Repo.Migrations.AddEventsDetachedRuleProvenance do
  @moduledoc """
  #624 解除挂载语义（方案 C）：events 增加可空 jsonb 列 `detached_rule_provenance`。

  语义单一：**只描述「已解除挂载后仍留在场上的强制值」**。detach 不回收平台
  锁死规则强制写入的值（方案 C：值留在 Event 上、回归普通可编辑字段），本列
  记录这些值来自哪个 Initiative 的哪条锁死规则，形状与 #596 写响应 `applied`
  同源：

      {"initiative": {"id": "...", "name": "...", "slug": "..."},
       "fields": {"min_age": {"value": 18, "source": "locked"}, ...}}

  生命周期（写入与清除全在 `Initiative.RuleInheritance.prepare_event_changes/2`
  同一事务内）：

  - detach（`initiative_id` 非空 → nil）时写入；无 locked 字段则保持 NULL；
  - 场主显式改写标记内某字段 → 逐字段删除；键空 → 整列 NULL；
  - 重挂载（nil → 非空）→ 整列 NULL（值重新归新 Initiative 治理）。

  迁移安全性：列可空、无默认值——Postgres 11+ 的 `ADD COLUMN` 只改目录，不
  重写表、不长时间持排他锁，存量行天然 NULL（无「存量行语义」需要回填）；
  故不需要 NOT VALID / 分批处理。索引不涉及。
  """
  use Ecto.Migration

  def up do
    alter table(:events) do
      add :detached_rule_provenance, :map
    end
  end

  def down do
    alter table(:events) do
      remove :detached_rule_provenance
    end
  end
end
