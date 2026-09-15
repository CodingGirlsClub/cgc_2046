defmodule Cgc2046.Repo.Migrations.BackfillCheckInCodes do
  use Ecto.Migration

  import Ecto.Query

  # 存量 Event 报名的核销码回填（KTD5：码在 create 生成，只覆盖本迁移之后创建的
  # 报名；此前已 confirmed 的 Event 报名码恒为 NULL → 主理人输码稳定「码无效」，
  # 参与者永久无法核销、押金无法因到场而退）。
  #
  # 口径：只回填 `event_id IS NOT NULL`（course 报名按设计无码）且 status 属于
  # 「可能被核销」的集合（confirmed / pending / payment_pending —— 前两者可能在
  # 未来落 confirmed；cancelled/expired/rejected 不回填）。同场唯一由唯一索引
  # enrollments_unique_check_in_code_index 兜底：逐行生成 + 冲突重试，超限即 raise
  # 让迁移整体失败（回填不完备不得静默放过）。
  #
  # 必须 @disable_ddl_transaction：撞码重试依赖 UPDATE 报错后连接仍可用，而
  # Postgres 在事务内任何错误都会中止事务（后续查询只得 in_failed_sql_transaction）
  # ——事务内重试是死代码，一次撞码即迁移失败卡死部署（#554）。逐语句自动提交后
  # 重试真正生效；失败重跑只选 check_in_code IS NULL 的行，断点续跑天然幂等。
  # 回填是纯数据写（无 DDL），符合 backend/AGENTS.md「大表回填与 DDL 拆开」纪律。
  @disable_ddl_transaction true
  @max_attempts 20
  @backfill_statuses ["confirmed", "pending", "payment_pending"]

  def up do
    ids =
      repo().all(
        from(e in "enrollments",
          where:
            not is_nil(e.event_id) and is_nil(e.check_in_code) and
              e.status in ^@backfill_statuses,
          select: {e.id, e.event_id}
        )
      )

    missing_after =
      Enum.reduce(ids, 0, fn {id, _event_id}, failed ->
        if assign_code(id), do: failed, else: failed + 1
      end)

    if missing_after > 0 do
      raise "check-in code backfill incomplete: #{missing_after} enrollment(s) still without a code"
    end
  end

  # 回滚不清码：码已下发（参与者/主理人可见），清掉只会造成「码突然失效」；
  # 列本身由 add_check_in_code_to_enrollments 的 down 负责（数据面不可逆，见 release runbook）。
  def down, do: :ok

  defp assign_code(enrollment_id) do
    Enum.reduce_while(1..@max_attempts, false, fn _attempt, _acc ->
      # 与 app 层同一生成器（crypto 无偏重采，保留前导零；KTD5 单源）。
      # 撞码路径的回归证据在 BackfillCheckInCodesMigrationTest（触发器 + sequence
      # 注入唯一冲突——迁移在 Migrator Runner 进程执行，进程字典 stub 不可达）
      code = Cgc2046.RandomCode.generate()

      case repo().query(
             "UPDATE enrollments SET check_in_code = $1 WHERE id = $2 AND check_in_code IS NULL",
             [code, enrollment_id]
           ) do
        {:ok, %{num_rows: 1}} -> {:halt, true}
        # 唯一索引冲突（同场同码）→ 重试；行已被并发回填（num_rows 0）→ 视为完成
        {:ok, %{num_rows: 0}} -> {:halt, true}
        {:error, %Postgrex.Error{postgres: %{code: :unique_violation}}} -> {:cont, false}
        {:error, reason} -> raise "check-in code backfill failed: #{inspect(reason)}"
      end
    end)
  end
end
