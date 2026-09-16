defmodule Cgc2046.Repo.Migrations.ResyncCapacityLedgerCache do
  use Ecto.Migration

  # 存量名额账本缓存列的一次性收敛（issue #587）。
  #
  # 背景：锁死规则传播（`Initiatives.RuleInheritance.propagate_rule_change/4`）
  # 此前是一条不发信号的裸 SQL，`deadline_rule` 改动只写 `events` 真值、不更新
  # `admission_capacity_ledgers` 的三列缓存（status / capacity /
  # registration_deadline）。报名截止的执法读的是缓存列（`CapacityLedger.reserve/2`
  # 三守卫之一），于是「放宽报名期」的场在缓存陈旧时被 CAS 误拒——报名明明没
  # 截止却报不了名。对账规12（ledger_cache_drift）只发现不修复，这些漂移会长期
  # 驻留。
  #
  # 本迁移只做一件事：把缓存三列按 offering 真值覆盖式收敛（缓存是派生态，
  # 真值永远是 events / courses）。**绝不写 events / courses**；`occupancy` 与
  # `sync_version` 是账本自有权威值，不动。
  #
  # 幂等与空跑：`WHERE … IS DISTINCT FROM` 只命中真正漂移的行——干净库空跑，
  # 重复执行第二遍零行更新，不回滚（`down` 无事可做）。纯数据写、无 DDL，
  # 无并发风险（账本表一行/offering，量级与 offerings 同阶）。
  #
  # 防再发生不靠本迁移：规则传播已改为在同一事务内直连
  # `CapacityLedger.sync_offering_cache/1`（有意不发 offering.capacity_changed）。
  # 缺失账本行（对账规⑧）不在本次范围。
  def up do
    execute("""
    UPDATE admission_capacity_ledgers l
    SET status = e.status,
        capacity = e.capacity,
        registration_deadline = e.registration_deadline,
        updated_at = NOW()
    FROM events e
    WHERE l.offering_kind = 'event'
      AND l.offering_id = e.id
      AND (l.status IS DISTINCT FROM e.status
           OR l.capacity IS DISTINCT FROM e.capacity
           OR l.registration_deadline IS DISTINCT FROM e.registration_deadline)
    """)

    execute("""
    UPDATE admission_capacity_ledgers l
    SET status = c.status,
        capacity = c.capacity,
        registration_deadline = c.registration_deadline,
        updated_at = NOW()
    FROM courses c
    WHERE l.offering_kind = 'course'
      AND l.offering_id = c.id
      AND (l.status IS DISTINCT FROM c.status
           OR l.capacity IS DISTINCT FROM c.capacity
           OR l.registration_deadline IS DISTINCT FROM c.registration_deadline)
    """)
  end

  # 缓存列向真值收敛不可逆（也不需要回退：回退只会把已修正的缓存重新弄脏）。
  def down, do: :ok
end
