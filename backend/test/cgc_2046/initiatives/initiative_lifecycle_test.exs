defmodule Cgc2046.Initiatives.InitiativeLifecycleTest do
  @moduledoc """
  #628 ① + ②：Initiative 状态机加 `cancelled`，以及 close/cancel 后的三条 guard。

  1. **状态机**：`draft` / `open` 可进 `cancelled`；`closed → cancelled` 拒绝；
     终态（closed / cancelled）无出边、重复迁移拒绝（CAS 语义）。
  2. **guard ①（`:launch` 拦截）**：close / cancel 后挂载场不可再发布——稳定
     code `initiative_not_open`、库中仍 `draft`、**不发 `event.launched` 信号**。
  3. **guard ②（公开页）**：close / cancel 后活动页不再挂出场次（页面仍可直达，
     R5 留档语义）；`cancelled` 进公开列表白名单。
  4. **guard ③（规则传播）**：close / cancel 后规则写面冻结 ⇒ 锁死规则不再传播
     到挂载的非终态场（#587 的 `status IN ('draft','open')` 范围 SQL 一字未改）。
  """

  use Cgc2046.DataCase, async: true
  use Oban.Testing, repo: Cgc2046.Repo

  require Ash.Query

  alias Cgc2046.AccountsFixtures, as: F
  alias Cgc2046.Errors.BusinessError
  alias Cgc2046.Events.Event
  alias Cgc2046.EventsFixtures, as: EF
  alias Cgc2046.Initiatives.{Initiative, InitiativeRule, Public}
  alias Cgc2046.Workflows.SignalPublishWorker

  setup do
    admin = F.platform_admin("initiative-lifecycle")

    %{admin: admin, workspace: F.create_workspace(admin)}
  end

  # ── ① 状态机 ─────────────────────────────────────────────────────────────

  test "draft 与 open 都可进 cancelled；终态无出边、重复迁移拒绝", %{admin: admin} do
    draft = create_initiative(admin, "lc-draft")

    assert {:ok, cancelled} = cancel(draft, admin)
    assert cancelled.status == :cancelled
    # 落库真值（不只信返回值）
    assert status_of(draft.id) == :cancelled

    assert {:error, _} = draft |> Ash.Changeset.for_update(:open, %{}) |> Ash.update(actor: admin)

    assert {:error, _} =
             draft |> Ash.Changeset.for_update(:close, %{}) |> Ash.update(actor: admin)

    assert {:error, _} = cancel(draft, admin)
    assert status_of(draft.id) == :cancelled

    opened = open_initiative(admin, "lc-open")

    assert {:ok, cancelled_open} = cancel(opened, admin)
    assert cancelled_open.status == :cancelled
    assert status_of(opened.id) == :cancelled
  end

  test "closed 不可再中止（收尾后无出边）", %{admin: admin} do
    closed = admin |> open_initiative("lc-closed") |> close!(admin)

    assert {:error, _} = cancel(closed, admin)

    assert {:error, _} =
             closed |> Ash.Changeset.for_update(:close, %{}) |> Ash.update(actor: admin)

    assert status_of(closed.id) == :closed
  end

  # ── ② guard ①：launch 拦截 ───────────────────────────────────────────────

  test "guard①：open 时挂载场可发布（正向对照）", %{admin: admin, workspace: workspace} do
    initiative = open_initiative(admin, "guard-launch-positive")
    event = draft_mounted(workspace, admin, initiative)

    assert {:ok, launched} = launch(event, workspace, admin)
    assert launched.status == :open

    assert Enum.any?(
             all_enqueued(worker: SignalPublishWorker),
             &(&1.args["signal_type"] == "event.launched")
           )
  end

  test "guard①：close 后挂载场不可再发布（initiative_not_open + 仍 draft + 无信号）", %{
    admin: admin,
    workspace: workspace
  } do
    initiative = open_initiative(admin, "guard-launch-close")
    event = draft_mounted(workspace, admin, initiative)
    _ = close!(initiative, admin)

    assert {:error, %Ash.Error.Invalid{errors: errors}} = launch(event, workspace, admin)

    assert Enum.any?(errors, &match?(%BusinessError{code: "initiative_not_open"}, &1))

    assert event_status(event.id) == :draft
    assert launched_signals(event.id) == []
  end

  test "guard①：cancel 后挂载场不可再发布", %{admin: admin, workspace: workspace} do
    initiative = open_initiative(admin, "guard-launch-cancel")
    event = draft_mounted(workspace, admin, initiative)
    assert {:ok, _} = cancel(initiative, admin)

    assert {:error, %Ash.Error.Invalid{errors: errors}} = launch(event, workspace, admin)

    assert Enum.any?(errors, &match?(%BusinessError{code: "initiative_not_open"}, &1))
    assert event_status(event.id) == :draft
    assert launched_signals(event.id) == []
  end

  test "guard①：未挂载场不受影响（无 Initiative 即放行）", %{admin: admin, workspace: workspace} do
    event = draft_event(workspace, admin)

    assert {:ok, launched} = launch(event, workspace, admin)
    assert launched.status == :open
  end

  # ── ② guard ②：公开页可见性 ─────────────────────────────────────────────

  test "guard②：close 后活动页不再挂出场次（页面仍可直达 + 文案态可读）", %{
    admin: admin,
    workspace: workspace
  } do
    initiative = open_initiative(admin, "guard-public-close")

    event =
      EF.create_event(workspace, admin, %{initiative_id: initiative.id, visibility: :public})

    assert {:ok, %{cities: [_ | _], event_count: 1, status: "open"}} =
             Public.get_by_slug(initiative.slug)

    _ = close!(initiative, admin)

    assert {:ok, %{cities: [], event_count: 0, status: "closed", id: id}} =
             Public.get_by_slug(initiative.slug)

    assert id == initiative.id
    # 不触发任何写入：场次状态与账本缓存原样
    assert event_status(event.id) == :open
  end

  test "guard②：cancel 后活动页不再挂出场次，且 cancelled 进公开列表", %{
    admin: admin,
    workspace: workspace
  } do
    initiative = open_initiative(admin, "guard-public-cancel")

    _event =
      EF.create_event(workspace, admin, %{initiative_id: initiative.id, visibility: :public})

    assert {:ok, _} = cancel(initiative, admin)

    assert {:ok, %{cities: [], event_count: 0, status: "cancelled"}} =
             Public.get_by_slug(initiative.slug)

    assert {:ok, cards} = Public.list()
    assert Enum.any?(cards, &(&1.slug == initiative.slug and &1.status == "cancelled"))
  end

  test "guard②：draft 活动仍 not_found（白名单未放宽到草稿）", %{admin: admin} do
    draft = create_initiative(admin, "guard-public-draft")

    assert {:error, :not_found} = Public.get_by_slug(draft.slug)
  end

  # ── ② guard ③：规则传播 ─────────────────────────────────────────────────

  test "guard③：close 后规则写面冻结，锁死规则不再传播到挂载的 draft 场", %{
    admin: admin,
    workspace: workspace
  } do
    initiative =
      open_initiative(admin, "guard-rule-close", %{min_participants: {%{count: 8}, true}})

    event = draft_mounted(workspace, admin, initiative)
    assert reload(event).min_participants == 8

    # 正向对照：open 状态下同一写入会传播（证明本用例能捕获回归）
    assert {:ok, _} = update_rule(initiative, :min_participants, %{value: %{count: 9}}, admin)
    assert reload(event).min_participants == 9

    _ = close!(initiative, admin)

    assert {:error, %Ash.Error.Invalid{}} =
             update_rule(initiative, :min_participants, %{value: %{count: 3}}, admin)

    # 场次字段与规则行都未被改写
    assert reload(event).min_participants == 9
    assert rule_value(initiative, :min_participants, admin) == %{"count" => 9}
  end

  test "guard③：cancel 后规则写面同样冻结", %{admin: admin, workspace: workspace} do
    initiative =
      open_initiative(admin, "guard-rule-cancel", %{min_participants: {%{count: 8}, true}})

    event = draft_mounted(workspace, admin, initiative)
    assert {:ok, _} = cancel(initiative, admin)

    assert {:error, %Ash.Error.Invalid{}} =
             update_rule(initiative, :min_participants, %{value: %{count: 3}}, admin)

    assert reload(event).min_participants == 8
    assert rule_value(initiative, :min_participants, admin) == %{"count" => 8}
  end

  # ── helpers ─────────────────────────────────────────────────────────────

  defp create_initiative(admin, slug) do
    Initiative
    |> Ash.Changeset.for_create(:create, %{name: "生命周期 #{slug}", slug: slug, created_by: admin.id})
    |> Ash.create!(actor: admin)
  end

  defp open_initiative(admin, slug, rule_overrides \\ %{}) do
    initiative = create_initiative(admin, slug)

    for {key, {value, locked}} <- Map.merge(default_rules(), rule_overrides) do
      InitiativeRule
      |> Ash.Changeset.for_create(:create, %{
        initiative_id: initiative.id,
        key: key,
        value: value,
        locked: locked
      })
      |> Ash.create!(actor: admin)
    end

    initiative |> Ash.Changeset.for_update(:open, %{}) |> Ash.update!(actor: admin)
  end

  defp default_rules do
    %{
      deposit: {%{enabled: false}, false},
      age_gate: {%{min_age: 18}, false},
      min_participants: {%{count: 8}, false},
      deadline_rule: {%{hours_before_start: 72}, false}
    }
  end

  # 挂载中的 draft 场（挂载要求 Event 处于 draft；create 后不 launch）
  defp draft_mounted(workspace, admin, initiative) do
    draft_event(workspace, admin, %{initiative_id: initiative.id})
  end

  defp draft_event(workspace, admin, attrs \\ %{}) do
    defaults = %{
      title: "挂载草稿场",
      enrollment_policy: :open,
      starts_at: EF.days_from_now(10),
      ends_at: EF.days_from_now(11)
    }

    Event
    |> Ash.Changeset.for_create(:create, Map.merge(defaults, attrs), tenant: workspace.id)
    |> Ash.create!(tenant: workspace.id, actor: admin)
  end

  defp launch(event, workspace, admin) do
    event
    |> Ash.Changeset.for_update(:launch, %{}, tenant: workspace.id)
    |> Ash.update(tenant: workspace.id, actor: admin)
  end

  defp close!(initiative, admin) do
    {:ok, closed} =
      initiative |> Ash.Changeset.for_update(:close, %{}) |> Ash.update(actor: admin)

    closed
  end

  defp cancel(initiative, admin) do
    initiative |> Ash.Changeset.for_update(:cancel, %{}) |> Ash.update(actor: admin)
  end

  defp update_rule(initiative, key, attrs, admin) do
    initiative
    |> rule(key, admin)
    |> Ash.Changeset.for_update(:update, attrs)
    |> Ash.update(actor: admin)
  end

  defp rule(initiative, key, admin) do
    InitiativeRule
    |> Ash.Query.filter(initiative_id == ^initiative.id and key == ^key)
    |> Ash.read_one!(actor: admin)
  end

  defp rule_value(initiative, key, admin), do: rule(initiative, key, admin).value

  defp status_of(id), do: Ash.get!(Initiative, id, authorize?: false).status
  defp event_status(id), do: Ash.get!(Event, id, authorize?: false).status

  defp reload(event), do: Ash.get!(Event, event.id, authorize?: false)

  # 按 event_id 收窄：共享 test 库的历史遗留 job 会污染 worker-only 断言
  defp launched_signals(event_id) do
    Enum.filter(
      all_enqueued(worker: SignalPublishWorker),
      &(&1.args["signal_type"] == "event.launched" and
          &1.args["data"]["event_id"] == event_id)
    )
  end
end
