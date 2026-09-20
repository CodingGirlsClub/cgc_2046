defmodule Cgc2046.Events.Qualification do
  @moduledoc """
  Deadline qualification primitive for Events.

  The event row is locked before taking the confirmed enrollment snapshot and
  the pending qualification status is a compare-and-set. Repeated scans
  therefore return `:skip` and cannot reverse an already recorded fact.

  Judgment anchor (#585 R2): an explicit `registration_deadline` always wins;
  events without one fall back to `starts_at - 72h` (see `effective_deadline/1`).
  """
  require Ash.Query
  require Logger

  alias Cgc2046.Admission.Enrollment
  alias Cgc2046.Events.Event

  # 无截止场的判定提前量（#585 R2）：issue 定 72h。
  @fallback_window_hours 72

  @doc """
  判定锚点单源（#585 R2）：显式 `registration_deadline` 恒胜兜底；未设截止回落
  `starts_at - #{@fallback_window_hours}h`；两者皆 nil → nil。qualify 的判定守卫与
  `EventLifecycleWorker` 的候选/判定都以此为准——`starts_at` 也未设的场返回 nil，
  调用方显式 skip（永不判定，接受语义：deposit 场有 CHECK 强制 deadline、pricing
  场强制 starts_at，双 nil 人群只剩免费 + 无截止 + 无开始时间的小众场）。
  """
  @spec effective_deadline(Event.t()) :: DateTime.t() | nil
  def effective_deadline(%Event{registration_deadline: %DateTime{} = deadline}), do: deadline

  def effective_deadline(%Event{starts_at: %DateTime{} = starts_at}),
    do: DateTime.add(starts_at, -@fallback_window_hours, :hour)

  def effective_deadline(%Event{}), do: nil

  @doc "兜底窗口小时数——EventLifecycleWorker 候选查询与 effective_deadline/1 同源。"
  @spec fallback_window_hours() :: pos_integer()
  def fallback_window_hours, do: @fallback_window_hours

  @spec qualify(Event.t()) ::
          {:ok, :confirmed | :underfilled, list(), non_neg_integer()} | :skip | :not_applicable
  def qualify(%Event{min_participants: nil}), do: :not_applicable

  def qualify(event) do
    case Cgc2046.Repo.transaction(fn ->
           case Cgc2046.Repo.query(
                  "SELECT qualification_status, status FROM events WHERE id = $1 FOR UPDATE",
                  [uuid_param(event.id)]
                ) do
             {:ok, %{rows: [["pending", "open"]]}} ->
               event = Ash.get!(Event, event.id, authorize?: false)
               deadline = effective_deadline(event)

               if is_nil(event.min_participants) or is_nil(deadline) or
                    DateTime.compare(deadline, DateTime.utc_now()) != :lt do
                 :skip
               else
                 {:ok, %{rows: [[confirmed_count]]}} =
                   Cgc2046.Repo.query(
                     "SELECT COUNT(*) FROM enrollments WHERE event_id = $1 AND status = 'confirmed'",
                     [uuid_param(event.id)]
                   )

                 outcome =
                   if confirmed_count >= event.min_participants,
                     do: :confirmed,
                     else: :underfilled

                 {:ok, %{num_rows: 1}} =
                   Cgc2046.Repo.query(
                     "UPDATE events SET qualification_status = $1, updated_at = NOW() WHERE id = $2 AND qualification_status = 'pending' AND status = 'open'",
                     [to_string(outcome), uuid_param(event.id)]
                   )

                 recipients =
                   Enrollment
                   |> Ash.Query.filter(
                     event_id == ^event.id and status in [:pending, :payment_pending, :confirmed]
                   )
                   |> Ash.read!(authorize?: false, tenant: event.workspace_id)

                 enqueue_notifications(event, outcome, recipients, confirmed_count)

                 {:ok, outcome, recipients, confirmed_count}
               end

             _ ->
               :skip
           end
         end) do
      {:ok, {:ok, outcome, recipients, confirmed_count}} ->
        {:ok, outcome, recipients, confirmed_count}

      {:ok, :skip} ->
        :skip

      {:error, reason} ->
        Logger.warning("event qualification failed for #{event.id}: #{inspect(reason)}")
        :skip
    end
  end

  defp uuid_param(<<_::128>> = id), do: id
  defp uuid_param(id), do: Ecto.UUID.dump!(id)

  defp enqueue_notifications(event, outcome, enrollments, count) do
    template =
      if outcome == :confirmed,
        do: "event_qualification_confirmed",
        else: "event_qualification_underfilled"

    data = %{
      "event_id" => event.id,
      "title" => event.title,
      "min_participants" => event.min_participants,
      "confirmed_count" => count
    }

    Enum.each(enrollments, fn enrollment ->
      Cgc2046.Notifications.Delivery.enqueue(
        {enrollment.user_id, Cgc2046.Notifications.Fanout.identities(enrollment.user_id)},
        template,
        data,
        %{"event_id" => event.id, "idempotency_key" => "qualification:" <> event.id}
      )
    end)

    # 管理腿（#585 R1）：Owner/Admin 与参与者同事务入 outbox，收件口径 =
    # Fanout.managers/2 缺省 :manage（Role.manage_roles/0 唯一真源，与
    # enrollment_submitted 同款先例）。独立幂等基键：双角色（既报名又是管理者）
    # 参与者/管理者两条各达——共享基键会被 outbox upsert 首写胜出吞掉管理文案。
    manager_data = Map.put(data, "outcome", to_string(outcome))

    event.workspace_id
    |> Cgc2046.Notifications.Fanout.managers()
    |> Enum.each(fn {user_id, identities} ->
      Cgc2046.Notifications.Delivery.enqueue(
        {user_id, identities},
        "event_qualification_manager",
        manager_data,
        %{"event_id" => event.id, "idempotency_key" => "qualification:manager:" <> event.id}
      )
    end)
  end
end
