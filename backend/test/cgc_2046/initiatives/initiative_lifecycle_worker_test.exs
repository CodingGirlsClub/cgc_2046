defmodule Cgc2046.Initiatives.InitiativeLifecycleWorkerTest do
  @moduledoc """
  #628 ③ 到点收尾扫描：`window_ends_at` 过点的 open Initiative → closed。

  幂等判据 = 域 action 的 CAS（`Initiative :close` 的行锁 + 写前态判定）：重复
  执行不产生第二个副作用（无第二条审计行、无第二次状态写入，`updated_at` 不变）。

  `window_ends_at` 为空 = 永不自动收尾（跳过，worker 每拍记 debug 计数）。
  """

  use Cgc2046.DataCase, async: true
  use Oban.Testing, repo: Cgc2046.Repo

  alias Cgc2046.Accounts.AdminActionLog
  alias Cgc2046.AccountsFixtures, as: F
  alias Cgc2046.Initiatives.{Initiative, InitiativeLifecycleWorker, InitiativeRule}

  setup do
    admin = F.platform_admin("initiative-lifecycle-worker")

    %{admin: admin}
  end

  test "window_ends_at 过点的 open 活动被收尾；未过点 / 空窗口 / draft 不动", %{admin: admin} do
    overdue = open_initiative(admin, "worker-overdue", days_ago(1))
    future = open_initiative(admin, "worker-future", days_from_now(1))
    no_window = open_initiative(admin, "worker-no-window", nil)
    draft = draft_initiative(admin, "worker-draft", days_ago(1))

    assert :ok = perform_job(InitiativeLifecycleWorker, %{})

    assert status_of(overdue.id) == :closed
    assert status_of(future.id) == :open
    assert status_of(no_window.id) == :open
    assert status_of(draft.id) == :draft
  end

  test "收尾走 :close 口径：不级联、不发 event.ended（收尾不退款）", %{admin: admin} do
    initiative = open_initiative(admin, "worker-no-cascade", days_ago(1))

    assert :ok = perform_job(InitiativeLifecycleWorker, %{})

    assert status_of(initiative.id) == :closed
    # 判据按 args 收窄：共享 test 库里可能有历史遗留 job（跨 run 的 committed
    # oban_jobs 行），worker-only 断言会被污染（同 rule_propagation_test 的
    # capacity_changed_jobs/0 口径）。
    refute Enum.any?(
             all_enqueued(worker: Cgc2046.Initiatives.CancelCascadeWorker),
             &(&1.args["initiative_id"] == initiative.id)
           )

    refute Enum.any?(
             all_enqueued(worker: Cgc2046.Workflows.SignalPublishWorker),
             &(&1.args["signal_type"] == "event.ended")
           )

    # 治理审计：系统驱动无 actor（cron 收尾与人工 close 可区分）
    assert [%{action: :initiative_close, actor_id: nil}] =
             AdminActionLog
             |> Ash.read!(authorize?: false)
             |> Enum.filter(&(&1.action == :initiative_close and &1.target_id == initiative.id))
  end

  test "幂等：重复执行不重复副作用（CAS 断言 + 第二拍零写入）", %{admin: admin} do
    initiative = open_initiative(admin, "worker-idempotent", days_ago(1))

    assert :ok = perform_job(InitiativeLifecycleWorker, %{})
    assert status_of(initiative.id) == :closed

    closed_row = Ash.get!(Initiative, initiative.id, authorize?: false)

    # 第二拍：扫描条件 `status == :open` 已排除 ⇒ 零动作
    assert :ok = perform_job(InitiativeLifecycleWorker, %{})

    assert Ash.get!(Initiative, initiative.id, authorize?: false).updated_at ==
             closed_row.updated_at

    # 直投 CAS 再证：重复 close 被状态门拒绝（同 Event 的 StatusTransition 语义）
    assert {:error, _} =
             initiative
             |> Ash.Changeset.for_update(:close, %{})
             |> Ash.update(authorize?: false)

    assert [_single] =
             AdminActionLog
             |> Ash.read!(authorize?: false)
             |> Enum.filter(&(&1.action == :initiative_close and &1.target_id == initiative.id))
  end

  test "已 cancel 的活动不被到点扫描改写（终态不可逆）", %{admin: admin} do
    initiative = open_initiative(admin, "worker-cancelled", days_ago(1))

    assert {:ok, _} =
             initiative |> Ash.Changeset.for_update(:cancel, %{}) |> Ash.update(actor: admin)

    assert :ok = perform_job(InitiativeLifecycleWorker, %{})

    assert status_of(initiative.id) == :cancelled
  end

  # ── helpers ─────────────────────────────────────────────────────────────

  defp days_ago(days), do: DateTime.add(DateTime.utc_now(), -days, :day)
  defp days_from_now(days), do: DateTime.add(DateTime.utc_now(), days, :day)

  defp draft_initiative(admin, slug, window_ends_at) do
    Initiative
    |> Ash.Changeset.for_create(:create, %{
      name: "Worker #{slug}",
      slug: slug,
      created_by: admin.id,
      window_ends_at: window_ends_at
    })
    |> Ash.create!(actor: admin)
  end

  defp open_initiative(admin, slug, window_ends_at) do
    initiative = draft_initiative(admin, slug, window_ends_at)

    for {key, value} <- default_rules() do
      InitiativeRule
      |> Ash.Changeset.for_create(:create, %{
        initiative_id: initiative.id,
        key: key,
        value: value,
        locked: false
      })
      |> Ash.create!(actor: admin)
    end

    initiative |> Ash.Changeset.for_update(:open, %{}) |> Ash.update!(actor: admin)
  end

  defp default_rules do
    %{
      deposit: %{enabled: false},
      age_gate: %{min_age: 18},
      min_participants: %{count: 8},
      deadline_rule: %{hours_before_start: 72}
    }
  end

  defp status_of(id), do: Ash.get!(Initiative, id, authorize?: false).status
end
