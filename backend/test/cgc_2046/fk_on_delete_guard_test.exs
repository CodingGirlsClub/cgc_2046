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
  # #745 已清空：原 9 列（curriculum_outputs.workflow_run_id / invitations.inviter_id /
  # invitations.accepted_by / portfolio_items.workspace_id / workspace_profiles.
  # workspace_id / workspace_profiles.user_id / mcp_pending_operations.user_id /
  # mcp_tokens.user_id / mcp_tool_call_logs.user_id）已由 20260918131057 补上
  # FK（孤儿防御清理 + 4 索引 + 9 约束；mcp_tool_call_logs 走 NOT VALID +
  # VALIDATE 两段式），并逐列声明 on_delete 移入对齐主体。
  # 后续新缺口按原格式登记于此。
  @no_db_fk_relationships []

  # #717：events/courses 直接引用列的单一登记清单。全集由 DB catalog 的实际 FK
  # 与命名候选列并集得到；新增 FK 或裸 uuid/uuid[] 引用而未登记时必须变红。
  # 历史根因证据：flashback_action_cards.event_id 曾是未登记裸 uuid，随后由
  # 20260919004500_drop_flashback_action_cards.exs 删除整表；它只保留在本注释中，
  # 不作为当前 manifest 条目，避免把已不存在的历史列误当活约束。
  @offering_cascade_manifest [
    %{
      table: "attendances",
      column: "event_id",
      handling: :structurally_impossible,
      expected_confdeltype: "a",
      reason:
        "Event :delete 仅允许 draft（events/event.ex:791-794）；签到发生在可报名活动，" <>
          "删除路径没有 attendance 显式收口，NO ACTION 由 draft-only 不变量挡住"
    },
    %{
      table: "curriculum_course_revisions",
      column: "course_id",
      handling: :structurally_impossible,
      expected_confdeltype: "a",
      reason:
        "Course :delete 仅允许 draft，course.ex:628-635 明确 revision 对 draft 结构性不存在；" <>
          "migration 未声明 on_delete，NO ACTION 保留为异常防线"
    },
    %{
      table: "enrollments",
      column: "event_id",
      handling: :fk_cascade,
      expected_confdeltype: "c",
      reason: "enrollment 行由 events FK ON DELETE CASCADE 承接"
    },
    %{
      table: "enrollments",
      column: "course_id",
      handling: :fk_cascade,
      expected_confdeltype: "c",
      reason: "enrollment 行由 courses FK ON DELETE CASCADE 承接"
    },
    %{
      table: "event_moderators",
      column: "event_id",
      handling: :fk_cascade,
      expected_confdeltype: "c",
      reason: "event moderator 行由 events FK ON DELETE CASCADE 承接"
    },
    %{
      table: "flashback_people",
      column: "archive_event_id",
      handling: :structurally_impossible,
      expected_confdeltype: nil,
      reason: "指向 Flashback event archive，不是当前 events.id"
    },
    %{
      table: "invitations",
      column: "prep_course_ids",
      handling: :explicit_collect,
      expected_confdeltype: nil,
      reason:
        "Course :delete 没有自动回写 invitation；Invitation.assign_prep_courses/2（accounts/invitation.ex:630-652）" <>
          "对已删除或已终结课程跳过并记录日志，属于规则兜底而非 FK 收口"
    },
    %{
      table: "invite_batches",
      column: "event_id",
      handling: :fk_cascade,
      expected_confdeltype: "c",
      reason: "invite batch 行由 events FK ON DELETE CASCADE 承接"
    },
    %{
      table: "invite_batches",
      column: "course_id",
      handling: :fk_cascade,
      expected_confdeltype: "c",
      reason: "invite batch 行由 courses FK ON DELETE CASCADE 承接"
    },
    %{
      table: "payments_webhook_events",
      column: "event_id",
      handling: :structurally_impossible,
      expected_confdeltype: nil,
      reason: "text 类型的支付渠道 event_id，不是当前 events.id"
    },
    %{
      table: "sponsorships",
      column: "event_id",
      handling: :fk_cascade,
      expected_confdeltype: "c",
      reason: "sponsorship 行由 events FK ON DELETE CASCADE 承接；deliveries 仅经 sponsorship_id 间接承接"
    },
    %{
      table: "speaker_invitations",
      column: "event_id",
      handling: :fk_cascade,
      expected_confdeltype: "c",
      reason: "speaker invitation 行由 events FK ON DELETE CASCADE 承接"
    },
    %{
      table: "volunteer_applications",
      column: "assigned_event_id",
      handling: :fk_cascade,
      expected_confdeltype: "n",
      reason: "志愿者可指派到 draft event；events 删除通过 SET NULL 保留申请"
    },
    %{
      table: "workflow_runs",
      column: "subject_course_id",
      handling: :structurally_impossible,
      expected_confdeltype: nil,
      reason:
        "WorkflowRun.subject_course_id 没有独立 FK 或删除收口；learning run 只在可学习的非 draft 课程存在，" <>
          "而 Course :delete 仅允许 draft，因此当前没有可达的课程删除并存场景"
    }
  ]

  @workflow_cascade_manifest [
    %{
      type: :learning,
      handling: :structurally_impossible,
      reason: "learning run 依赖已发布/可学习课程，draft-only Course :delete 不会触达该 run"
    },
    %{
      type: :enrollment,
      handling: :structurally_impossible,
      reason: "WorkflowDefinition.type 的 :enrollment 是预留枚举；当前代码没有该类型的 event/course 实例化或删除收口路径"
    },
    %{
      type: :sponsorship,
      handling: :structurally_impossible,
      reason: "WorkflowDefinition.type 的 :sponsorship 是预留枚举；当前代码没有该类型的 event/course 实例化或删除收口路径"
    },
    %{
      type: :speaker_invitation,
      handling: :explicit_collect,
      reason:
        "Event :delete 通过 SpeakerInvitation.stop_event_runs/1 收口非终态 run（events/event.ex:818-824）"
    },
    %{
      type: :curriculum,
      handling: :structurally_impossible,
      reason:
        "curriculum run 由 Event launch 后实例化；Event :delete 仅允许 draft（events/event.ex:791-794），" <>
          "因此没有可达的 event 删除并存场景"
    },
    %{
      type: :course_preparation,
      handling: :explicit_collect,
      reason:
        "Course :delete 通过 Curriculum.Prep.stop_active_runs/1 收口非终态 prep run（courses/course.ex:670-675）"
    },
    %{
      type: :recruitment_application,
      handling: :structurally_impossible,
      reason:
        "recruitment_application run 的业务锚点是 volunteer_application/cohort；它没有 event_id/course_id 列，也没有 event/course 删除收口路径"
    }
  ]

  @cascade_handlings [:fk_cascade, :explicit_collect, :structurally_impossible]

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

  describe "#717 级联清单单一所有者" do
    test "所有 event/course 引用候选列都已登记" do
      actual = MapSet.new(offering_reference_columns())
      registered = MapSet.new(@offering_cascade_manifest, &{&1.table, &1.column})

      assert actual == registered,
             "event/course 引用列登记不完整；缺少 #{inspect(MapSet.difference(actual, registered) |> MapSet.to_list())}；" <>
               "多余 #{inspect(MapSet.difference(registered, actual) |> MapSet.to_list())}"
    end

    test "列 manifest 的 handling、理由与 FK 动作一致" do
      offering_fks = offering_fks()

      for entry <- @offering_cascade_manifest do
        assert entry.handling in @cascade_handlings,
               "#{entry.table}.#{entry.column} 使用了未知处理类别 #{inspect(entry.handling)}"

        assert is_binary(entry.reason) and String.trim(entry.reason) != "",
               "#{entry.table}.#{entry.column} 必须写明处理理由"

        actual = Map.get(offering_fks, {entry.table, entry.column})

        case entry.handling do
          :fk_cascade ->
            assert actual == entry.expected_confdeltype,
                   "#{entry.table}.#{entry.column} 声明 FK 承接，期望 confdeltype=" <>
                     "#{entry.expected_confdeltype}，实际 #{inspect(actual)}"

          :structurally_impossible ->
            assert actual == entry.expected_confdeltype,
                   "#{entry.table}.#{entry.column} 声明结构性不存在，期望 confdeltype=" <>
                     "#{inspect(entry.expected_confdeltype)}，实际 #{inspect(actual)}"

          :explicit_collect ->
            assert is_nil(actual),
                   "#{entry.table}.#{entry.column} 声明显式收口但仍有指向 events/courses 的 FK " <>
                     "（实际 #{inspect(actual)}）"
        end
      end
    end

    test "代码声明的每种 workflow type 都有处理登记" do
      actual = MapSet.new(workflow_types())
      registered = MapSet.new(@workflow_cascade_manifest, & &1.type)

      assert actual == registered,
             "workflow type 登记不完整；缺少 #{inspect(MapSet.difference(actual, registered) |> MapSet.to_list())}；" <>
               "多余 #{inspect(MapSet.difference(registered, actual) |> MapSet.to_list())}"

      for entry <- @workflow_cascade_manifest do
        assert entry.handling in @cascade_handlings,
               "workflow #{entry.type} 使用了未知处理类别 #{inspect(entry.handling)}"

        assert is_binary(entry.reason) and String.trim(entry.reason) != "",
               "workflow #{entry.type} 必须写明处理理由"
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

  defp offering_reference_columns do
    offering_fk_columns()
    |> MapSet.new()
    |> MapSet.union(MapSet.new(named_offering_columns()))
    |> MapSet.to_list()
  end

  defp offering_fk_columns do
    %{rows: rows} =
      Cgc2046.Repo.query!("""
      SELECT child.relname, child_attr.attname
      FROM pg_constraint con
      JOIN pg_class child ON child.oid = con.conrelid
      JOIN pg_namespace child_ns ON child_ns.oid = child.relnamespace AND child_ns.nspname = 'public'
      JOIN LATERAL unnest(con.conkey) WITH ORDINALITY AS key(attnum, ord) ON true
      JOIN pg_attribute child_attr ON child_attr.attrelid = con.conrelid AND child_attr.attnum = key.attnum
      JOIN pg_class parent ON parent.oid = con.confrelid
      JOIN pg_namespace parent_ns ON parent_ns.oid = parent.relnamespace AND parent_ns.nspname = 'public'
      WHERE con.contype = 'f'
        AND array_length(con.conkey, 1) = 1
        AND parent.relname IN ('events', 'courses')
      ORDER BY child.relname, child_attr.attname
      """)

    Enum.map(rows, fn [table, column] -> {table, column} end)
  end

  defp named_offering_columns do
    %{rows: rows} =
      Cgc2046.Repo.query!("""
      SELECT table_name, column_name
      FROM information_schema.columns
      WHERE table_schema = 'public'
        AND (
          column_name IN ('event_id', 'course_id')
          OR right(column_name, 9) = '_event_id'
          OR right(column_name, 10) = '_course_id'
          OR right(column_name, 10) = '_event_ids'
          OR right(column_name, 11) = '_course_ids'
        )
      ORDER BY table_name, column_name
      """)

    Enum.map(rows, fn [table, column] -> {table, column} end)
  end

  defp offering_fks do
    %{rows: rows} =
      Cgc2046.Repo.query!("""
      SELECT child.relname, child_attr.attname, con.confdeltype::text
      FROM pg_constraint con
      JOIN pg_class child ON child.oid = con.conrelid
      JOIN pg_namespace child_ns ON child_ns.oid = child.relnamespace AND child_ns.nspname = 'public'
      JOIN LATERAL unnest(con.conkey) WITH ORDINALITY AS key(attnum, ord) ON true
      JOIN pg_attribute child_attr ON child_attr.attrelid = con.conrelid AND child_attr.attnum = key.attnum
      JOIN pg_class parent ON parent.oid = con.confrelid
      JOIN pg_namespace parent_ns ON parent_ns.oid = parent.relnamespace AND parent_ns.nspname = 'public'
      WHERE con.contype = 'f'
        AND array_length(con.conkey, 1) = 1
        AND parent.relname IN ('events', 'courses')
      """)

    Map.new(rows, fn [table, column, action] -> {{table, column}, action} end)
  end

  defp workflow_types do
    attr = Ash.Resource.Info.attribute(Cgc2046.Workflows.WorkflowDefinition, :type)
    attr.constraints[:one_of]
  end
end
