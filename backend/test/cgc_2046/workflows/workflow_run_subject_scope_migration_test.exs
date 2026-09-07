defmodule Cgc2046.Workflows.WorkflowRunSubjectScopeMigrationTest do
  use ExUnit.Case, async: false

  @moduledoc """
  发布前 review（H9）要求的失败原子性证据：`20260906000003_add_workflow_run_subject_scope.exs`
  不再做静态文本断言，而是在真实一次性数据库上执行迁移并观察 abort 行为——
  这是 U6 验收（迁移 preflight 先于 raw-run policy 切换、unresolved 行阻塞发布）
  的可执行裁决记录。

  探针覆盖（隐私计划「unresolved rows 人工 reconcile」条款，abort-only 语义）：

  1. **cast 失败**：`input_snapshot.user_id` 为 36 位无连字符 hex——通过 preflight
     正则 `^[0-9a-f-]{36}$` 但 `::uuid` cast 必炸。此时 ALTER/索引已在同事务内
     执行，整体回滚后必须零半残留（4 列 / 3 索引 / schema_migrations 行均不存在）。
  2. **缺 user_id 键**：即便 enrollment 锚点存在、理论上可经 `enrollment.user_id`
     派生学员，迁移也拒绝隐式派生——阻塞发布，人工 reconcile 是唯一路径。
  3. **悬空 enrollment_id**：enrollments 无此行且快照无其它可解析锚点 →
     backfill 守卫抛错。
  4. **happy path**：合法 learning run 回填（course 经 enrollment join 派生）、
     非 learning 脏行不受守卫约束（既有边界）、守卫边界记录（合法 user_id +
     悬空 enrollment_id 放行——`subject_enrollment_id` 无 FK，原样落列）、
     抹掉版本行后完整重放幂等。

  实现：每个 case `CREATE DATABASE` 独立建库（不能用 cgc_2046_test 模板——
  模板已含目标版本，无从探针回滚），主 Repo 经 `sandbox: false` checkout
  执行 DDL（CREATE/DROP DATABASE 不能在 sandbox 包装事务内）；探针 Repo 为
  独立命名进程（pool_size 2），on_exit `WITH (FORCE)` drop。
  """

  alias Ecto.Adapters.SQL
  alias Ecto.Adapters.SQL.Sandbox

  @moduletag timeout: 120_000

  @migrations_path Path.expand("../../../priv/repo/migrations", __DIR__)
  @before_version 20_260_906_000_002
  @target_version 20_260_906_000_003

  @subject_columns ~w(
    subject_user_id subject_course_id subject_enrollment_id subject_course_revision_id
  )
  @subject_indexes ~w(
    workflow_runs_subject_user_id_index
    workflow_runs_subject_course_id_index
    workflow_runs_subject_enrollment_id_index
  )

  setup do
    unique = :erlang.unique_integer([:positive])
    db = "cgc2046_migration_probe_#{unique}"

    # 防御同名残留（上次运行崩溃留下的孤儿库）；PG 无 CREATE DATABASE IF NOT EXISTS
    admin_sql!(~s|DROP DATABASE IF EXISTS "#{db}" WITH (FORCE)|)
    admin_sql!(~s(CREATE DATABASE "#{db}"))

    # 独立一次性探针 Repo：name: nil 不注册（默认会注册为 Cgc2046.Repo 撞主进程）。
    # Ecto.Migrator 只认真实 Repo 模块——迁移经 dynamic_repo: pid 指到本进程。
    {:ok, repo} = Cgc2046.Repo.start_link(database: db, pool_size: 2, name: nil)

    # 探针连接须在 sandbox 包装事务外：迁移失败回滚/残留断言都要求真实提交语义
    Sandbox.checkout(repo, sandbox: false)

    on_exit(fn ->
      # 探针 repo 由测试进程 start_link 拉起，随测试进程退出（父退出传播）；
      # 不手动 Supervisor.stop——on_exit 时它多半正在 shutdown，stop 会 race 崩溃。
      # FORCE drop 兜底终止任何残留连接。
      admin_sql!(~s|DROP DATABASE IF EXISTS "#{db}" WITH (FORCE)|)
    end)

    migrate(repo, @before_version)

    {:ok, repo: repo}
  end

  test "preflight 通过但 uuid cast 失败的 user_id：abort 且零半残留", %{repo: repo} do
    workspace_id = seed_workspace!(repo)
    definition_id = seed_definition!(repo, workspace_id, "learning")

    # 36 位无连字符 hex：匹配 preflight 正则 ^[0-9a-f-]{36}$，::uuid cast 必炸
    insert_run!(repo, workspace_id, definition_id, %{"user_id" => String.duplicate("ab", 18)})

    error = assert_raise Postgrex.Error, fn -> migrate(repo, @target_version) end
    assert Exception.message(error) =~ "invalid input syntax for type uuid"

    assert_zero_residue(repo)
  end

  test "缺 user_id 键（enrollment 锚点存在也不隐式派生）：abort 且零半残留", %{repo: repo} do
    workspace_id = seed_workspace!(repo)
    user_id = seed_user!(repo)
    course_id = seed_course!(repo, workspace_id)
    enrollment_id = seed_enrollment!(repo, workspace_id, user_id, course_id)
    definition_id = seed_definition!(repo, workspace_id, "learning")

    insert_run!(repo, workspace_id, definition_id, %{
      "enrollment_id" => enrollment_id,
      "course_id" => course_id
    })

    error = assert_raise Postgrex.Error, fn -> migrate(repo, @target_version) end
    assert Exception.message(error) =~ "learning workflow run subject backfill incomplete"

    assert_zero_residue(repo)
  end

  test "悬空 enrollment_id 且无其它可解析锚点：abort 且零半残留", %{repo: repo} do
    workspace_id = seed_workspace!(repo)
    definition_id = seed_definition!(repo, workspace_id, "learning")

    # enrollments 无此行；快照里也没有 user_id/course_id 可救
    insert_run!(repo, workspace_id, definition_id, %{"enrollment_id" => Ecto.UUID.generate()})

    error = assert_raise Postgrex.Error, fn -> migrate(repo, @target_version) end
    assert Exception.message(error) =~ "learning workflow run subject backfill incomplete"

    assert_zero_residue(repo)
  end

  test "合法 learning run 回填成功（course 经 enrollment join），非 learning 脏行不动，幂等重放",
       %{repo: repo} do
    workspace_id = seed_workspace!(repo)
    user_id = seed_user!(repo)
    course_id = seed_course!(repo, workspace_id)
    enrollment_id = seed_enrollment!(repo, workspace_id, user_id, course_id)
    revision_id = Ecto.UUID.generate()
    learning_definition = seed_definition!(repo, workspace_id, "learning")
    other_definition = seed_definition!(repo, workspace_id, "curriculum")

    learning_run_id =
      insert_run!(repo, workspace_id, learning_definition, %{
        "user_id" => user_id,
        "enrollment_id" => enrollment_id,
        "course_revision_id" => revision_id
      })

    # 守卫边界记录：合法 user_id + 悬空 enrollment_id → 守卫只查非空
    # （subject_enrollment_id 无 FK），悬空 id 原样落列、迁移放行。
    # cutover runbook 据此提供迁移后悬空扫描 SQL（登记，不阻塞）。
    dangling = Ecto.UUID.generate()

    boundary_run_id =
      insert_run!(repo, workspace_id, learning_definition, %{
        "user_id" => user_id,
        "enrollment_id" => dangling
      })

    # 非 learning 行的脏 input_snapshot 不在守卫范围（preflight/backfill 均限定 d.type = 'learning'）
    other_run_id =
      insert_run!(repo, workspace_id, other_definition, %{"user_id" => "not-a-uuid"})

    assert [@target_version] = migrate(repo, @target_version)
    assert_subject_shape(repo)

    assert subject_row(repo, learning_run_id) == {user_id, course_id, enrollment_id, revision_id}
    assert subject_row(repo, boundary_run_id) == {user_id, nil, dangling, nil}
    assert subject_row(repo, other_run_id) == {nil, nil, nil, nil}

    # 幂等：抹掉版本记录后完整重放迁移——add/create_if_not_exists 与守卫全部安全重跑
    SQL.query!(repo, "DELETE FROM schema_migrations WHERE version = #{@target_version}", [])
    assert [@target_version] = migrate(repo, @target_version)

    assert subject_row(repo, learning_run_id) == {user_id, course_id, enrollment_id, revision_id}
    assert subject_row(repo, boundary_run_id) == {user_id, nil, dangling, nil}
    assert subject_row(repo, other_run_id) == {nil, nil, nil, nil}
  end

  # --- 探针基建 ----------------------------------------------------------------

  # 主 Repo 的管理面 DDL（CREATE/DROP DATABASE）须在 sandbox 包装事务外执行
  defp admin_sql!(statement) do
    Sandbox.unboxed_run(Cgc2046.Repo, fn -> SQL.query!(Cgc2046.Repo, statement) end)
  end

  # Ecto.Migrator 需要真实 Repo 模块（get_dynamic_repo/config），
  # dynamic_repo 选项把全部迁移查询指到探针库进程
  defp migrate(repo, version) do
    Ecto.Migrator.run(Cgc2046.Repo, @migrations_path, :up, to: version, dynamic_repo: repo)
  end

  # 4 列 / 3 索引 / schema_migrations 版本行的存在性计数
  defp subject_shape_counts(repo) do
    [[columns]] =
      SQL.query!(
        repo,
        """
        SELECT count(*) FROM information_schema.columns
        WHERE table_schema = 'public' AND table_name = 'workflow_runs'
          AND column_name = ANY($1::text[])
        """,
        [@subject_columns]
      ).rows

    [[indexes]] =
      SQL.query!(
        repo,
        """
        SELECT count(*) FROM pg_indexes
        WHERE schemaname = 'public' AND tablename = 'workflow_runs'
          AND indexname = ANY($1::text[])
        """,
        [@subject_indexes]
      ).rows

    [[migrated]] =
      SQL.query!(
        repo,
        "SELECT count(*) FROM schema_migrations WHERE version = #{@target_version}",
        []
      ).rows

    {columns, indexes, migrated}
  end

  defp assert_zero_residue(repo), do: assert(subject_shape_counts(repo) == {0, 0, 0})
  defp assert_subject_shape(repo), do: assert(subject_shape_counts(repo) == {4, 3, 1})

  defp subject_row(repo, run_id) do
    [row] =
      SQL.query!(
        repo,
        """
        SELECT subject_user_id::text, subject_course_id::text,
               subject_enrollment_id::text, subject_course_revision_id::text
        FROM workflow_runs WHERE id = $1
        """,
        [Cgc2046.Repo.uuid!(run_id)]
      ).rows

    List.to_tuple(row)
  end

  # --- 最小合法 fixture（按 baseline NOT NULL / FK 约束补齐，再污染） ---------------

  defp insert_one!(repo, sql, params) do
    repo |> SQL.query!(sql, params) |> Map.fetch!(:rows) |> hd() |> hd()
  end

  defp seed_workspace!(repo) do
    insert_one!(
      repo,
      "INSERT INTO workspaces (slug, name) VALUES ($1, 'probe workspace') RETURNING id::text",
      ["probe-ws-#{:erlang.unique_integer([:positive])}"]
    )
  end

  defp seed_user!(repo) do
    insert_one!(repo, "INSERT INTO users DEFAULT VALUES RETURNING id::text", [])
  end

  defp seed_course!(repo, workspace_id) do
    insert_one!(
      repo,
      """
      INSERT INTO courses (workspace_id, title, slug) VALUES ($1, 'probe course', $2)
      RETURNING id::text
      """,
      [Cgc2046.Repo.uuid!(workspace_id), "probe-course-#{:erlang.unique_integer([:positive])}"]
    )
  end

  defp seed_definition!(repo, workspace_id, type) do
    insert_one!(
      repo,
      """
      INSERT INTO workflow_definitions (workspace_id, name, type) VALUES ($1, $2, $3)
      RETURNING id::text
      """,
      [
        Cgc2046.Repo.uuid!(workspace_id),
        "probe-def-#{:erlang.unique_integer([:positive])}",
        type
      ]
    )
  end

  defp seed_enrollment!(repo, workspace_id, user_id, course_id) do
    insert_one!(
      repo,
      """
      INSERT INTO enrollments (workspace_id, user_id, course_id, inserted_at, updated_at)
      VALUES ($1, $2, $3, now() AT TIME ZONE 'utc', now() AT TIME ZONE 'utc')
      RETURNING id::text
      """,
      [
        Cgc2046.Repo.uuid!(workspace_id),
        Cgc2046.Repo.uuid!(user_id),
        Cgc2046.Repo.uuid!(course_id)
      ]
    )
  end

  defp insert_run!(repo, workspace_id, definition_id, input_snapshot) do
    insert_one!(
      repo,
      """
      INSERT INTO workflow_runs (workspace_id, definition_id, definition_version, input_snapshot)
      VALUES ($1, $2, 1, $3::jsonb)
      RETURNING id::text
      """,
      [
        Cgc2046.Repo.uuid!(workspace_id),
        Cgc2046.Repo.uuid!(definition_id),
        # Ecto 类型模块对 jsonb 参数走 Jason 编码——直接传 map（传 JSON 字符串会双重编码成标量）
        input_snapshot
      ]
    )
  end
end
