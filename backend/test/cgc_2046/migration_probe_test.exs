defmodule Cgc2046.MigrationProbeTest do
  use ExUnit.Case, async: false

  @moduledoc """
  迁移探针（#611）：改名类迁移的**前置检查**与**幂等重放**在真实一次性库上可执行裁决。

  背景：`ALTER INDEX ... RENAME TO` 在对象不存在时直接失败（42P01），而
  「存量库 / 新建库 / 恢复演练」三条路径的 catalog 状态不保证一致，此前无测试覆盖。
  探针在一次性库上**全量迁移到 head**（顺带覆盖"新建库"路径），再对该库做两件事：

  1. **T1 幂等 + 存量路径**：抹掉版本行后重放 `up` ⇒ 命中 `:already_renamed` 分支、
     不抛异常、索引仍在；再把索引改回旧名（模拟 #611 之前的存量库）⇒ 重放 `up`
     真把旧名改成目标名。
  2. **T2 前置检查诊断 + 原子性**：删掉**最后一条**改名对的目标索引（两名皆缺）⇒
     `up` 抛错且消息含 `expected` / `actual` 两段；同迁移先成功的前几条改名必须整体
     回滚（5 条同事务，不留半改名中间态）。

  ## 覆盖范围与 opt-in

  改名类迁移以 `@renames` 为 **opt-in**：声明 `@renames` 并导出 `renames/0` 的迁移才会
  被本探针发现（直接从 `priv/repo/migrations/*.exs` 编译出的模块里筛），故清单不可能与
  真实 DDL 漂移。`20260916130000_align_initiative_slug_index_name.exs` 未声明 ⇒ 不覆盖：
  它"索引已改名 + 版本行缺失"的组合在任何真实路径都不可达（改名与版本行同事务写入），
  retrofit 它买到的是零保护；新改名迁移一律走 `@renames`。

  实现照 `workflow_run_subject_scope_migration_test.exs` 的先例：每个用例独立
  `CREATE DATABASE`（模板库已含目标版本，无从探针重放）+ 独立命名进程 Repo
  （`name: nil`）+ `sandbox: false`（迁移要求真实提交语义），`on_exit` 用
  `WITH (FORCE)` drop（历史孤儿库 `cgc2046_migration_probe_*` 说明必须防御）。

  迁移只编译一次（`setup_all`）：以目录形式反复 `Ecto.Migrator.run` 会重复
  `Code.compile_file` 并刷 "redefining module" 警告，故之后一律传 `{version, module}`。
  """

  alias Cgc2046.Repo.IndexCatalog
  alias Ecto.Adapters.SQL
  alias Ecto.Adapters.SQL.Sandbox

  @moduletag :migration_probe
  @moduletag timeout: 180_000

  @migrations_path Path.expand("../../priv/repo/migrations", __DIR__)

  setup_all do
    {:ok, migrations: migration_pairs!()}
  end

  setup %{migrations: migrations} do
    unique = :erlang.unique_integer([:positive])
    db = "cgc2046_identity_probe_#{unique}"

    # 防御同名残留（上次运行崩溃留下的孤儿库）；PG 无 CREATE DATABASE IF NOT EXISTS
    admin_sql!(~s|DROP DATABASE IF EXISTS "#{db}" WITH (FORCE)|)
    admin_sql!(~s(CREATE DATABASE "#{db}"))

    # on_exit 先于一切可能失败的步骤注册：否则 checkout/迁移失败时本库成孤儿
    # （本机 PG 连接打满时 Sandbox.checkout 会 raise，历史上留下一批孤儿探针库）。
    on_exit(fn ->
      # 探针 repo 由测试进程 start_link 拉起，随测试进程退出（父退出传播）；
      # 不手动 Supervisor.stop——on_exit 时它多半正在 shutdown，stop 会 race 崩溃。
      admin_sql!(~s|DROP DATABASE IF EXISTS "#{db}" WITH (FORCE)|)
    end)

    # 独立一次性探针 Repo：name: nil 不注册（默认会注册为 Cgc2046.Repo 撞主进程）。
    # Ecto.Migrator 只认真实 Repo 模块——迁移经 dynamic_repo: pid 指到本进程。
    {:ok, repo} = Cgc2046.Repo.start_link(database: db, pool_size: 2, name: nil)

    # 探针连接须在 sandbox 包装事务外：迁移的真实提交/回滚语义是断言对象
    Sandbox.checkout(repo, sandbox: false)

    # 空库 = 全部 pending：一次跑完即"新建库"路径的完整验证
    assert Enum.map(migrations, &elem(&1, 0)) == migrate!(repo, migrations)

    {:ok, repo: repo, migrations: migrations}
  end

  test "T1 改名迁移重放幂等（no-op）且存量库路径真改名", %{repo: repo, migrations: migrations} do
    renames = rename_migrations(migrations)

    assert renames != [],
           "未发现任何导出 renames/0 的改名迁移——探针空转即红。" <>
             "改名类迁移以 @renames 为 opt-in：新改名迁移须声明 @renames 并导出 renames/0。"

    for {version, module, pairs} <- renames, {table, from, to} <- pairs do
      # 1) 幂等重放：head 库上抹掉版本行 ⇒ up 命中 already_renamed，不抛异常
      delete_version!(repo, version)

      assert [^version] = migrate!(repo, [{version, module}])

      assert renamed?(repo, table, from, to),
             "重放 #{version} 后应保持 #{to} 存在（幂等 no-op），" <>
               "实际 #{inspect(catalog(repo, table))}"

      # 2) 存量库路径：改回旧名（模拟 #611 之前的库）⇒ up 真改名
      rename_to(repo, [{table, from, to}], :old)
      delete_version!(repo, version)

      assert [^version] = migrate!(repo, [{version, module}])

      assert renamed?(repo, table, from, to),
             "存量库路径应把 #{from} 改名为 #{to}，实际 #{inspect(catalog(repo, table))}"
    end
  end

  test "T2 前置检查失败给「期望名 vs 实际名」，同迁移前几条改名整体回滚", %{
    repo: repo,
    migrations: migrations
  } do
    [{version, module, pairs} | _] = rename_migrations(migrations)
    {victim_table, victim_from, victim_to} = List.last(pairs)

    # 先摆成「存量库」态（全部改回旧名 = #611 之前的库），否则 head 库上前几条
    # 命中 already_renamed，没有"已执行的改名"可回滚，原子性断言会空转。
    rename_to(repo, pairs, :old)

    # 最后一条必然失败：把旧名也删掉 ⇒ from / to 皆缺
    with_repo(repo, fn -> Cgc2046.Repo.query!("DROP INDEX #{victim_from}") end)
    delete_version!(repo, version)

    error = assert_raise RuntimeError, fn -> migrate!(repo, [{version, module}]) end
    message = Exception.message(error)

    assert message =~ "identity 索引改名前置条件失败"
    assert message =~ "table:    #{victim_table}"
    assert message =~ "expected: #{victim_from} | #{victim_to}"
    assert message =~ "actual:"

    # 原子性：排在 victim 之前、本次已成功执行的改名必须随事务整体回滚
    # （5 条同迁移同事务，不留半改名中间态）
    for {table, from, to} <- Enum.drop(pairs, -1) do
      names = catalog(repo, table)

      assert from in names and to not in names,
             "迁移失败应整体回滚：#{table} 期望仍是旧名 #{from}，实际 #{inspect(names)}"
    end
  end

  # --- 探针基建 ----------------------------------------------------------------

  # 主 Repo 的管理面 DDL（CREATE/DROP DATABASE）须在 sandbox 包装事务外执行
  defp admin_sql!(statement) do
    Sandbox.unboxed_run(Cgc2046.Repo, fn -> SQL.query!(Cgc2046.Repo, statement) end)
  end

  # IndexCatalog 走 repo.query!（= get_dynamic_repo），故探针库查询临时切 dynamic repo。
  # 注意不能用 `Ecto.Adapters.SQL.query!(Cgc2046.Repo, ...)`——那个按 repo **模块** 查注册表
  # （`Ecto.Repo.Registry.lookup(atom)` → `GenServer.whereis`），恒打回主 Repo、忽视
  # dynamic repo，撞 sandbox :manual 的 ownership 检查。
  defp with_repo(repo, fun) do
    previous = Cgc2046.Repo.put_dynamic_repo(repo)

    try do
      fun.()
    after
      Cgc2046.Repo.put_dynamic_repo(previous)
    end
  end

  defp catalog(repo, table), do: with_repo(repo, fn -> IndexCatalog.index_names(table) end)

  defp migrate!(repo, migrations) do
    # 显式 {version, module} 列表 + all: true：只跑列表内 pending 的那些
    # （Ecto 要求 :all / :to / :step 之一；列表本身已把范围钉死）
    Ecto.Migrator.run(Cgc2046.Repo, migrations, :up,
      all: true,
      dynamic_repo: repo,
      log: false
    )
  end

  # 摆场景用：把给定改名对整体搬到旧名（:old）或目标名（:new）
  defp rename_to(repo, pairs, direction) do
    for {_table, from, to} <- pairs do
      {src, dst} = if direction == :old, do: {to, from}, else: {from, to}

      with_repo(repo, fn -> Cgc2046.Repo.query!("ALTER INDEX #{src} RENAME TO #{dst}") end)
    end
  end

  defp delete_version!(repo, version) do
    with_repo(repo, fn ->
      Cgc2046.Repo.query!("DELETE FROM schema_migrations WHERE version = $1", [version])
    end)
  end

  # 迁移文件一次性编译（见 moduledoc）；@renames 是 opt-in 单源
  defp migration_pairs! do
    @migrations_path
    |> Path.join("*.exs")
    |> Path.wildcard()
    |> Enum.map(fn path ->
      {version, _} = path |> Path.basename() |> Integer.parse()

      module =
        path
        |> Code.compile_file()
        |> Enum.map(&elem(&1, 0))
        |> Enum.find(&function_exported?(&1, :__migration__, 0))

      {version, module}
    end)
    |> Enum.sort()
  end

  defp rename_migrations(migrations) do
    for {version, module} <- migrations, function_exported?(module, :renames, 0) do
      {version, module, apply(module, :renames, [])}
    end
  end

  defp renamed?(repo, table, from, to) do
    with_repo(repo, fn ->
      names = IndexCatalog.index_names(table)
      present = IndexCatalog.present_unique_indexes([to])

      from not in names and MapSet.member?(present, to)
    end)
  end
end
