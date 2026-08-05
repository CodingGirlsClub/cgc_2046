defmodule Cgc2046.Repo.Migrations.DropInvitationsPlainToken do
  @moduledoc """
  删除 invitations.plain_token 列（P1 #1 安全修复）。

  明文邀请令牌不再持久化，改为 create action metadata 一次性返回。
  详见 `Cgc2046.Accounts.Invitation` create action 的 `metadata(:plain_token, ...)`。
  """

  use Ecto.Migration

  defp column_exists?(table, column) do
    repo()
    |> Ecto.Adapters.SQL.query!(
      "SELECT 1 FROM information_schema.columns WHERE table_schema = 'public' AND table_name = $1 AND column_name = $2",
      [to_string(table), to_string(column)]
    )
    |> then(fn result -> result.num_rows > 0 end)
  end

  def up do
    if column_exists?(:invitations, :plain_token) do
      alter table(:invitations) do
        remove :plain_token
      end
    end
  end

  # 不实现 down：重建 plain_token 列即退回明文存储的不安全状态，不提供回滚路径。
  def down do
    :ok
  end
end
