defmodule Cgc2046.FkOnDeleteGuardTest do
  use Cgc2046.DataCase, async: true

  @moduledoc """
  FK 契约全仓守卫（#724）：resource `belongs_to`/`references` DSL ↔ `pg_constraint` 双向。

  方向 = **DSL 期望 → DB 实际**（不是反向从手写 migration 出发），因为 DB 侧 FK 由
  手写 migration 承载（squash baseline + 20260913155651 等），而
  `mix ash_postgres.generate_migrations --check` 比对的是 snapshot、**不比对 DB**
  （同 #611 的 identity 索引守卫）："snapshot 记 null 而 DB 实为 CASCADE / SET NULL"
  这类漂移它看不见——#724 的 37 列正是此形态（未声明 on_delete 时 snapshot 记 null，
  未来 generator 若触碰该列会生成 NO ACTION 版 modify 造成行为回退）。

  期望集合的推导与生成器同源（`deps/ash_postgres/.../migration_generator.ex:3930`
  起）：**每个 `belongs_to`**（且 source/destination 同 repo）产出一条 reference，
  动作 = `references do reference(:x, on_delete: ...) end` 的声明值，**未声明 = 生成
  迁移不打印 on_delete = Ecto 不写 ON DELETE 子句 = PG 默认 NO ACTION**；
  `ignore?: true` 的 relationship 不产出约束。

  四类关系被完整划入四个互斥桶（任一侧变动都红，故不可能空集合假绿）：

  | 桶 | DSL 有 relationship | DB 有 FK | 断言 |
  |---|---|---|---|
  | 对齐主体 | 是 | 是 | `confdeltype` == 声明值（未声明 → `a`） |
  | `@db_only_fks` | 否（仅 attribute） | 是 | DB 动作逐列登记并钉住 |
  | `@no_db_fk_relationships` | 是 | 否 | DB 无约束（登记理由）|
  | `ignore?: true` | 是（显式忽略）| 否 | DB 不得有约束 |

  后两张表是**报备清单而非豁免**：条目必须写明理由、必须与 DB 现状相符，DB 侧一变
  （补了 FK / 加了约束）就红，逼一次显式对齐。#745 完成处置：@db_only_fks 6 列补
  relationship（零 DDL 纯追平）、@no_db_fk_relationships 9 列补 FK migration，两清单
  双双清空、条目移入对齐主体；机制保留给未来缺口。
  """

  # DB-only FK：列在 DB 有 FK，但 resource 里只有 `attribute`、没有 relationship，
  # `references do` 无从挂载。形如 {table, column, 期望 on_delete, 理由}
  # #745 已清空：原 6 列（event_moderators.workspace_id / events.created_by /
  # speaker_invitations.accepted_by / sponsorship_deliveries.workspace_id /
  # notification_deliveries.user_id / signal_idempotency.workspace_id）全部补上
  # belongs_to + references 条目（DB 约束本就存在，零 DDL 纯追平），移入对齐主体。
  # 后续新缺口按原格式登记于此。
  @db_only_fks []

  # 反向缺口：resource 声明了 belongs_to（→ snapshot 有 reference），但手写 migration
  # 只写了裸 `add :col, :uuid`、从未建 FK。形如 {table, column, relationship, 理由}
  @no_db_fk_relationships [
    {"curriculum_outputs", "workflow_run_id", :workflow_run,
     "squash baseline 只给 workspace_id 建 references，workflow_run_id 是裸 :uuid"},
    {"invitations", "inviter_id", :inviter,
     "squash baseline 只给 workspace_id 建 references，inviter_id 是裸 :uuid"},
    {"invitations", "accepted_by", :accepted_by_user,
     "squash baseline 只给 workspace_id 建 references，accepted_by 是裸 :uuid"},
    {"portfolio_items", "workspace_id", :workspace,
     "squash baseline 只给 user_id 建 references，workspace_id 是裸 :uuid"},
    {"workspace_profiles", "workspace_id", :workspace, "squash baseline 建表两列皆裸 :uuid（该表无任何 FK）"},
    {"workspace_profiles", "user_id", :user, "squash baseline 建表两列皆裸 :uuid（该表无任何 FK）"},
    {"mcp_pending_operations", "user_id", :user,
     "squash baseline 建表 user_id 裸 :uuid（mcp_* 三表均无 FK）"},
    {"mcp_tokens", "user_id", :user, "squash baseline 建表 user_id 裸 :uuid（mcp_* 三表均无 FK）"},
    {"mcp_tool_call_logs", "user_id", :user, "squash baseline 建表 user_id 裸 :uuid（mcp_* 三表均无 FK）"}
  ]

  # 未声明 on_delete → 生成迁移不打印 on_delete → Ecto 不写 ON DELETE 子句 → NO ACTION
  defp confdeltype(nil), do: "a"
  defp confdeltype(:nothing), do: "a"
  defp confdeltype(:delete), do: "c"
  defp confdeltype(:nilify), do: "n"
  defp confdeltype({:nilify, _columns}), do: "n"
  defp confdeltype(:restrict), do: "r"

  defp confdeltype(other) do
    raise "未映射的 references on_delete #{inspect(other)}——本守卫需同步 ash_postgres 新语义"
  end

  describe "DSL ↔ pg_constraint 双向一致" do
    test "正向：每个 FK relationship 的 on_delete 与 DB confdeltype 逐列相符" do
      db = db_fks()
      aligned = aligned_relationships()

      # 本测试的断言全在 for 内：集合为空会零断言通过（假绿），故先钉住非空。
      assert length(aligned) >= 60,
             "对齐主体只剩 #{length(aligned)} 列（<60）——DSL 读取异常或关系被批量删除"

      for %{table: table, column: column, on_delete: on_delete, relationship: relationship} <-
            aligned do
        expected = confdeltype(on_delete)
        actual = db[{table, column}]

        cond do
          actual == nil ->
            flunk(
              "#{table}.#{column}（belongs_to #{inspect(relationship)}）在 DB 无该 FK——" <>
                "migration 漏建或约束名/列名不符；确认无约束则登记 @no_db_fk_relationships"
            )

          actual != expected ->
            flunk(
              "#{table}.#{column} ON DELETE 漂移：resource 声明 #{inspect(on_delete)}" <>
                "（期望 confdeltype=#{expected}），DB 实际 #{actual}"
            )

          true ->
            :ok
        end
      end
    end

    test "反向：DB FK 集合 == 对齐主体 ∪ @db_only_fks（漏声明与登记过期都红）" do
      expected =
        MapSet.new(aligned_relationships(), fn %{table: t, column: c} -> {t, c} end)

      registered = MapSet.new(@db_only_fks, fn {table, column, _, _} -> {table, column} end)
      wanted = MapSet.union(expected, registered)
      actual = db_fks() |> Map.keys() |> MapSet.new()

      # 防空集合假绿：DSL 集合异常缩小（ash_domains 配置读错 / Info API 变更）时
      # 下面的等式断言会以"DB 多出几十列"的形式红，这里先给出可读的失败点。
      assert MapSet.size(expected) >= 60,
             "DSL 期望的 FK 集合只剩 #{MapSet.size(expected)} 列（<60）——守卫配置读取异常"

      assert MapSet.subset?(actual, wanted),
             "DB 有 FK 但 DSL 未声明、也未登记 @db_only_fks 的列（漏声明或残留约束）"

      assert MapSet.subset?(wanted, actual),
             "DSL 期望（或 @db_only_fks 登记）了 FK 但 DB 没有的列（migration 漏建/登记过期）"
    end

    test "ignore?: true 的 relationship 不得在 DB 留下 FK" do
      db = db_fks()

      ignored = Enum.filter(expected_fks(), & &1.ignore?)

      assert ignored != [], "预期至少有一个 ignore?: true 的 relationship（signal_logs.run_id）"

      for %{table: table, column: column, relationship: relationship} <- ignored do
        refute Map.has_key?(db, {table, column}),
               "#{table}.#{column}（belongs_to #{inspect(relationship)}）标了 ignore?: true，" <>
                 "DB 却有 FK——契约与实现不一致"
      end
    end

    test "@db_only_fks 自洽：真实存在、动作相符、与 DSL 不重叠、理由必填" do
      db = db_fks()
      universe = MapSet.new(expected_fks(), &{&1.table, &1.column})

      for {table, column, on_delete, reason} <- @db_only_fks do
        assert is_binary(reason) and String.trim(reason) != "",
               "#{table}.#{column} 登记为 DB-only FK 但未写明理由"

        refute MapSet.member?(universe, {table, column}),
               "#{table}.#{column} 已有 relationship（属对齐主体），@db_only_fks 登记已过期——" <>
                 "该声明 on_delete 并从本清单移除"

        assert db[{table, column}] == confdeltype(on_delete),
               "#{table}.#{column} 登记期望 confdeltype=#{confdeltype(on_delete)}，DB 实际 " <>
                 "#{inspect(db[{table, column}])}——约束缺失或动作已变，须重新对齐"
      end
    end

    test "@no_db_fk_relationships 自洽：relationship 真实存在、DB 确实无 FK、理由必填" do
      db = db_fks()
      universe = Map.new(expected_fks(), &{{&1.table, &1.column}, &1.relationship})

      for {table, column, relationship, reason} <- @no_db_fk_relationships do
        assert is_binary(reason) and String.trim(reason) != "",
               "#{table}.#{column} 登记为无 FK relationship 但未写明理由"

        assert Map.get(universe, {table, column}) == relationship,
               "#{table}.#{column} 登记的 relationship #{inspect(relationship)} 与 DSL 不符" <>
                 "（实际 #{inspect(Map.get(universe, {table, column}))}）——登记已过期"

        refute Map.has_key?(db, {table, column}),
               "#{table}.#{column} 登记为「无 FK」，DB 却有 FK——补了约束就该从清单移除并声明 on_delete"
      end
    end
  end

  # 对齐主体 = 未忽略、且不在 @no_db_fk_relationships 里的 relationship
  defp aligned_relationships do
    no_fk = MapSet.new(@no_db_fk_relationships, fn {t, c, _, _} -> {t, c} end)

    for %{ignore?: false} = fk <- expected_fks(),
        not MapSet.member?(no_fk, {fk.table, fk.column}) do
      fk
    end
  end

  # 生成器同源的期望集合（`migration_generator.ex:3930` 起）：
  # - 只取 belongs_to，且 source/destination 同 repo（`foreign_key?/1`，本仓全部 Cgc2046.Repo）
  # - 未声明 references 条目时 on_delete 为 nil（生成器 configured_reference 的兜底）
  defp expected_fks do
    :cgc_2046
    |> Application.get_env(:ash_domains, [])
    |> Enum.flat_map(&Ash.Domain.Info.resources/1)
    |> Enum.uniq()
    |> Enum.flat_map(fn resource ->
      case AshPostgres.DataLayer.Info.table(resource) do
        nil ->
          []

        table ->
          for relationship <- Ash.Resource.Info.relationships(resource),
              relationship.type == :belongs_to,
              same_repo_foreign_key?(relationship) do
            ref = AshPostgres.DataLayer.Info.reference(resource, relationship.name)

            %{
              table: to_string(table),
              column: to_string(relationship.source_attribute),
              on_delete: ref && ref.on_delete,
              ignore?: ref != nil and ref.ignore? == true,
              relationship: relationship.name
            }
          end
      end
    end)
  end

  defp same_repo_foreign_key?(relationship) do
    Ash.DataLayer.data_layer(relationship.source) == AshPostgres.DataLayer and
      AshPostgres.DataLayer.Info.repo(relationship.source, :mutate) ==
        AshPostgres.DataLayer.Info.repo(relationship.destination, :mutate)
  end

  # 单列 FK 的 {table, column} => confdeltype。
  # 复合 FK 与「同列多约束」无法用 {table, column} 表达，会逃逸四个桶，故用约束总数
  # 钉住这条假设：数量对不上即红（本仓当前 0 复合、0 同列多约束）。
  defp db_fks do
    %{rows: rows} =
      Cgc2046.Repo.query!("""
      SELECT c.relname, a.attname, con.confdeltype::text
      FROM pg_constraint con
      JOIN pg_class c ON c.oid = con.conrelid
      JOIN pg_namespace n ON n.oid = c.relnamespace AND n.nspname = 'public'
      JOIN LATERAL unnest(con.conkey) WITH ORDINALITY AS k(attnum, ord) ON true
      JOIN pg_attribute a ON a.attrelid = con.conrelid AND a.attnum = k.attnum
      WHERE con.contype = 'f' AND array_length(con.conkey, 1) = 1
      """)

    fks = Map.new(rows, fn [table, column, action] -> {{table, column}, action} end)

    %{rows: [[total]]} =
      Cgc2046.Repo.query!("""
      SELECT count(*)
      FROM pg_constraint con
      JOIN pg_class c ON c.oid = con.conrelid
      JOIN pg_namespace n ON n.oid = c.relnamespace AND n.nspname = 'public'
      WHERE con.contype = 'f'
      """)

    assert map_size(fks) == total,
           "public 有 #{total} 个 FK 约束，但单列展开只得 #{map_size(fks)} 条——存在复合 FK" <>
             "或同列多约束，会逃逸四桶断言（须扩展本守卫）"

    fks
  end
end
