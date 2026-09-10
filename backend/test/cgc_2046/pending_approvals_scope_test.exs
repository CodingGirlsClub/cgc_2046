defmodule Cgc2046.PendingApprovalsScopeTest do
  @moduledoc """
  018：`PendingApprovals.list/2` 的 `:workspace_id` 单台收窄。

  缺省行为不变（跨台聚合）；传入 `workspace_id:` 后查询层只聚合该台——
  MCP `list_my_tasks` 等单工作台消费者不再为丢弃的跨台行付 3×W 查询 +
  enrich 批量装配。
  """

  use Cgc2046.DataCase, async: true

  alias Cgc2046.AccountsFixtures, as: Fixtures
  alias Cgc2046.Admission.Enrollment
  alias Cgc2046.EventsFixtures, as: EventFixtures
  alias Cgc2046.PendingApprovals

  test "缺省聚合全部受管台；workspace_id 收窄单台；非受管台空集" do
    platform_admin = Fixtures.platform_admin("scope-platform-" <> uniq())
    owner = Fixtures.register_user("scope-owner-" <> uniq())

    ws_a = Fixtures.create_workspace(platform_admin, %{name: "Scope A"})
    ws_b = Fixtures.create_workspace(platform_admin, %{name: "Scope B"})
    Fixtures.add_member(ws_a, owner, [:owner])
    Fixtures.add_member(ws_b, owner, [:owner])

    applicant_a = Fixtures.register_user("scope-applicant-a-" <> uniq())
    applicant_b = Fixtures.register_user("scope-applicant-b-" <> uniq())

    event_a = EventFixtures.create_event(ws_a, platform_admin, %{enrollment_policy: :request})
    event_b = EventFixtures.create_event(ws_b, platform_admin, %{enrollment_policy: :request})

    pending_a = create_pending_enrollment(event_a, applicant_a, ws_a)
    pending_b = create_pending_enrollment(event_b, applicant_b, ws_b)

    # 缺省：跨台聚合（行为不变）
    assert {:ok, rows} = PendingApprovals.list(owner)
    assert Enum.sort(Enum.map(rows, & &1.workspace_id)) == Enum.sort([ws_a.id, ws_b.id])

    # 收窄单台：只回该台行
    assert {:ok, rows_a} = PendingApprovals.list(owner, workspace_id: ws_a.id)
    assert Enum.map(rows_a, & &1.id) == [pending_a.id]

    assert {:ok, rows_b} = PendingApprovals.list(owner, workspace_id: ws_b.id)
    assert Enum.map(rows_b, & &1.id) == [pending_b.id]

    # 非受管 workspace_id → 空集（不报错），与跨台聚合后过滤为空同语义
    stranger_ws = Fixtures.create_workspace(platform_admin, %{name: "Scope C"})

    assert {:ok, []} = PendingApprovals.list(owner, workspace_id: stranger_ws.id)

    # 行形状零回归：收窄路径与缺省路径返回同一行（同 id 同台）
    row_a = hd(rows_a)

    assert row_a.id == pending_a.id
    assert row_a.workspace_id == ws_a.id
    assert row_a.id in Enum.map(rows, & &1.id)
  end

  defp create_pending_enrollment(event, applicant, workspace) do
    Enrollment
    |> Ash.Changeset.for_create(:create_enrollment, %{
      event_id: event.id,
      user_id: applicant.id
    })
    |> Ash.create(tenant: workspace.id, actor: applicant)
    |> case do
      {:ok, enrollment} -> enrollment
      {:error, error} -> raise "setup failed: #{inspect(error)}"
    end
  end

  defp uniq, do: String.slice(Ecto.UUID.generate(), 0, 8)
end
