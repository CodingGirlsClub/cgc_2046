defmodule Cgc2046.Repo.Migrations.AlignIdentityIndexNames do
  @moduledoc """
  #611：5 处 identity 索引名与 Ash identity 推导名对齐（纯 catalog rename）。

  根因同 #604：手写 migration 用 `create(unique_index(...))` 走 Ecto 默认命名，
  而 ash_postgres 注册的是 `unique_constraint(name: identity_index_names[name] ||
  "<table>_<identity>_index", match: :exact)`（`deps/ash_postgres/lib/data_layer.ex:3740`）
  ——名字永不匹配 ⇒ 冲突落 `Ash.Error.Unknown`（#612 兜底成 `database_error`，
  MCP 面原文含索引名 + 该 changeset 注册的全部约束名）。5 处旧名来源：

    * `20260901000000_squash_baseline.exs` :1099（mcp_tokens）/ :1157（wechat_login_tickets）
      / :1281（speaker_invitations）
    * `20260913155651_create_initiatives_and_moderators.exs` :36（initiative_rules）
      / :84（event_moderators）

  ## 写法

  `@renames` 是改名对单源，并经 `renames/0` 导出——`@tag :migration_probe` 探针据此
  **自动发现**改名类迁移（`test/cgc_2046/migration_probe_test.exs`），不另维护清单，
  也不可能与实际 DDL 漂移。改名类迁移以 `@renames` 为 opt-in：`20260916130000`
  未声明，故探针不覆盖它（该迁移"索引已改名 + 版本行缺失"的组合在任何真实路径都
  不可达——改名与版本行同事务写入）。

  ## 前置检查与幂等

  每条 rename 先查该表实际索引：旧名在 → 真改名；旧名不在但**目标名在** → 幂等 no-op
  （覆盖恢复演练 / 曾被手工改过的库 / 版本行被删后的重放）；两名皆无 → 报
  「期望名 vs 实际名」并 abort（比 Postgres 的 `42P01 relation does not exist` 可读）。
  不用 `ALTER INDEX IF EXISTS`：那会在改名失效时静默通过，正是本 issue 要消灭的
  "漂移复活且无人知道"。

  并发纪律（backend/AGENTS.md）：`ALTER INDEX ... RENAME` 是纯目录更新，实测只在索引
  自身取 ShareUpdateExclusiveLock、父表零锁、事务内可执行（#604 实证），故不加
  `@disable_ddl_transaction`。5 条同迁移同事务：任一条前置失败则全部回滚，不存在
  半改名的中间态。`down` 逆序、同款前置检查，可逆。
  """
  use Ecto.Migration

  alias Cgc2046.Repo.IndexCatalog

  @renames [
    {"initiative_rules", "initiative_rules_initiative_id_key_index",
     "initiative_rules_unique_initiative_key_index"},
    {"event_moderators", "event_moderators_event_id_user_id_index",
     "event_moderators_unique_event_user_index"},
    {"mcp_tokens", "mcp_tokens_token_hash_index", "mcp_tokens_unique_token_hash_index"},
    {"speaker_invitations", "speaker_invitations_unique_event_email_index",
     "speaker_invitations_unique_event_speaker_index"},
    {"wechat_login_tickets", "wechat_login_tickets_state_index",
     "wechat_login_tickets_unique_state_index"}
  ]

  @doc """
  改名对 `[{table, from, to}]` 单源（迁移探针自动发现入口，勿删）。
  """
  def renames, do: @renames

  def up do
    Enum.each(@renames, fn {table, from, to} -> rename_index!(table, from, to) end)
  end

  def down do
    @renames
    |> Enum.reverse()
    |> Enum.each(fn {table, from, to} -> rename_index!(table, to, from) end)
  end

  defp rename_index!(table, from, to) do
    actual = IndexCatalog.index_names(table, Ecto.Migration.repo())

    cond do
      from in actual ->
        execute("ALTER INDEX #{from} RENAME TO #{to}")

      to in actual ->
        :already_renamed

      true ->
        raise """
        identity 索引改名前置条件失败：`#{from}` 与 `#{to}` 都不存在。
          table:    #{table}
          expected: #{from} | #{to}
          actual:   #{inspect(actual)}
        """
    end
  end
end
