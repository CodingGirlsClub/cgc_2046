defmodule Cgc2046.Repo.Migrations.AddTokenKind do
  @moduledoc """
  连接 token 分类（ADR-0022）：

  - `mcp_tokens.kind`：`terminal`（默认，存量行即此值）或 `learning_host`（配对签发）。
  - `mcp_tool_call_logs.token_kind`：可空；审计按凭证类型区分。

  两张都是活表：加常量默认值的列、加可空列在 PG11+ 只改元数据，不重写表。

  `down` 先撤销全部未撤销的 `learning_host` 凭证，再删列：删列后它们与终端 token 无从区分，
  撤销保证它们在任何版本的代码下都不再生效，不只依赖域分隔哈希。
  """

  use Ecto.Migration

  def up do
    alter table(:mcp_tokens) do
      add :kind, :text, null: false, default: "terminal"
    end

    alter table(:mcp_tool_call_logs) do
      add :token_kind, :text
    end
  end

  def down do
    execute("""
    UPDATE mcp_tokens SET revoked_at = now() AT TIME ZONE 'utc'
    WHERE kind = 'learning_host' AND revoked_at IS NULL
    """)

    alter table(:mcp_tokens) do
      remove :kind
    end

    alter table(:mcp_tool_call_logs) do
      remove :token_kind
    end
  end
end
