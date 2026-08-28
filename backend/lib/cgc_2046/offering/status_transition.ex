defmodule Cgc2046.Offering.StatusTransition do
  @moduledoc """
  状态机 CAS helper（KTD2：offering 层共享纯函数内核，Event/Course 状态机共用）。

  DB 级 compare-and-set：条件 UPDATE 原子抢占状态迁移（enrollment.expire 同款
  纪律）。num_rows=0 → 并发竞态（cron 与手动双拍），拒绝而非双成功双发布。
  成功后由调用方 force_change（Ash 后续写同值幂等，返回 record 状态正确）。
  """

  alias Cgc2046.Repo

  @doc "对 table（\"events\" / \"courses\"）执行 status 条件 UPDATE。"
  @spec run(Ash.Changeset.t(), String.t(), atom()) ::
          :ok | {:error, :status_race | {:database, term()}}
  def run(changeset, table, to_status) do
    sql = "UPDATE #{table} SET status = $1, updated_at = NOW() WHERE id = $2 AND status = $3"
    id = Ash.Changeset.get_data(changeset, :id)
    from_status = Ash.Changeset.get_data(changeset, :status)

    case Repo.query(sql, [to_string(to_status), Repo.uuid!(id), to_string(from_status)]) do
      {:ok, %{num_rows: 1}} ->
        :ok

      {:ok, %{num_rows: 0}} ->
        {:error, :status_race}

      {:error, reason} ->
        {:error, {:database, reason}}
    end
  end
end
