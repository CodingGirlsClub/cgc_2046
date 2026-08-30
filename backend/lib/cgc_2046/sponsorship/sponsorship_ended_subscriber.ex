defmodule Cgc2046.Sponsorship.SponsorshipEndedSubscriber do
  @moduledoc """
  赞助关系随 Event 结束自动 ended（E-3 #48；赞助 doc #5 待 v1 项由此落地）。

  订阅 `event.ended`（E-9 #124 事务内 outbox 生产）→ 该 Event 的全部 active
  Event 级 Sponsorship 转 ended（Workspace 级长期赞助不受影响）。
  订阅骨架与 claim-after 幂等语义（全部副作用成功才 claim，任一失败不写
  claim 等重投）由 `Cgc2046.Workflows.SignalSubscriber` 统一持有（语义事实
  见其 moduledoc）。
  """

  use Cgc2046.Workflows.SignalSubscriber,
    patterns: ["event.ended"],
    idempotency: :claim_after_effects,
    consumer_key: "sponsorship_ended_subscriber"

  require Ash.Query
  require Logger

  alias Cgc2046.Sponsorship.Sponsorship

  @impl Cgc2046.Workflows.SignalSubscriber
  def handle(_type, %{"event_id" => event_id}) when is_binary(event_id) do
    end_active_sponsorships(event_id)
  end

  def handle(_type, data) do
    Logger.warning(
      "SponsorshipEndedSubscriber received signal without event id: #{inspect(data)}"
    )

    :ok
  end

  # 仅 Event 级 active（Workspace 级 event_id IS NULL 天然不命中）。
  # 状态转换走 Sponsorship :end 领域 action（D-A6 纪律，不裸写 UPDATE）。
  # 返回 :ok（全部成功或无可转记录）| {:error, failed_count}（骨架不落 claim 等重投）。
  defp end_active_sponsorships(event_id) do
    Sponsorship
    |> Ash.Query.filter(event_id == ^event_id and status == :active)
    |> Ash.read!(authorize?: false)
    |> Enum.reduce(:ok, fn sponsorship, acc ->
      case sponsorship
           |> Ash.Changeset.for_update(:end, %{},
             tenant: sponsorship.workspace_id,
             authorize?: false
           )
           |> Ash.update(tenant: sponsorship.workspace_id, authorize?: false) do
        {:ok, _} ->
          acc

        {:error, reason} ->
          Logger.warning(
            "SponsorshipEndedSubscriber end failed for sponsorship #{sponsorship.id}: #{inspect(reason)}"
          )

          {:error, if(acc == :ok, do: 1, else: elem(acc, 1) + 1)}
      end
    end)
  end
end
