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
  # 让迁移整体回滚（回填不完备不得静默放过）。
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
      code = "~6..0B" |> :io_lib.format([:rand.uniform(1_000_000) - 1]) |> IO.iodata_to_binary()

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
