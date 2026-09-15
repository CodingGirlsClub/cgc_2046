defmodule Cgc2046.Admission.BackfillCheckInCodesMigrationTest do
  use ExUnit.Case, async: false

  @moduledoc """
  #554 回归：核销码回填迁移（20260915120000）在真实一次性数据库上的行为证据。

  修复前缺陷：迁移跑在默认 DDL 事务内，撞码（同场同码撞唯一索引
  enrollments_unique_check_in_code_index）后 Postgres 中止事务，重试查询只得
  in_failed_sql_transaction → raise——一次撞码即迁移失败、部署卡死。

  修复后形状：@disable_ddl_transaction true（逐语句自动提交，撞码重试生效；
  失败重跑只选 NULL 码行，断点续跑幂等）+ 码生成与 app 层同单源
  （Cgc2046.RandomCode，crypto 无偏重采）。

  撞码注入不依赖生成器 stub（迁移在 Migrator Runner 进程执行，进程字典 stub
  不可达）：BEFORE UPDATE 触发器对前 N 次回填尝试 `RAISE unique_violation`，
  计数走 sequence（nextval 非事务性，语句回滚不吞计数）——与
  payment_workers_failclosed_guard_test 的触发器注入同纪律。

  探针基建同 WorkflowRunSubjectScopeMigrationTest：每 case 独立 CREATE DATABASE
  （不能用 cgc_2046_test 模板——模板已含目标版本），dynamic_repo 指向探针库，
  on_exit FORCE drop。
  """

  alias Ecto.Adapters.SQL
  alias Ecto.Adapters.SQL.Sandbox

  @moduletag timeout: 120_000

  @migrations_path Path.expand("../../../priv/repo/migrations", __DIR__)
  @before_version 20_260_914_114_239
  @target_version 20_260_915_120_000

  setup do
    unique = :erlang.unique_integer([:positive])
    db = "cgc2046_backfill_probe_#{unique}"

    admin_sql!(~s|DROP DATABASE IF EXISTS "#{db}" WITH (FORCE)|)
    admin_sql!(~s(CREATE DATABASE "#{db}"))

    {:ok, repo} = Cgc2046.Repo.start_link(database: db, pool_size: 2, name: nil)
    Sandbox.checkout(repo, sandbox: false)

    on_exit(fn ->
      admin_sql!(~s|DROP DATABASE IF EXISTS "#{db}" WITH (FORCE)|)
    end)

    migrate(repo, @before_version)

    {:ok, repo: repo}
  end

  test "撞码重试收敛：前 5 次回填尝试注入唯一冲突，迁移仍完成且同场唯一（#554 核心回归）",
       %{repo: repo} do
    workspace_id = seed_workspace!(repo)
    event_id = seed_event!(repo, workspace_id)

    for _ <- 1..3 do
      seed_enrollment!(repo, workspace_id, seed_user!(repo), event_id, "confirmed")
    end

    inject_collision_trigger!(repo, 5)

    # 修复前：首次注入冲突即中止 DDL 事务，迁移 raise（in_failed_sql_transaction）；
    # 修复后：逐语句自动提交，unique_violation → :cont 重试链真实走通
    assert [@target_version] = migrate(repo, @target_version)

    codes = codes_of(repo, event_id)
    assert length(codes) == 3
    assert Enum.all?(codes, &(&1 =~ ~r/^\d{6}$/))
    assert length(Enum.uniq(codes)) == 3

    # 注入确实咬过（sequence 计数 > 行数 = 有重试发生），而非侥幸无碰撞通过
    assert attempt_count(repo) > 3
  end

  test "断点续跑幂等：已有码行不动，NULL 行补齐，抹版本行后重放安全", %{repo: repo} do
    workspace_id = seed_workspace!(repo)
    event_id = seed_event!(repo, workspace_id)

    pre_coded =
      seed_enrollment!(repo, workspace_id, seed_user!(repo), event_id, "confirmed", "111111")

    seed_enrollment!(repo, workspace_id, seed_user!(repo), event_id, "confirmed")
    seed_enrollment!(repo, workspace_id, seed_user!(repo), event_id, "confirmed")

    assert [@target_version] = migrate(repo, @target_version)

    codes = codes_of(repo, event_id)
    assert length(codes) == 3
    assert "111111" in codes
    assert length(Enum.uniq(codes)) == 3

    # 幂等重放：抹掉版本记录再跑——无 NULL 行可选，零改动零报错
    SQL.query!(repo, "DELETE FROM schema_migrations WHERE version = #{@target_version}", [])
    assert [@target_version] = migrate(repo, @target_version)
    assert codes_of(repo, event_id) == codes
    assert code_of(repo, pre_coded) == "111111"
  end

  test "不回填集合：cancelled/expired/rejected 与 course 报名保持 NULL", %{repo: repo} do
    workspace_id = seed_workspace!(repo)
    event_id = seed_event!(repo, workspace_id)
    course_id = seed_course!(repo, workspace_id)

    # 应回填：confirmed / pending / payment_pending（event）
    for status <- ["confirmed", "pending", "payment_pending"] do
      seed_enrollment!(repo, workspace_id, seed_user!(repo), event_id, status)
    end

    # 不回填：终态 event 报名 + course 报名（即便 confirmed）
    for status <- ["cancelled", "expired", "rejected"] do
      seed_enrollment!(repo, workspace_id, seed_user!(repo), event_id, status)
    end

    course_enrollment =
      seed_course_enrollment!(repo, workspace_id, seed_user!(repo), course_id, "confirmed")

    assert [@target_version] = migrate(repo, @target_version)

    codes = codes_of(repo, event_id)
    assert length(codes) == 3
    assert length(Enum.uniq(codes)) == 3

    assert null_code_count(repo, event_id) == 3
    assert is_nil(code_of(repo, course_enrollment))
  end

  # --- 撞码注入 ----------------------------------------------------------------

  # BEFORE UPDATE 触发器：前 fail_count 次「NULL → 非 NULL」回填尝试抛
  # unique_violation（与撞码同 SQLSTATE，迁移的重试分支按 code 匹配）。
  # 计数用 sequence：nextval 非事务性，语句回滚不吞计数——这是跨「逐语句
  # 自动提交」边界保持注入状态的唯一可靠手段（表行会随语句回滚被吞）。
  defp inject_collision_trigger!(repo, fail_count) do
    SQL.query!(repo, "CREATE SEQUENCE probe_collision_seq", [])

    SQL.query!(repo, """
    CREATE OR REPLACE FUNCTION cgc_probe_collision() RETURNS trigger AS $$
    BEGIN
      IF nextval('probe_collision_seq') <= #{fail_count} THEN
        RAISE unique_violation USING MESSAGE = 'probe injected collision';
      END IF;
      RETURN NEW;
    END;
    $$ LANGUAGE plpgsql;
    """)

    SQL.query!(repo, """
    CREATE TRIGGER probe_collision BEFORE UPDATE ON enrollments FOR EACH ROW
    WHEN (OLD.check_in_code IS NULL AND NEW.check_in_code IS NOT NULL)
    EXECUTE FUNCTION cgc_probe_collision();
    """)
  end

  defp attempt_count(repo) do
    repo
    |> SQL.query!("SELECT last_value FROM probe_collision_seq", [])
    |> Map.fetch!(:rows)
    |> hd()
    |> hd()
  end

  # --- 探针基建 ----------------------------------------------------------------

  defp admin_sql!(statement) do
    Sandbox.unboxed_run(Cgc2046.Repo, fn -> SQL.query!(Cgc2046.Repo, statement) end)
  end

  defp migrate(repo, version) do
    Ecto.Migrator.run(Cgc2046.Repo, @migrations_path, :up, to: version, dynamic_repo: repo)
  end

  # --- 最小合法 fixture（按目标版本 NOT NULL / FK / 唯一索引约束补齐） ------------

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

  defp seed_event!(repo, workspace_id) do
    insert_one!(
      repo,
      "INSERT INTO events (workspace_id, title, slug, status) VALUES ($1, 'probe event', $2, 'open') RETURNING id::text",
      [
        Cgc2046.Repo.uuid!(workspace_id),
        "probe-event-#{:erlang.unique_integer([:positive])}"
      ]
    )
  end

  defp seed_course!(repo, workspace_id) do
    insert_one!(
      repo,
      "INSERT INTO courses (workspace_id, title, slug) VALUES ($1, 'probe course', $2) RETURNING id::text",
      [Cgc2046.Repo.uuid!(workspace_id), "probe-course-#{:erlang.unique_integer([:positive])}"]
    )
  end

  # unique_event_user 部分唯一索引：同场同人至多一条活跃报名——每报名独立 user
  defp seed_enrollment!(repo, workspace_id, user_id, event_id, status, code \\ nil) do
    insert_one!(
      repo,
      """
      INSERT INTO enrollments
        (workspace_id, user_id, event_id, status, check_in_code, inserted_at, updated_at)
      VALUES ($1, $2, $3, $4, $5, NOW(), NOW())
      RETURNING id::text
      """,
      [
        Cgc2046.Repo.uuid!(workspace_id),
        Cgc2046.Repo.uuid!(user_id),
        Cgc2046.Repo.uuid!(event_id),
        status,
        code
      ]
    )
  end

  defp seed_course_enrollment!(repo, workspace_id, user_id, course_id, status) do
    insert_one!(
      repo,
      """
      INSERT INTO enrollments
        (workspace_id, user_id, course_id, status, inserted_at, updated_at)
      VALUES ($1, $2, $3, $4, NOW(), NOW())
      RETURNING id::text
      """,
      [
        Cgc2046.Repo.uuid!(workspace_id),
        Cgc2046.Repo.uuid!(user_id),
        Cgc2046.Repo.uuid!(course_id),
        status
      ]
    )
  end

  # --- 断言读取 ------------------------------------------------------------------

  defp codes_of(repo, event_id) do
    repo
    |> SQL.query!(
      "SELECT check_in_code FROM enrollments WHERE event_id = $1 AND check_in_code IS NOT NULL ORDER BY check_in_code",
      [Cgc2046.Repo.uuid!(event_id)]
    )
    |> Map.fetch!(:rows)
    |> Enum.map(&hd/1)
  end

  defp null_code_count(repo, event_id) do
    repo
    |> SQL.query!(
      "SELECT count(*) FROM enrollments WHERE event_id = $1 AND check_in_code IS NULL",
      [Cgc2046.Repo.uuid!(event_id)]
    )
    |> Map.fetch!(:rows)
    |> hd()
    |> hd()
  end

  defp code_of(repo, enrollment_id) do
    repo
    |> SQL.query!(
      "SELECT check_in_code FROM enrollments WHERE id = $1",
      [Cgc2046.Repo.uuid!(enrollment_id)]
    )
    |> Map.fetch!(:rows)
    |> hd()
    |> hd()
  end
end
