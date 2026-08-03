defmodule Cgc2046.Repo do
  use AshPostgres.Repo, otp_app: :cgc_2046

  def installed_extensions do
    ["ash-functions", "citext"]
  end

  def min_pg_version, do: %Version{major: 16, minor: 0, patch: 0}

  @doc """
  获取 per-workspace 事务级 advisory lock（pg_advisory_xact_lock 在事务提交/回滚时自动释放）。

  先设置 lock_timeout 防止连接池耗尽，再获取锁。
  用于序列化同工作台的 owner 变更操作。
  """
  @spec acquire_workspace_lock!(String.t()) :: :ok
  def acquire_workspace_lock!(workspace_id) do
    # 先设置 lock_timeout，再获取 advisory lock。
    # 分两次 query：PostgreSQL 不允许在 prepared statement 中执行多条命令。
    {:ok, _} =
      Ecto.Adapters.SQL.query(__MODULE__, "SET lock_timeout TO '5s'", [])

    {:ok, _} =
      Ecto.Adapters.SQL.query(
        __MODULE__,
        "SELECT pg_advisory_xact_lock(hashtext($1))",
        [workspace_id]
      )

    :ok
  end
end
