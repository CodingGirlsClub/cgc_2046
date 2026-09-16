defmodule Cgc2046.Initiatives.InitiativeLifecycleWorker do
  @moduledoc """
  到点收尾扫描（#628 ③）：`window_ends_at` 已过点的 `open` Initiative → `:close`
  （收尾口径：不级联、不退款，同 `Initiative :close`）。

  复用 `Cgc2046.Events.EventLifecycleWorker` 的成熟模式：

  - **Oban 唯一任务**（300s 窗口，与 cron 周期对齐）防并发双拍；
  - **拍内幂等 = 域 action 的 CAS**：逐条走 `Initiative :close`，其
    `transition/3` 在行锁内判「写前态必须是 open」——第二拍/并发手动 close
    的 `num_rows` 语义等价于状态不符 → 拒绝 → 记 warning 跳过，**不产生第二个
    副作用**（不发审计行、不改任何字段）；加之扫描本身带 `status == :open`，
    已收尾的活动连扫都扫不到；
  - **单条失败不中断整拍**（`close_record/1`）：手动 close 先落库属预期竞态。

  ## 触发条件与空窗语义

  `status = open` ∧ `window_ends_at` 非空 ∧ `window_ends_at < now()`。
  **`window_ends_at` 为空 = 永不自动收尾**（同 `EventLifecycleWorker` 对
  `registration_deadline = nil` 的语义，见该模块 :116-129）：不设窗口的活动只能
  人工 `:close` / `:cancel`。该分支每拍记一条 `debug` 计数（不刷 info 日志）。
  """

  use Oban.Worker,
    queue: :maintenance,
    max_attempts: 3,
    unique: [period: 300, states: :incomplete]

  require Ash.Query
  require Logger

  alias Cgc2046.Initiatives.Initiative

  @impl Oban.Worker
  def perform(%Oban.Job{}) do
    now = DateTime.utc_now()

    closed = close_overdue(now)
    without_window = count_open_without_window()

    if closed > 0 do
      Logger.info("initiative lifecycle sweep: closed #{closed} initiative(s)")
    end

    if without_window > 0 do
      Logger.debug(
        "initiative lifecycle sweep: #{without_window} open initiative(s) have no window_ends_at (never auto-closed)"
      )
    end

    :ok
  end

  defp close_overdue(now) do
    Initiative
    |> Ash.Query.filter(status == :open and not is_nil(window_ends_at) and window_ends_at < ^now)
    |> Ash.read!(authorize?: false)
    |> Enum.reduce(0, fn initiative, acc ->
      case close_record(initiative) do
        :ok -> acc + 1
        :skip -> acc
      end
    end)
  end

  defp count_open_without_window do
    Initiative
    |> Ash.Query.filter(status == :open and is_nil(window_ends_at))
    |> Ash.read!(authorize?: false)
    |> length()
  end

  defp close_record(initiative) do
    case initiative
         |> Ash.Changeset.for_update(:close, %{})
         |> Ash.update(authorize?: false) do
      {:ok, _} ->
        :ok

      {:error, reason} ->
        Logger.warning(
          "initiative lifecycle close failed for #{initiative.id}: #{inspect(reason)}"
        )

        :skip
    end
  end
end
