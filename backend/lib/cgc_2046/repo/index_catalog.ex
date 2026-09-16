defmodule Cgc2046.Repo.IndexCatalog do
  @moduledoc """
  identity 推导索引名的单源判据（#611），三个消费者共用一套 helper：

  - 全仓守卫 `test/cgc_2046/identity_index_guard_test.exs`（DSL → `pg_indexes`）；
  - 改名迁移 `20260916200609_align_identity_index_names.exs` 的 DDL 前置检查；
  - 迁移探针 `test/cgc_2046/migration_probe_test.exs` 的改名前后断言。

  期望名的公式与 ash_postgres 自己**逐字同源**——注册唯一约束时
  （`deps/ash_postgres/lib/data_layer.ex:3740`）与生成迁移时
  （`deps/ash_postgres/lib/migration_generator/migration_generator.ex:4140`）都是：

      identity_index_names(resource)[identity.name] || "\#{table}_\#{identity.name}_index"

  故本模块钉的不是「命名惯例」而是**运行时真正注册给 Ecto 的那串约束名**
  （`unique_constraint(name: ..., match: :exact)`，`AshPostgres.Repo` 的
  `default_constraint_match_type/2` 默认 `:exact`）。名字对不上 ⇒ 冲突落
  `Ash.Error.Unknown`（#612 兜底成 database_error，MCP 面原文含索引名）；
  名字对但索引不唯一 ⇒ 同样接不上，故存在性判定必须叠加 `indisunique`。

  注意 `<table>_<identity>_index` 有例外：`workspace_memberships` /
  `workspace_profiles` 用 `postgres.identity_index_names` 覆盖成
  `wm_unique_ws_user_idx` / `wsp_unique_ws_user_idx`——这正是不能手写字符串
  拼名字、必须走 `AshPostgres.DataLayer.Info` 的原因。
  """

  @doc """
  全部 postgres resource 的 identity 期望索引（按 table / identity 排序）。

  返回 `%{resource: module, table: String.t(), identity: atom, index_name: String.t()}`。
  """
  @spec expected_identity_indexes() :: [
          %{resource: module, table: String.t(), identity: atom, index_name: String.t()}
        ]
  def expected_identity_indexes do
    :cgc_2046
    |> Application.get_env(:ash_domains, [])
    |> Enum.flat_map(&Ash.Domain.Info.resources/1)
    |> Enum.uniq()
    |> Enum.flat_map(&resource_identity_indexes/1)
    |> Enum.sort_by(&{&1.table, &1.identity})
  end

  defp resource_identity_indexes(resource) do
    table = AshPostgres.DataLayer.Info.table(resource)

    if table do
      overrides = AshPostgres.DataLayer.Info.identity_index_names(resource)

      for identity <- Ash.Resource.Info.identities(resource) do
        %{
          resource: resource,
          table: to_string(table),
          identity: identity.name,
          index_name: overrides[identity.name] || "#{table}_#{identity.name}_index"
        }
      end
    else
      []
    end
  end

  @doc """
  给定索引名集合里，DB 中真实存在**且唯一**的子集（`pg_indexes` × `pg_index`）。
  """
  @spec present_unique_indexes([String.t()], module) :: MapSet.t(String.t())
  def present_unique_indexes(names, repo \\ Cgc2046.Repo) do
    %{rows: rows} =
      repo.query!(
        """
        SELECT p.indexname
        FROM pg_indexes p
        JOIN pg_class c ON c.relname = p.indexname AND c.relnamespace = 'public'::regnamespace
        JOIN pg_index i ON i.indexrelid = c.oid
        WHERE p.schemaname = 'public'
          AND i.indisunique
          AND p.indexname = ANY($1::text[])
        """,
        [names]
      )

    rows |> List.flatten() |> MapSet.new()
  end

  @doc """
  某表在 DB 中的全部索引名（迁移前置检查与失败诊断用，排序稳定便于断言/报错阅读）。

  迁移体内调用须传 `Ecto.Migration.repo()`：Ecto 迁移体与 `repo.transaction/2`
  同进程执行（`Ecto.Migrator.run_maybe_in_transaction/5`），故该 repo 上的查询
  加入迁移事务，读到的就是本事务视图。
  """
  @spec index_names(String.t(), module) :: [String.t()]
  def index_names(table, repo \\ Cgc2046.Repo) do
    %{rows: rows} =
      repo.query!(
        """
        SELECT indexname FROM pg_indexes
        WHERE schemaname = 'public' AND tablename = $1
        ORDER BY indexname
        """,
        [table]
      )

    List.flatten(rows)
  end
end
