defmodule Cgc2046.Repo.Migrations.AlignInitiativeSlugIndexName do
  @moduledoc """
  #604：唯一索引名与 Ash identity 名对齐（纯 catalog rename）。

  背景：`20260913155651` 用 `create(unique_index(:initiatives, [:slug]))` 建出
  Ecto 默认名 `initiatives_slug_index`，而 `Initiative` 的
  `identity(:unique_slug, [:slug])` 让 ash_postgres 注册
  `unique_constraint(:slug, name: "initiatives_unique_slug_index", match: :exact)`
  ——名字永远匹配不上 ⇒ 撞 slug 时 Ecto 不转 changeset 错误，落
  `Ash.Error.Unknown`（原文含索引名 + 该 changeset 注册的全部约束名）。
  错误到业务码的转换见 `Initiative.handle_write_error/2`。

  并发纪律（backend/AGENTS.md）：加索引才需要
  `@disable_ddl_transaction true` + `concurrently: true`；`ALTER INDEX ... RENAME`
  是纯目录更新，实测只在索引自身取 ShareUpdateExclusiveLock（父表 `initiatives`
  无锁），事务内可执行，故保持默认事务。up/down 对称、可逆。

  写法说明：不用 `rename index(:initiatives, :initiatives_slug_index)`——Ecto
  `index/2` 把第二个参数当**列名**，会推出 `initiatives_initiatives_slug_index_index`
  这个不存在的名字（实测 42P01）。裸 `execute` 与 20260903000000 的索引更名同款。
  """
  use Ecto.Migration

  def up do
    execute("ALTER INDEX initiatives_slug_index RENAME TO initiatives_unique_slug_index")
  end

  def down do
    execute("ALTER INDEX initiatives_unique_slug_index RENAME TO initiatives_slug_index")
  end
end
