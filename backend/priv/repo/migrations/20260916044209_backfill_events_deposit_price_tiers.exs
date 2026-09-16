defmodule Cgc2046.Repo.Migrations.BackfillEventsDepositPriceTiers do
  # 分批阈值（owner 裁决 #3）：≤ 阈值逐行 dump 清理前 JSON（可手工还原）；
  # > 阈值走分批 UPDATE + 聚合日志（每批只记区间与计数，不灌 JSON）。
  # 放在 moduledoc 之前：文档里引用了这两个值。
  @row_log_limit 100
  @batch_size 100

  @predicate "deposit_enabled AND price_tiers <> '[]'::jsonb"

  @moduledoc """
  #597 I2 存量回填：押金场清空 `price_tiers`（「押金开 + 档位非空」在域侧被钉死
  之前的历史残留）。

  ## 回填的作用（与下一个迁移的分工）

  紧随其后的 `20260916044210_add_events_deposit_excludes_price_tiers_check` 给
  events 加 CHECK
  `NOT (deposit_enabled AND NOT pricing_enabled AND price_tiers <> '[]'::jsonb)`。
  CHECK 即便以 **NOT VALID** 加入，仍对**每次 UPDATE 产生的新行版本**生效——存量
  违规行会连「改标题」都被拒，直接违反 `Events.PaymentModeValidation` 明写的
  「存量行不被无关编辑永久锁死」纪律。NOT VALID 只豁免 ADD 那一刻的存量校验，
  不豁免后续写入。

  分工：**本迁移**做批量清理与逐行落档（分批、独立事务，避免大表回填与 DDL 挤在
  同一迁移里长时间持锁，AGENTS.md「大表回填与 DDL 拆开」）；**CHECK 迁移**在
  `ADD` 之后、`VALIDATE` 之前做一次幂等补清，负责部署窗口内的新残留（见下）——
  故即使本迁移被跳过，CHECK 迁移也会清干净再 VALIDATE；本迁移的价值是分批、
  落档与把重活挪出 DDL 迁移。

  **部署窗口**：pre-deploy 钩子在**新镜像启动前**跑迁移，此时**旧容器仍在服务**
  （`.kamal/hooks/pre-deploy`，Kamal blue-green）。旧代码没有 I2 校验，故本迁移
  提交后、CHECK 提交前仍可能被旧 pod 写入新的残留行（straggler）。两个迁移与
  代码必须**同一次部署**：

  - CHECK 先行而代码未跟 → 旧 pod 撞上已生效的 CHECK（报 I1 文案，安全但语义不准）；
  - 代码先行而 CHECK 未落 → 并发写偏斜窗口裸奔。

  ## 可还原性（owner 裁决 #3 要求）

  受影响行 ≤ #{@row_log_limit} 时：`id` 与**清理前** `price_tiers` 逐行打进部署
  日志（`RAISE NOTICE`）。> 阈值时改**分批 UPDATE + 聚合日志**（每批只记区间与
  计数），不灌 JSON——该规模下的还原依据是上线前的 prod 普查结果（见下）。

  ## 上线前置条件（非可选）

  合并前由 owner/ops 在 prod 只读连接跑同一判据的普查，结果贴回 issue #597：

      SELECT id, workspace_id, status, deposit_enabled, deposit_amount_cents,
             jsonb_array_length(price_tiers) AS tier_count, updated_at
      FROM events
      WHERE deposit_enabled AND price_tiers <> '[]'::jsonb
      ORDER BY updated_at DESC;

  对称残留（deposit 关但 `deposit_amount_cents` 非空 / pricing 开但金额非空）属
  惰性数据，**不清理、不加约束**（#597 裁决：I6/I7 不立不变量），口径查询：

      SELECT count(*) FILTER (WHERE deposit_enabled AND pricing_enabled)                    AS both_true_must_be_0,
             count(*) FILTER (WHERE NOT deposit_enabled AND deposit_amount_cents IS NOT NULL) AS amount_residue,
             count(*) FILTER (WHERE pricing_enabled AND deposit_amount_cents IS NOT NULL)     AS pricing_with_amount,
             count(*) FILTER (WHERE NOT deposit_enabled AND NOT pricing_enabled
                                AND price_tiers <> '[]'::jsonb)                               AS dormant_tiers
      FROM events;

  ## 幂等 / 回滚

  判据只命中违规行，重复执行是空操作；`@disable_ddl_transaction true` 下逐语句提交，
  中途失败重跑收敛（已清的行不再命中）。`down` 为 no-op：档位 JSON 不可逆，还原
  依据只有 up 的部署日志留档。
  """
  use Ecto.Migration

  # 分批生效的前提（见 clear_in_batches 注释）：默认 DDL 事务会把整迁移包成一个事务
  @disable_ddl_transaction true

  def up do
    total = residual_count()

    if total <= @row_log_limit do
      clear_with_row_dump(total)
    else
      clear_in_batches(total)
    end
  end

  defp residual_count do
    repo().query!("SELECT count(*) FROM events WHERE #{@predicate}").rows
    |> List.first()
    |> List.first()
  end

  # ≤ 阈值：逐行 NOTICE（id + 清理前 price_tiers）后单条 UPDATE。
  defp clear_with_row_dump(total) do
    execute("""
    DO $$
    DECLARE
      row_record RECORD;
      affected INTEGER := 0;
    BEGIN
      RAISE NOTICE '[#597 backfill] deposit events with residual price_tiers: %', #{total};

      FOR row_record IN
        SELECT id, price_tiers FROM events
         WHERE #{@predicate}
         ORDER BY id
      LOOP
        RAISE NOTICE '[#597 backfill] event % price_tiers before clear: %',
          row_record.id, row_record.price_tiers;
      END LOOP;

      UPDATE events
         SET price_tiers = '[]'::jsonb, updated_at = NOW()
       WHERE #{@predicate};

      GET DIAGNOSTICS affected = ROW_COUNT;
      RAISE NOTICE '[#597 backfill] cleared % row(s)', affected;
    END $$;
    """)
  end

  # > 阈值：分批。**必须** `@disable_ddl_transaction true`：否则 Ecto.Migrator 会把
  # 整个迁移包在一个事务里，`repo().query!` 逐条提交的只是 savepoint 级语句，
  # 行锁/WAL 仍持到迁移结束（分批就白做了；AGENTS.md「大表回填与 DDL 拆开、分批」
  # 的反例正是 20260906000003）。置真后每条语句各自事务，批间断锁；迁移本身幂等，
  # 中途失败重跑安全。
  # 每批只记计数 + 首个 id；「清理前档位」不落日志——该规模下体积不可控，还原依靠
  # 上线前的普查结果（见 moduledoc「上线前置条件」）。straggler 由 CHECK 迁移兜底。
  defp clear_in_batches(total) do
    IO.puts("[#597 backfill] #{total} residual row(s) > #{@row_log_limit}: batched clear")

    # 上限：初始批数 + 5 轮余量（并发去违规会让某批空转；超过上限交给 CHECK 迁移补清）
    clear_batch(0, nil, div(total, @batch_size) + 5)
  end

  defp clear_batch(cleared, first_id, batches_left) do
    if batches_left <= 0 do
      IO.puts(
        "[#597 backfill] batched clear hit iteration cap: cleared #{cleared}, " <>
          "remaining #{residual_count()} (由 #597 CHECK 迁移的 straggler 补清兜底)"
      )
    else
      # 判据必须同时出现在**外层** WHERE：批间有并发写（部署窗口内的旧 pod）把某行改成
      # 非违规（如 pricing_enabled=true + 档位）时，READ COMMITTED 的 EPQ 只重查外层
      # qual——只写 `id IN (子查询)` 会把刚配好的档位清掉，造出
      # `pricing_enabled=true, price_tiers=[]`（PriceTiersValidation 会永久拒绝该行的
      # 后续更新）。外层再判一次 → 去违规行被跳过。
      %{rows: rows} =
        repo().query!(
          """
          UPDATE events SET price_tiers = '[]'::jsonb, updated_at = NOW()
           WHERE #{@predicate}
             AND id IN (
               SELECT id FROM events WHERE #{@predicate} ORDER BY id LIMIT #{@batch_size}
             )
          RETURNING id
          """,
          [],
          log: false
        )

      # id 由 Postgrex 以 16 字节 binary 返回，解成 UUID 字符串再进日志
      ids = Enum.map(rows, &(&1 |> List.first() |> Ecto.UUID.load!()))
      cleared = cleared + length(ids)
      first_id = first_id || List.first(ids)

      # 空批不等于清完：被 EPQ 跳过的行不进 RETURNING，故再看一次剩余计数。
      # 仍有剩余就继续（子查询每条语句重跑），直到清空或触上限。
      if rows == [] and residual_count() == 0 do
        IO.puts(
          "[#597 backfill] cleared #{cleared} row(s) in batches " <>
            "(aggregate logging; first id #{inspect(first_id)})"
        )
      else
        clear_batch(cleared, first_id, batches_left - 1)
      end
    end
  end

  def down do
    # 不可逆：清理前的档位 JSON 只存在于 up 的部署日志（见 moduledoc）。
    :ok
  end
end
