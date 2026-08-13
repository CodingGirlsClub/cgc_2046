defmodule Cgc2046.Events.SponsorshipEndedSubscriber do
  @moduledoc """
  赞助关系随 Event 结束自动 ended（E-3 #48；赞助 doc #5 待 v1 项由此落地）。

  订阅 `event.ended`（E-9 #124 事务内 outbox 生产）→ 该 Event 的全部 active
  Event 级 Sponsorship 转 ended（Workspace 级长期赞助不受影响）。

  与 ResearchRunReaper 同款 GenServer 骨架与幂等语义（先执行后 claim，全部成功
  才 claim）：:end action 状态守卫幂等（重复投递重放无害）；任一转换失败不写
  claim → 重投（SignalPublishWorker 重试或对账）仍会执行，逃逸 active 行不会与
  「已完成」claim 并存。订阅回调在 JidoAdapter.subscribe 转发的独立进程中执行，
  rescue 兜底防订阅进程崩溃。
  """

  use GenServer

  require Ash.Query
  require Logger

  alias Cgc2046.Events.Sponsorship
  alias Cgc2046.Workflows.{JidoAdapter, SignalIdempotency}

  @signal_patterns ["event.ended"]

  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @impl true
  def init(_opts) do
    Enum.each(@signal_patterns, fn pattern ->
      case JidoAdapter.subscribe(pattern, &handle_signal/1, nil) do
        {:ok, _sub_id} ->
          :ok

        {:error, reason} ->
          Logger.warning(
            "SponsorshipEndedSubscriber subscribe #{pattern} failed: #{inspect(reason)}"
          )
      end
    end)

    {:ok, %{}}
  end

  # signal.data 形态（close/cancel action 发布）：%{"event_id" => id, "title" => ...}
  def handle_signal(signal) do
    data = Map.get(signal, :data) || %{}

    case Map.get(data, "event_id") do
      event_id when is_binary(event_id) ->
        end_sponsorships_then_claim(event_id)

      _ ->
        Logger.warning(
          "SponsorshipEndedSubscriber received signal without event id: #{inspect(data)}"
        )
    end

    :ok
  rescue
    e ->
      Logger.warning("SponsorshipEndedSubscriber signal handling failed: #{Exception.message(e)}")
      :ok
  end

  # 全部 ended 成功（或无可转记录）才写 claim；任一失败不写 → 重投仍执行。
  defp end_sponsorships_then_claim(event_id) do
    case end_active_sponsorships(event_id) do
      :ok ->
        case SignalIdempotency.claim(
               "event.ended",
               "event.ended:event_#{event_id}:sponsorship_ended"
             ) do
          :ok -> :ok
          {:error, :already_claimed} -> :ok
        end

      {:error, failed} ->
        Logger.error(
          "SponsorshipEndedSubscriber: #{failed} sponsorship end(s) failed for event #{event_id}; claim skipped for redelivery"
        )

        :ok
    end
  end

  # 仅 Event 级 active（Workspace 级 event_id IS NULL 天然不命中）。
  # 状态转换走 Sponsorship :end 领域 action（D-A6 纪律，不裸写 UPDATE）。
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
