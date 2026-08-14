defmodule Cgc2046.Repo do
  use AshPostgres.Repo, otp_app: :cgc_2046

  def installed_extensions do
    ["ash-functions", "citext"]
  end

  def min_pg_version, do: %Version{major: 16, minor: 0, patch: 0}

  @doc """
  获取事务级 advisory lock（pg_advisory_xact_lock 在事务提交/回滚时自动释放）。

  先设置 lock_timeout 防止连接池耗尽，再获取锁。

  opts：

  - `hash: :hashtext | :hashtextextended`（默认 `:hashtext`）——键哈希函数。
    miniprogram_code 用 `hashtextextended($1, 0)`（键域与 workspace/sponsorship
    锁分离，误换 hashtext 会碰撞/漂移）；键域零变化（PR-I D1）。

  ## 错误处理

  锁超时（`lock_not_available`）和死锁（`deadlock_detected`）会转为用户友好提示，
  避免原始 Postgres 错误暴露给用户。其他 PG 错误继续抛出，不掩盖非预期问题。
  """
  @spec acquire_lock!(String.t(), keyword()) :: :ok
  def acquire_lock!(key, opts \\ []) do
    hash = Keyword.get(opts, :hash, :hashtext)

    # 先设置 lock_timeout，再获取 advisory lock。
    # 分两次 query：PostgreSQL 不允许在 prepared statement 中执行多条命令。
    {:ok, _} =
      Ecto.Adapters.SQL.query(__MODULE__, "SET lock_timeout TO '5s'", [])

    case Ecto.Adapters.SQL.query(
           __MODULE__,
           "SELECT pg_advisory_xact_lock(#{hash_expression(hash)})",
           [key]
         ) do
      {:ok, _} ->
        :ok

      {:error, %Postgrex.Error{postgres: %{code: :lock_not_available}}} ->
        raise "工作台操作暂时繁忙，请稍后重试"

      {:error, %Postgrex.Error{postgres: %{code: :deadlock_detected}}} ->
        raise "检测到锁冲突，请稍后重试"

      {:error, err} ->
        raise err
    end
  end

  defp hash_expression(:hashtext), do: "hashtext($1)"
  defp hash_expression(:hashtextextended), do: "hashtextextended($1, 0)"

  @doc """
  Ecto.UUID.dump!/1 单点包装：裸 SQL 参数统一经此帮手 dump uuid（raw bytes 传参，
  值校验 + 明确 ArgumentError）。八处机械收敛（5 私有帮手 + 3 内联，PR-I D3）。
  """
  @spec uuid!(String.t()) :: <<_::128>>
  def uuid!(value), do: Ecto.UUID.dump!(value)
end
