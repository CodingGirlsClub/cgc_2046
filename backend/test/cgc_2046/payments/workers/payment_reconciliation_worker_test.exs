defmodule Cgc2046.Payments.Workers.PaymentReconciliationWorkerTest do
  @moduledoc """
  U13：缴费对账规⑦（KTD11/R23）。

  - 五类差异各自命中（channel_only / local_paid_missing / amount_mismatch /
    pending_overdue / refunding_stuck）。
  - 无差异 → 空报告（未命中删除：预置旧 finding 被清）。
  - 两渠道样例文件解析（parse_statement_csv 公开面，字段提取）。
  - 拉取失败：告警 telemetry + 不抛（本地判定仍执行）。
  """

  use Cgc2046.DataCase, async: false
  use Oban.Testing, repo: Cgc2046.Repo

  alias Cgc2046.Payments.Order
  alias Cgc2046.Payments.Providers.{Alipay, Fake, WechatPay}
  alias Cgc2046.Reconciliation.Finding
  alias Cgc2046.Payments.Workers.PaymentReconciliationWorker

  @tier_id "88888888-8888-8888-8888-888888888888"
  @tier %{"id" => @tier_id, "name" => "标准", "amount_cents" => 19_900}

  @samples_dir "test/fixtures/statement_samples"

  describe "样例文件解析（两渠道格式）" do
    test "微信：反引号分隔表头 zip，汇总行剔除，金额/状态/单号字段提取" do
      rows =
        (@samples_dir <> "/wechat_trade_bill.csv")
        |> File.read!()
        |> WechatPay.parse_statement_csv()

      assert [%{} = jsapi, %{} = native, %{} = refund_row] = rows

      assert jsapi["商户订单号"] == "CGC3f2a...01"
      assert jsapi["订单金额(元)"] == "199.00"
      assert jsapi["交易状态"] == "SUCCESS"
      assert native["商户订单号"] == "CGC7b4c...02"
      assert refund_row["交易状态"] == "REFUND"
      # 汇总行（总开头）不出现在数据行
      refute Enum.any?(rows, &(Map.get(&1, "总交易单数") != nil))
    end

    test "支付宝：# 明细头剔除，逗号分隔表头 zip，字段提取" do
      rows =
        (@samples_dir <> "/alipay_bill_detail.csv")
        |> File.read!()
        |> Alipay.parse_statement_csv()

      assert length(rows) == 3

      assert [%{first: _} | _] = [%{first: hd(rows)} | []]

      first = hd(rows)
      assert first["商户订单号"] == "CGC5e6f...11"
      assert first["订单金额"] == "199.00"
      assert first["交易状态"] == "TRADE_SUCCESS"

      refute Enum.any?(rows, &String.starts_with?(Map.get(&1, "支付宝交易号", ""), "#"))
    end
  end

  describe "perform/1 五类差异" do
    test "各自命中：channel_only / amount_mismatch / local_paid_missing / pending_overdue / refunding_stuck" do
      base = setup_workspace()

      # 本地三单与账单的比对矩阵：
      # - paid 匹配金额（无差异基准）
      # - paid 金额不符 → amount_mismatch
      # - paid 当日落账但账单无 → local_paid_missing
      # - cancelled 但渠道有款 → channel_only
      # - 账单独有（本地无单）→ channel_only
      matched = insert_order(base, :paid, 19_900)
      mismatched = insert_order(base, :paid, 29_900)
      missing_in_channel = insert_order(base, :paid, 19_900, updated_now: true)
      cancelled_with_channel = insert_order(base, :cancelled, 19_900)

      # pending 超期（expire_at 已过 2h）
      pending_stuck = insert_order(base, :pending, 19_900, expire_offset: -7_200)
      # refunding 卡死（updated_at 已 25h 前）
      refunding_stuck = insert_order(base, :refunding, 19_900, updated_offset: -25 * 3_600)

      statement =
        statement_for([
          {matched.out_trade_no, 19_900},
          {mismatched.out_trade_no, 19_900},
          {cancelled_with_channel.out_trade_no, 19_900},
          {"CGC-unknown-999", 19_900}
        ])

      Fake.script!(fetch_statement: {:ok, statement_rows(statement)})

      assert :ok = perform_job(PaymentReconciliationWorker, %{})

      findings =
        Ash.read!(Finding, authorize?: false) |> Enum.filter(&(&1.rule == :payment_recon))

      kinds = Map.new(findings, &{&1.entity_id, &1.detail["kind"]})

      assert kinds[mismatched.id] == "amount_mismatch"
      assert kinds[missing_in_channel.id] == "local_paid_missing"
      assert kinds[cancelled_with_channel.id] == "channel_only"
      assert kinds["CGC-unknown-999"] == "channel_only"
      assert kinds[pending_stuck.id] == "pending_overdue"
      assert kinds[refunding_stuck.id] == "refunding_stuck"

      # 匹配单无 finding
      refute Map.has_key?(kinds, matched.id)

      # 差异上下文（排查面）
      mismatch_finding = Enum.find(findings, &(&1.entity_id == mismatched.id))

      assert mismatch_finding.detail["channel_cents"] == 19_900
      assert mismatch_finding.detail["local_cents"] == 29_900
    after
      Fake.reset!()
    end

    test "无差异 → 空报告（预置旧 finding 未命中删除）" do
      base = setup_workspace()
      healthy = insert_order(base, :paid, 19_900)

      # 预置一条昨日差异（今日不再命中 → 删除）
      insert_finding("stale-order-id", %{"kind" => "channel_only"})

      Fake.script!(
        fetch_statement: {:ok, statement_rows(statement_for([{healthy.out_trade_no, 19_900}]))}
      )

      assert :ok = perform_job(PaymentReconciliationWorker, %{})

      findings =
        Ash.read!(Finding, authorize?: false) |> Enum.filter(&(&1.rule == :payment_recon))

      assert findings == []
    after
      Fake.reset!()
    end

    test "拉取失败：告警 telemetry + 不抛；本地判定（pending 超期）仍执行" do
      base = setup_workspace()
      stuck = insert_order(base, :pending, 19_900, expire_offset: -7_200)

      handler_id = "recon-alert-#{System.unique_integer([:positive])}"

      :ok =
        :telemetry.attach(
          handler_id,
          [:cgc2046, :payment_recon, :statement_fetch_failed],
          fn _event, _measurements, meta, _config -> send(self(), {:recon_alert, meta}) end,
          nil
        )

      Fake.script!(fetch_statement: {:error, :bill_not_ready})

      assert :ok = perform_job(PaymentReconciliationWorker, %{})

      # 两渠道各一条告警事件
      events =
        for _ <- 1..2 do
          receive do
            {:recon_alert, meta} -> meta
          after
            1_000 -> flunk("telemetry event not received")
          end
        end

      :ok = :telemetry.detach(handler_id)

      assert Enum.sort(Enum.map(events, & &1.channel)) == [:alipay, :wechat]

      Fake.reset!()
    end

    test "SDK raise 隔离（生产实证 2026-08-21~25）：单渠道崩溃不拖死 job,其余渠道照常比对" do
      base = setup_workspace()
      stuck = insert_order(base, :pending, 19_900, expire_offset: -7_200)

      handler_id = "recon-raise-#{System.unique_integer([:positive])}"

      :ok =
        :telemetry.attach(
          handler_id,
          [:cgc2046, :payment_recon, :statement_fetch_failed],
          fn _event, _measurements, meta, _config -> send(self(), {:recon_alert, meta}) end,
          nil
        )

      # 两渠道 script 同 raise(旧形状下整个 job 崩 → discarded)
      Fake.script!(fetch_statement: :raise)

      # rescue 隔离:job 完成,不抛
      assert :ok = perform_job(PaymentReconciliationWorker, %{})

      # 两渠道各一条告警(reason 带异常摘要)
      events =
        for _ <- 1..2 do
          receive do
            {:recon_alert, meta} -> meta
          after
            1_000 -> flunk("telemetry event not received")
          end
        end

      :ok = :telemetry.detach(handler_id)

      assert Enum.sort(Enum.map(events, & &1.channel)) == [:alipay, :wechat]
      assert Enum.all?(events, &String.contains?(&1.reason, "ArgumentError"))

      # 本地判定不受渠道崩溃影响:pending 超期照常落 Finding
      findings =
        Ash.read!(Finding, authorize?: false) |> Enum.filter(&(&1.rule == :payment_recon))

      assert Enum.any?(
               findings,
               &(&1.entity_id == stuck.id and &1.detail["kind"] == "pending_overdue")
             )
    after
      Fake.reset!()
    end
  end

  # ── 布置 ──

  defp setup_workspace do
    admin = Cgc2046.AccountsFixtures.platform_admin("recon-admin-" <> uniq())
    workspace = Cgc2046.AccountsFixtures.create_workspace(admin)
    # creator 是 platform_admin 非 Owner——显式入座 owner 才可建收费 Event
    Cgc2046.AccountsFixtures.add_member(workspace, admin, [:owner])
    %{workspace: workspace, creator: admin}
  end

  defp insert_order(base, status, amount_cents, opts \\ []) do
    expire_at =
      DateTime.add(
        DateTime.utc_now(),
        Keyword.get(opts, :expire_offset, 2 * 3_600),
        :second
      )

    {:ok, order} =
      Order
      |> Ash.Changeset.for_create(:create, %{
        enrollment_id: enroll(base).id,
        provider: :wechat_native,
        out_trade_no:
          "CGC" <> (Ecto.UUID.generate() |> String.replace("-", "") |> String.slice(0, 20)),
        amount_cents: amount_cents,
        tier_snapshot: @tier,
        expire_at: expire_at
      })
      |> Ash.create(tenant: base.workspace.id, authorize?: false)

    order = %{order | status: status}

    # 直接 SQL 落期望状态与时间戳（测试布置,非被测行为;worker 读 updated_at 判定窗口）
    updated_at =
      case Keyword.get(opts, :updated_offset) do
        nil -> DateTime.utc_now()
        offset -> DateTime.add(DateTime.utc_now(), offset, :second)
      end

    {:ok, _} =
      Cgc2046.Repo.query(
        "UPDATE payments_orders SET status = $1, updated_at = $2 WHERE id = $3",
        [Atom.to_string(status), updated_at, Ecto.UUID.dump!(order.id)]
      )

    # local_paid_missing 用：updated_at 保留当日（bill_date = 昨天 → 需把 updated_at
    # 落在昨天 = 当日落账账单日）
    if opts[:updated_now] do
      {:ok, _} =
        Cgc2046.Repo.query(
          "UPDATE payments_orders SET updated_at = NOW() - INTERVAL '1 day' WHERE id = $1",
          [Ecto.UUID.dump!(order.id)]
        )
    end

    order
  end

  defp enroll(base) do
    event =
      Cgc2046.EventsFixtures.create_event(
        base.workspace,
        base.creator,
        %{
          pricing_enabled: true,
          price_tiers: [@tier]
        }
      )

    learner = Cgc2046.AccountsFixtures.register_user("recon-l-" <> uniq())

    {:ok, enrollment} =
      Cgc2046.Admission.Enrollment
      |> Ash.Changeset.for_create(:create_enrollment, %{
        event_id: event.id,
        user_id: learner.id,
        tier_id: @tier_id
      })
      |> Ash.create(tenant: base.workspace.id, actor: learner)

    enrollment
  end

  defp insert_finding(entity_id, detail) do
    Finding
    |> Ash.Changeset.for_create(:create, %{
      rule: :payment_recon,
      entity_type: :payment_order,
      entity_id: entity_id,
      workspace_id: nil,
      detail: detail
    })
    |> Ash.create!(authorize?: false)
  end

  # Fake.fetch_statement 返回的行形状（adapter parse_statement_csv 产物形状:
  # %{"商户订单号" => ..., "订单金额(元)" => ..., "交易状态" => ...}）
  defp statement_rows(entries) do
    Enum.map(entries, fn {out_trade_no, cents} ->
      %{
        "商户订单号" => out_trade_no,
        "订单金额(元)" => format_yuan(cents),
        "交易状态" => "SUCCESS"
      }
    end)
  end

  defp statement_for(entries), do: entries

  defp format_yuan(cents), do: :erlang.float_to_binary(cents / 100, decimals: 2)

  defp uniq, do: String.slice(Ecto.UUID.generate(), 0, 8)
end
