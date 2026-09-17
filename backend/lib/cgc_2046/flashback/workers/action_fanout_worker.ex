defmodule Cgc2046.Flashback.Workers.ActionFanoutWorker do
  @moduledoc """
  成场通知分派（U7/R13a/KTD5）：卡 scheduled 后按附议者**平台身份**分通道——

  - 有平台身份（person.user_id）→ `Notifications.Fanout`（微信/tt/xhs 订阅
    消息，`flashback_action_scheduled` 模板；配额不足由 NotificationWorker
    终态 discard + 可 grep 日志承接，无需预判）；
  - 未注册链接持有者 → U8 outreach（邮件/短信，模板 `action_scheduled`；
    payload 带 card_id 锚点由 OutreachWorker stale 重查成场信息）。

  幂等：`unique: [fields: [:worker, :args], states: :all]`——重复入队被吞；
  执行时重查卡状态（非 scheduled 静默跳过，重查教训 L5）。
  """

  use Oban.Worker,
    queue: :notifications,
    max_attempts: 3,
    unique: [period: 604_800, fields: [:worker, :args], states: :all]

  require Ash.Query

  alias Cgc2046.Flashback.{ActionCard, Endorsement, Person}
  alias Cgc2046.Flashback.Outreach.Dispatch
  alias Cgc2046.Notifications.Fanout

  @template_key "flashback_action_scheduled"

  @impl Oban.Worker
  def perform(%Oban.Job{args: %{"card_id" => card_id}}) do
    case fetch_scheduled_card(card_id) do
      {:ok, card} ->
        endorsers(card.id)
        |> Enum.each(&deliver_one(card, &1))

        :ok

      {:skip, _detail} ->
        :ok

      {:error, reason} ->
        {:error, inspect(reason)}
    end
  end

  def perform(_job), do: :ok

  # ── 通道分派（KTD5） ─────────────────────────────────────────────────

  defp deliver_one(%ActionCard{} = card, %Person{user_id: user_id} = _person)
       when not is_nil(user_id) do
    # payload 带 card_id 锚点 + event_id 直链；Fanout 逐身份入队（同用户
    # 多身份不折叠）。失败只 log（成场通知 best-effort，重试由 unique 幂等
    # 语义之外的 Oban attempts 承接）。
    Fanout.deliver(
      {user_id, Fanout.identities(user_id)},
      @template_key,
      %{"card_id" => card.id, "event_id" => card.event_id, "title" => card.title},
      %{"card_id" => card.id}
    )
  end

  defp deliver_one(%ActionCard{} = card, %Person{} = person) do
    # 未注册附议者 → U8 outreach 邮件/短信（批次号锚定卡，unique_send 幂等）。
    Dispatch.enqueue_persons([person.id], "action_scheduled", "card-" <> card.id)
  end

  # ── 内部 ─────────────────────────────────────────────────────────────

  # stale 重查：卡不存在 / 未 scheduled（被撤下或回滚）→ 静默跳过。
  defp fetch_scheduled_card(card_id) do
    ActionCard
    |> Ash.Query.for_read(:read)
    |> Ash.Query.filter(id == ^card_id)
    |> Ash.read_one(authorize?: false)
    |> case do
      {:ok, %ActionCard{status: :scheduled} = card} ->
        {:ok, card}

      {:ok, _other} ->
        {:skip, "card_not_scheduled"}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp endorsers(card_id) do
    person_ids =
      Endorsement
      |> Ash.Query.for_read(:read)
      |> Ash.Query.filter(card_id == ^card_id)
      |> Ash.read!(authorize?: false, page: false)
      |> Enum.map(& &1.person_id)
      |> Enum.uniq()

    Person
    |> Ash.Query.for_read(:read)
    |> Ash.Query.filter(id in ^person_ids)
    |> Ash.read!(authorize?: false, page: false)
  end
end
