defmodule Cgc2046.StatusTransition do
  @moduledoc """
  Event/Course 状态机 CAS 原语唯一真源（ADR-0009 D5：Offering 端口纯读投影契约、
  零写入——本写原语自 offering/ 迁出，落根部，与 ApprovalClaim「横切写原语单文件」
  先例同款）。

  DB 级 compare-and-set：条件 UPDATE 原子抢占状态迁移（enrollment.expire 同款
  纪律）。num_rows=0 → 并发竞态（cron 与手动双拍），拒绝而非双成功双发布。
  成功后由调用方 force_change（Ash 后续写同值幂等，返回 record 状态正确）。

  table 参数是编译期白名单 atom（:events | :courses），拒绝任意字符串——
  表名直接插 SQL，字符串入口即注入面（ApprovalClaim fetch_table! 同款校验）。
  """

  alias Cgc2046.Repo

  @tables [:events, :courses]

  @doc "对 table（:events / :courses）执行 status 条件 UPDATE。"
  @spec run(Ash.Changeset.t(), :events | :courses, atom()) ::
          :ok | {:error, :status_race | {:database, term()}}
  def run(changeset, table, to_status) do
    unless table in @tables do
      raise ArgumentError,
            "StatusTransition: 未知 table #{inspect(table)}（允许：#{inspect(@tables)}）"
    end

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
