defmodule Cgc2046.Admission.CapacityLedgerSubscriber do
  @moduledoc """
  名额账本信号订阅器（ADR-0009 PR⑤ U6；R13/R16；KTD4/KTD5）。

  三族信号一个动作——经 Offering 端口回查实体最新值，覆盖式同步账本行
  （`CapacityLedger.sync_from_offering/1`）：

  - `event.launched` / `course.launched`：建行（payload 不扩字段，回读优于
    信号快照，KTD5）；与报名路径懒建 upsert 的竞态由
    `(offering_kind, offering_id)` 唯一索引幂等吸收。
  - `offering.capacity_changed`：capacity / registration_deadline 编辑传播
    （R16；Event/Course `:update` 检测到变更才发）。
  - `event.ended` / `course.ended`：close / cancel 后回查 status 更新缓存
    （账本 CAS 的 status 守卫随后拒新单）。

  幂等策略 `:state_based`：所有副作用为回查式覆盖写，天然幂等、乱序自收敛，
  无需 claim（Curriculum.Instantiator 同款）。订阅骨架由
  `Cgc2046.Workflows.SignalSubscriber` 统一持有。

  注意（issue #587）：`offering.capacity_changed` **不是**账本缓存更新的唯一
  来源——锁死规则传播（`Initiatives.RuleInheritance`）在规则事务内直连
  `CapacityLedger.sync_offering_cache/1`，**有意不发**该信号（信号经 Oban
  异步投递，满足不了报名截止执法的同事务收敛）。新增订阅方必须显式把规则
  传播路径纳入，不得假设它会发信号。
  """

  use Cgc2046.Workflows.SignalSubscriber,
    patterns: [
      "event.launched",
      "course.launched",
      "event.ended",
      "course.ended",
      "offering.capacity_changed"
    ],
    idempotency: :state_based,
    consumer_key: "capacity_ledger_subscriber"

  require Logger

  alias Cgc2046.Admission.CapacityLedger

  @impl Cgc2046.Workflows.SignalSubscriber
  def handle(type, data) do
    case Cgc2046.Offering.fetch_by_signal_payload(data) do
      {:ok, entity} ->
        case CapacityLedger.sync_from_offering(entity) do
          :ok ->
            :ok

          {:error, reason} ->
            Logger.error("CapacityLedgerSubscriber sync failed for #{type}: #{inspect(reason)}")

            {:error, reason}
        end

      {:error, :not_found} ->
        Logger.warning(
          "CapacityLedgerSubscriber received #{type} for unknown offering: #{inspect(data)}"
        )

        :ok
    end
  end
end
