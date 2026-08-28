defmodule Cgc2046.EventsFixtures do
  @moduledoc """
  事件 / 课程测试布置的唯一入口。

  - `create_event/3` / `create_course/3`：默认 `:open` 报名策略、无容量上限、
    7 天后截止，属性经 attrs 覆盖；创建后强制置为 `open` 状态。
  - `force_open`：状态机无直达 open 的公开 action，此处的 UPDATE 裸 SQL 是布置
    而非被测对象——事件/课程生命周期测试应自行走域 action 推进状态。
  - `set_confirmed_count/3`：置位「已确认名额」语义——ADR-0009 PR⑤ U6 后占位
    计数权威在名额账本（CapacityLedger.occupancy），`confirmed_count` 列为展示
    投影（U7 起本布置置账本 occupancy 后经真实投影订阅器
    投递 `capacity.synced` 收敛显示列，不再直写 events/courses 表）。
    账本写无公开 action，裸 SQL 置位，与 force_open 同纪律。
  - `days_from_now/1`：badge / 时间过滤测试共用的布置时间源。
  """

  alias Cgc2046.Courses.Course
  alias Cgc2046.Events.Event

  def create_event(workspace, actor, attrs \\ %{}) do
    attrs =
      Map.merge(
        %{
          title: "Test Event",
          enrollment_policy: :open,
          capacity: nil,
          registration_deadline: DateTime.add(DateTime.utc_now(), 7, :day)
        },
        attrs
      )

    Event
    |> Ash.Changeset.for_create(:create, attrs, tenant: workspace.id)
    |> Ash.create!(tenant: workspace.id, actor: actor)
    |> force_open(:events)
  end

  def create_course(workspace, actor, attrs \\ %{}) do
    attrs =
      Map.merge(
        %{
          title: "Test Course",
          enrollment_policy: :open,
          capacity: nil,
          registration_deadline: DateTime.add(DateTime.utc_now(), 7, :day)
        },
        attrs
      )

    Course
    |> Ash.Changeset.for_create(:create, attrs, tenant: workspace.id)
    |> Ash.create!(tenant: workspace.id, actor: actor)
    |> force_open(:courses)
  end

  # 布置而非被测对象：状态机无直达 open 的公开 action，直接写库置位。
  defp force_open(record, table) do
    {:ok, _} =
      Ecto.Adapters.SQL.query(
        Cgc2046.Repo,
        "UPDATE #{table} SET status = 'open' WHERE id = $1",
        [Ecto.UUID.dump!(record.id)]
      )

    Ash.get!(record.__struct__, record.id, authorize?: false)
  end

  @doc "布置时间源：当前时间 + n 天。"
  def days_from_now(days), do: DateTime.add(DateTime.utc_now(), days, :day)

  @doc """
  读名额账本 occupancy（ADR-0009 PR⑤ U6：占位计数权威自 confirmed_count 迁账本）。
  无账本行（未占位过）视为 0。
  """
  def ledger_occupancy(record) do
    kind = if record.__struct__ == Cgc2046.Events.Event, do: :event, else: :course

    case Cgc2046.Admission.CapacityLedger.fetch_by_offering(kind, record.id) do
      {:ok, ledger} -> ledger.occupancy
      {:error, :not_found} -> 0
    end
  end

  # 布置而非被测对象（force_open 同款纪律）：U6 后「名额占用」权威 = 账本
  # occupancy（无行时按 offering 现值建行，懒建同口径）；confirmed_count 列是
  # 展示投影（U7 收编：置位账本 occupancy + 推进 sync_version 后，经真实投影
  # 订阅器投递 `capacity.synced` 收敛显示列——fixture 不再直写 events/courses
  # 表，显示口径与生产同路）。
  def set_confirmed_count(record, table, count) do
    kind = if table == :events, do: "event", else: "course"

    {:ok, %{rows: [[sync_version]]}} =
      Ecto.Adapters.SQL.query(
        Cgc2046.Repo,
        """
        INSERT INTO admission_capacity_ledgers
          (id, workspace_id, offering_kind, offering_id, status, capacity,
           registration_deadline, occupancy, sync_version, inserted_at, updated_at)
        SELECT gen_random_uuid(), o.workspace_id, $2, o.id, o.status, o.capacity,
               o.registration_deadline, $3, 1, NOW(), NOW()
        FROM #{table} o
        WHERE o.id = $1
        ON CONFLICT (offering_kind, offering_id)
        DO UPDATE SET occupancy = $3,
                      sync_version = admission_capacity_ledgers.sync_version + 1,
                      updated_at = NOW()
        RETURNING sync_version
        """,
        [Ecto.UUID.dump!(record.id), kind, count]
      )

    subscriber =
      if table == :events,
        do: Cgc2046.Events.CapacityProjectionSubscriber,
        else: Cgc2046.Courses.CapacityProjectionSubscriber

    :ok =
      Cgc2046.Workflows.SignalSubscriber.deliver(subscriber, %{
        type: "capacity.synced",
        data: %{
          "#{kind}_id" => record.id,
          "occupancy" => count,
          "sync_version" => sync_version,
          "idempotency_key" => "capacity.synced:#{record.id}",
          "workspace_id" => record.workspace_id
        }
      })

    Ash.get!(record.__struct__, record.id, authorize?: false)
  end
end
