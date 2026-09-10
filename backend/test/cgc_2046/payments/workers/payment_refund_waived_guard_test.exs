defmodule Cgc2046.Payments.Workers.PaymentRefundWaivedGuardTest do
  @moduledoc """
  015：退款收尾免缴判定的 fail-closed 守卫。

  `PaymentRefundWorker.waived?/1` 读 AdminActionLog 失败必须上抛
  （`{:error, reason}`）而非折叠为 false——false 会把免缴学员的已确认报名
  错误取消 + 名额释放（不可逆；settlement worker 同名函数本就 fail-closed）。

  注入手段 = 沙箱事务内改名 `admin_action_logs`（DDL 事务性，测试结束回滚；
  本文件 async: false 串行执行，避免与并行测试争该表锁）。恢复后经 `:refunded`
  状态门重入收敛，并验证免缴语义本体：钱退、报名保持 confirmed。
  """

  use Cgc2046.DataCase, async: false
  use Oban.Testing, repo: Cgc2046.Repo

  alias Cgc2046.AccountsFixtures, as: Fixtures
  alias Cgc2046.Admission.Enrollment
  alias Cgc2046.EventsFixtures, as: EventFixtures
  alias Cgc2046.Payments.Order
  alias Cgc2046.Payments.Workers.PaymentRefundWorker

  @tier_id "77777777-7777-7777-7777-777777777777"

  test "waived? 读失败 → {:error} 不取消免缴报名；恢复后重入按免缴语义保留 confirmed" do
    admin = Fixtures.platform_admin("waive-guard-admin")
    workspace = Fixtures.create_workspace(admin)

    event =
      EventFixtures.create_event(workspace, admin, %{
        pricing_enabled: true,
        price_tiers: [%{"id" => @tier_id, "name" => "标准", "amount_cents" => 19_900}]
      })

    learner = Fixtures.register_user("waive-guard-learner")

    {:ok, enrollment} =
      Enrollment
      |> Ash.Changeset.for_create(:create_enrollment, %{
        event_id: event.id,
        user_id: learner.id,
        tier_id: @tier_id
      })
      |> Ash.create(tenant: workspace.id, actor: learner)

    {:ok, order} =
      Order
      |> Ash.Changeset.for_create(:create, %{
        enrollment_id: enrollment.id,
        provider: :wechat_native,
        out_trade_no: "oto-" <> Ecto.UUID.generate(),
        amount_cents: 19_900,
        tier_snapshot: %{"id" => @tier_id, "name" => "标准", "amount_cents" => 19_900},
        expire_at: DateTime.add(DateTime.utc_now(), 2, :hour)
      })
      |> Ash.create(tenant: workspace.id, authorize?: false)

    # 布置：paid + confirmed（占位确认态）
    {:ok, _} =
      order
      |> Ash.Changeset.for_update(:mark_paid, %{transaction_id: "waive-guard-txn"})
      |> Ash.update(tenant: workspace.id, authorize?: false)

    {:ok, _} =
      Ash.get!(Enrollment, enrollment.id, authorize?: false)
      |> Ash.Changeset.for_update(:settle_paid, %{})
      |> Ash.update(tenant: workspace.id, authorize?: false)

    # 免缴审计行（waived? 的判定事实源；真实写入在 waive_payment action，
    # 此处等效布置——审计行存在 ⇔ 免缴先落，KTD4）
    {:ok, _} =
      Cgc2046.Repo.query(
        "INSERT INTO admin_action_logs " <>
          "(id, action, target_type, target_id, result, metadata, inserted_at) " <>
          "VALUES (gen_random_uuid(), 'waive_payment', 'enrollment', $1, 'success', '{}'::jsonb, NOW())",
        [Cgc2046.Repo.uuid!(enrollment.id)]
      )

    # 订单推到 refunded（报名收尾窗口：confirmed 未处理——F-B 同款布置）
    {:ok, refunding} =
      order
      |> Ash.Changeset.for_update(:start_refund, %{})
      |> Ash.update(tenant: workspace.id, authorize?: false)

    {:ok, _} =
      refunding
      |> Ash.Changeset.for_update(:refund_succeeded, %{})
      |> Ash.update(tenant: workspace.id, authorize?: false)

    # 注入：waived? 的读失败（改名表；沙箱事务内 DDL，测试结束自动回滚）
    Cgc2046.Repo.query!("ALTER TABLE admin_action_logs RENAME TO admin_action_logs_blocked")

    assert {:error, _read_failure} =
             perform_job(PaymentRefundWorker, %{"order_id" => order.id})

    # 守卫生效：读失败绝不折叠为 false——免缴报名未被错误取消
    assert Ash.get!(Enrollment, enrollment.id, authorize?: false).status == :confirmed

    # 解除 → 重试经 :refunded 状态门收敛：免缴语义本体 = 钱退、报名保持 confirmed
    Cgc2046.Repo.query!("ALTER TABLE admin_action_logs_blocked RENAME TO admin_action_logs")

    assert :ok = perform_job(PaymentRefundWorker, %{"order_id" => order.id})

    assert Ash.get!(Enrollment, enrollment.id, authorize?: false).status == :confirmed

    assert Ash.get!(Order, order.id, tenant: workspace.id, authorize?: false).status == :refunded
  end
end
