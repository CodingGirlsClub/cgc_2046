defmodule Cgc2046.EventsFixtures do
  @moduledoc """
  事件 / 课程测试布置的唯一入口。

  - `create_event/3` / `create_course/3`：默认 `:open` 报名策略、无容量上限、
    7 天后截止，属性经 attrs 覆盖；创建后强制置为 `open` 状态。
  - `force_open`：状态机无直达 open 的公开 action，此处的 UPDATE 裸 SQL 是布置
    而非被测对象——事件/课程生命周期测试应自行走域 action 推进状态。
  - `set_confirmed_count/3`：confirmed_count 无公开写 action（仅 Enrollment
    原子维护），裸 SQL 置位，与 force_open 同纪律。
  - `days_from_now/1`：badge / 时间过滤测试共用的布置时间源。
  """

  alias Cgc2046.Events.{Course, Event}

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

  # 布置而非被测对象：confirmed_count 无公开写 action（仅 Enrollment 原子维护），
  # 裸 SQL 置位（force_open 同款纪律）。
  def set_confirmed_count(record, table, count) do
    {:ok, _} =
      Ecto.Adapters.SQL.query(
        Cgc2046.Repo,
        "UPDATE #{table} SET confirmed_count = $1 WHERE id = $2",
        [count, Ecto.UUID.dump!(record.id)]
      )

    Ash.get!(record.__struct__, record.id, authorize?: false)
  end
end
