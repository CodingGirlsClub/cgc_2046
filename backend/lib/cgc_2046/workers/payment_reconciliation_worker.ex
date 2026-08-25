defmodule Cgc2046.Workers.PaymentReconciliationWorker do
  @moduledoc """
  缴费对账规⑦（U13/KTD11/R23；先例：`ReconciliationScanWorker` 的 upsert/刷新语义）。

  Oban cron 夜间一拍（config.exs `23 3 * * *`，避开整点渠道尖峰），拉 **T+1**
  两渠道账单（`Provider.fetch_statement(昨天)`）与本地订单比对，五类差异落
  Finding（rule = `:payment_recon`，entity_type = `:payment_order`，唯一键
  (rule, entity_type, entity_id)，detail.kind 区分子类）：

  1. **渠道有我无**（`channel_only`）：账单行的 out_trade_no 在本地不存在或
     已 cancelled（作废单在渠道侧有款 = 异常）；
  2. **我 paid 渠道无**（`local_paid_missing`）：本地当日落账的 paid 单不在
     当日账单（账单是日切片，比对基准 = updated_at 在账单日内的 paid 单）；
  3. **金额不符**（`amount_mismatch`）：账单行与本地单金额不一致（R20 的
     对账面兜底——落账前置校验只覆盖回调路径）；
  4. **pending 超期**（`pending_overdue`）：本地 pending 单过期超过缓冲窗仍
     未流转（U8 扫描每分钟跑，此处是「扫描失效」的兜底，阈值 1 小时）；
  5. **refunding 卡死超期**（`refunding_stuck`）：refunding 超过 24h 未收敛
     （refund worker 查单重试窗 ~16s×5 之上再兜底；管理员 retry_refund 入口）。

  规1/2/3 依赖账单，规4/5 纯本地判定。**账单拉取失败（无权限/未出账）**：
  Logger.error + telemetry，该渠道跳过不抛（KTD11「告警不阻塞」）——本地
  判定规4/5 仍执行，本次报告只覆盖本地面。

  ## 刷新语义（同 ReconciliationScanWorker D2）

  命中 upsert（已存在走 `:refresh` 保 first_seen_at）；本次未命中的行删除
  ——「无差异 → 空报告」由结构保证。账单是日切片：昨天的 `channel_only`
  差异今日不再出现即被删除（正确——渠道侧单日核对窗口关闭）。

  ## 差异处置（v1 全人工）

  Finding 是报告不是自动修复（Assumptions）：/admin/reconciliation 页可见，
  运营按 detail.kind 处置（补单/退款/核对渠道后台）。

  ## 样例文件

  无账单权限环境以 `test/fixtures/statement_samples/` 的两渠道样例 CSV 驱动
  `parse_statement_csv/1` 解析逻辑（adapter 公开面，见各 provider @doc）。
  """

  use Oban.Worker,
    queue: :maintenance,
    max_attempts: 3,
    unique: [period: 300, states: :incomplete]

  require Ash.Query
  require Logger

  alias Cgc2046.Payments.{Order, Provider}
  alias Cgc2046.Reconciliation.Finding

  @rule :payment_recon
  @entity_type :payment_order

  @channels [:wechat, :alipay]

  # 规4：pending 过期缓冲窗（U8 分钟级扫描之上留 1 小时）
  @pending_overdue_buffer_seconds 3_600

  # 规5：refunding 卡死阈值（refund worker 重试窗之上；RISKS 4 的最终兜底）
  @refunding_stuck_hours 24

  # 账单行字段（两渠道 CSV 表头的中文名——parse_statement_csv 产物键）
  @wechat_trade_no_key "商户订单号"
  @wechat_amount_key "订单金额(元)"
  @wechat_status_key "交易状态"
  @alipay_trade_no_key "商户订单号"
  @alipay_amount_key "订单金额"
  @alipay_status_key "订单状态"

  @impl Oban.Worker
  def perform(%Oban.Job{}) do
    now = DateTime.utc_now()

    # T+1：对昨日账单（渠道出账次日可拉）
    bill_date = Date.add(DateTime.to_date(now), -1)

    statement_entries =
      @channels
      |> Enum.flat_map(fn channel ->
        case fetch_channel_statement(channel, bill_date) do
          {:ok, rows} -> normalize_rows(channel, rows)
          :skip -> []
        end
      end)
      |> Map.new(fn entry -> {entry.out_trade_no, entry} end)

    # 本地面：paid/pending/refunding 全量（五类比对基准）+ 当日落账的 paid（规2）
    orders =
      Order
      |> Ash.Query.filter(status in [:paid, :pending, :refunding])
      |> Ash.read!(authorize?: false)

    # 全量单索引（含 cancelled）：channel_only 需区分「本地已作废」与「无本地单」
    local_by_trade_no =
      Order
      |> Ash.read!(authorize?: false)
      |> Map.new(fn o -> {o.out_trade_no, o} end)

    candidates = diff_candidates(statement_entries, orders, local_by_trade_no, bill_date, now)

    upsert_all(candidates)
    delete_stale(candidates)

    :ok
  end

  # ── 账单拉取（失败告警不抛，KTD11）────────────────────────────────────────

  defp fetch_channel_statement(channel, date) do
    # rescue 隔离:adapter/SDK 可能直接 raise(生产实证 2026-08-21~25,alipay
    # query 形状 bug 在签名段 ArgumentError,每日 job 全数 discarded)——单渠道
    # 崩溃只 skip 该渠道,不拖死其余渠道已拉账单的比对与 Finding 落库
    try do
      do_fetch_channel_statement(channel, date)
    rescue
      e ->
        Logger.error(
          "payment recon: #{channel} statement fetch raised for #{Date.to_iso8601(date)}: " <>
            Exception.format(:error, e, __STACKTRACE__)
        )

        :telemetry.execute(
          [:cgc2046, :payment_recon, :statement_fetch_failed],
          %{count: 1},
          %{channel: channel, date: Date.to_iso8601(date), reason: inspect(e)}
        )

        :skip
    end
  end

  defp do_fetch_channel_statement(channel, date) do
    case Provider.for_channel(channel).fetch_statement(date) do
      {:ok, rows} when is_list(rows) ->
        {:ok, rows}

      {:ok, _other} ->
        {:ok, []}

      {:error, reason} ->
        Logger.error(
          "payment recon: #{channel} statement fetch failed for #{Date.to_iso8601(date)}: " <>
            inspect(reason)
        )

        :telemetry.execute(
          [:cgc2046, :payment_recon, :statement_fetch_failed],
          %{count: 1},
          %{channel: channel, date: Date.to_iso8601(date), reason: inspect(reason)}
        )

        :skip
    end
  end

  # ── 行归一：两渠道 CSV 行 → 统一差异比对形状 ──────────────────────────────

  defp normalize_rows(channel, rows) do
    {trade_no_key, amount_key, status_key, to_cents} = channel_fields(channel)

    rows
    |> Enum.flat_map(fn row ->
      with trade_no when is_binary(trade_no) and trade_no != "" <- row[trade_no_key],
           amount when is_binary(amount) <- row[amount_key],
           {cents, ""} <- normalize_amount(amount, to_cents),
           status when is_binary(status) <- row[status_key] do
        [%{out_trade_no: trade_no, amount_cents: cents, channel_status: status}]
      else
        _ -> []
      end
    end)
  end

  defp channel_fields(:wechat) do
    {@wechat_trade_no_key, @wechat_amount_key, @wechat_status_key, :yuan_to_cents}
  end

  defp channel_fields(:alipay) do
    {@alipay_trade_no_key, @alipay_amount_key, @alipay_status_key, :yuan_to_cents}
  end

  # 金额串（元，可能带 ¥ 前缀/千分位）→ 分
  defp normalize_amount(raw, :yuan_to_cents) do
    cleaned = raw |> String.replace("¥", "") |> String.replace(",", "")

    case Float.parse(cleaned) do
      {yuan, rest} -> {round(yuan * 100), rest}
      :error -> {:error, :unparsable}
    end
  end

  # ── 五类差异判定 ──────────────────────────────────────────────────────────

  defp diff_candidates(statement_entries, orders, local_by_trade_no, bill_date, now) do
    # 规1：渠道有我无（本地无此单，或本地已作废——cancelled 单渠道侧有款）
    channel_only =
      Enum.flat_map(statement_entries, fn {out_trade_no, entry} ->
        case local_by_trade_no do
          %{^out_trade_no => order} ->
            if order.status == :cancelled do
              [candidate(order.id, "channel_only", entry, %{})]
            else
              []
            end

          %{} ->
            # 无本地单：entity_id 用 out_trade_no（唯一键可挂靠）
            [candidate(out_trade_no, "channel_only", entry, %{no_local_order: true})]
        end
      end)

    matched_or_local =
      Enum.flat_map(orders, fn order ->
        case Map.fetch(statement_entries, order.out_trade_no) do
          {:ok, entry} ->
            # 规3：金额不符
            if entry.amount_cents == order.amount_cents do
              []
            else
              [
                candidate(order.id, "amount_mismatch", entry, %{
                  local_cents: order.amount_cents
                })
              ]
            end

          :error ->
            # 规2：我 paid 渠道无（限定当日落账——账单是日切片，跨日落账不比对）
            if order.status == :paid and bill_date == DateTime.to_date(order.updated_at) do
              [candidate(order.id, "local_paid_missing", nil, %{status: "paid"})]
            else
              []
            end
        end
      end)

    local_only = pending_overdue(orders, now) ++ refunding_stuck(orders, now)

    dedupe(channel_only ++ matched_or_local ++ local_only)
  end

  defp pending_overdue(orders, now) do
    cutoff = DateTime.add(now, -@pending_overdue_buffer_seconds)

    Enum.flat_map(orders, fn order ->
      if order.status == :pending and DateTime.compare(order.expire_at, cutoff) == :lt do
        [candidate(order.id, "pending_overdue", nil, %{expire_at: order.expire_at})]
      else
        []
      end
    end)
  end

  defp refunding_stuck(orders, now) do
    cutoff = DateTime.add(now, -@refunding_stuck_hours, :hour)

    Enum.flat_map(orders, fn order ->
      if order.status == :refunding and DateTime.compare(order.updated_at, cutoff) == :lt do
        [candidate(order.id, "refunding_stuck", nil, %{since: order.updated_at})]
      else
        []
      end
    end)
  end

  defp candidate(entity_id, kind, entry, extra) do
    detail =
      %{kind: kind}
      |> Map.merge(extra)
      |> Map.merge(
        case entry do
          nil -> %{}
          entry -> %{channel_cents: entry.amount_cents, channel_status: entry.channel_status}
        end
      )

    %{
      entity_type: @entity_type,
      entity_id: entity_id,
      workspace_id: nil,
      detail: detail
    }
  end

  # 同实体多差异（如 amount_mismatch 与 refunding_stuck 同单）：kind 优先级
  # 取首个（本拍差异集合去重，唯一键语义下不重复报告同实体）
  defp dedupe(candidates) do
    candidates
    |> Enum.reverse()
    |> Enum.uniq_by(&{&1.entity_type, &1.entity_id})
    |> Enum.reverse()
  end

  # ── 刷新语义（ReconciliationScanWorker 同款）──────────────────────────────

  defp upsert_all(candidates) do
    Enum.each(candidates, &upsert_finding/1)
  end

  defp upsert_finding(candidate) do
    case existing_finding(candidate.entity_type, candidate.entity_id) do
      nil ->
        Finding
        |> Ash.Changeset.for_create(
          :create,
          Map.merge(
            %{rule: @rule},
            Map.take(candidate, [:entity_type, :entity_id, :workspace_id, :detail])
          )
        )
        |> Ash.create(authorize?: false)
        |> handle_write(candidate)

      finding ->
        finding
        |> Ash.Changeset.for_update(:refresh, %{
          workspace_id: candidate.workspace_id,
          detail: candidate.detail
        })
        |> Ash.update(authorize?: false)
        |> handle_write(candidate)
    end
  end

  defp handle_write(result, candidate) do
    case result do
      {:ok, _} ->
        :ok

      {:error, error} ->
        Logger.warning(
          "payment recon: #{@rule} upsert failed for #{candidate.entity_id}: #{inspect(error)}"
        )

        :ok
    end
  end

  defp existing_finding(entity_type, entity_id) do
    case Finding
         |> Ash.Query.filter(
           rule == ^@rule and entity_type == ^entity_type and entity_id == ^entity_id
         )
         |> Ash.read_one(authorize?: false) do
      {:ok, finding} -> finding
      {:error, _} -> nil
    end
  end

  defp delete_stale(candidates) do
    current = MapSet.new(candidates, fn c -> {c.entity_type, c.entity_id} end)

    Finding
    |> Ash.Query.filter(rule == ^@rule)
    |> Ash.read!(authorize?: false)
    |> Enum.each(fn finding ->
      unless MapSet.member?(current, {finding.entity_type, finding.entity_id}) do
        case Ash.destroy(finding, authorize?: false) do
          :ok ->
            :ok

          {:error, error} ->
            Logger.warning(
              "payment recon: stale delete failed for #{finding.entity_id}: #{inspect(error)}"
            )
        end
      end
    end)
  end
end
