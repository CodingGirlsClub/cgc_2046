defmodule Cgc2046.Workers.LoginArtifactPrunerWorker do
  @moduledoc """
  登录支撑表过期清理（#252）。

  `phone_verification_codes`（5min TTL）与 `wechat_login_tickets`（10min TTL）
  只进不出，生产无界增长。本 job 每小时删两表中 `expires_at` 早于
  now() - 1 天的行——保留 1 天窗口供排查（最近发码/出票记录可见），
  过期即不可用（消费路径全部校验 expires_at），删行不影响任何在途流程。

  - 频率档位：小时级（表 TTL 分钟级、保留窗天级，粒度足够；仓内
    ApprovalReminderWorker 同档）。
  - 实现：`Ecto.Adapters.SQL` 批删（两表均为内部资源直写 insert_all/原生
    UPDATE 的同一约定，不走 Ash action——无策略/通知面，纯运维删除）。
  - 幂等：重复执行零行删除，无副作用。
  """

  use Oban.Worker,
    queue: :maintenance,
    max_attempts: 3,
    unique: [period: 3_600, states: :incomplete]

  require Logger

  @retention_days 1
  @tables ~w(phone_verification_codes wechat_login_tickets)

  @impl Oban.Worker
  def perform(%Oban.Job{}) do
    cutoff = DateTime.add(DateTime.utc_now(), -@retention_days * 24 * 60 * 60, :second)

    results = Map.new(@tables, fn table -> {table, delete_expired(table, cutoff)} end)
    total = results |> Map.values() |> Enum.sum()
    Logger.info("[login_artifact_pruner] removed #{total} expired rows: #{inspect(results)}")

    :ok
  end

  defp delete_expired(table, %DateTime{} = cutoff) do
    # utc_datetime 列（naive）必须与 naive 参数同型比较——传 %DateTime{}
    # 会被编码为 timestamptz，naive 列在非 UTC 会话时区下按本地时区提升，
    # 比较错位 8 小时（advisor A5 同款坑）。app 侧算 UTC cutoff 传 naive。
    naive_cutoff = cutoff |> DateTime.to_naive() |> NaiveDateTime.truncate(:second)

    {:ok, %Postgrex.Result{num_rows: deleted}} =
      Ecto.Adapters.SQL.query(
        Cgc2046.Repo,
        "DELETE FROM #{table} WHERE expires_at < $1",
        [naive_cutoff]
      )

    deleted
  end
end
