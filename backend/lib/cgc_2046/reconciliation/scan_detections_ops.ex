defmodule Cgc2046.Reconciliation.ScanDetectionsOps do
  # 对账扫描检测函数库（#852 C9 拆分，账本/运营告警窗域，规8-13+15）。
  # 与 ScanDetections 同为 ReconciliationScanWorker 的检测库：全部经 Repo
  # 裸 SQL 直查业务表（账本写路径同口径先例），candidates 交
  # Finding.apply_rule/3（D2 刷新语义单源）。
  # 规则语义清单见 ReconciliationScanWorker.rules/0 与 Finding moduledoc。

  alias Cgc2046.Repo

  # 规10 漂移宽限：R17「超 N 拍」与 cron 周期（10 分钟一拍）对齐取一拍——
  # 异步信号在途（capacity.synced / 缓存覆盖写）属正常窗口，账本最近变更
  # 早于一个周期仍漂移才告警。规12 不用本常量（无宽限，见 detect_ledger_cache_drift 注释）
  @drift_grace_seconds 600

  @fund_burst_actions [:order_refund, :order_refund_retry, :waive_payment]
  @fund_burst_default_window_seconds 3600
  @fund_burst_default_threshold 5

  @notification_failed_window_seconds 86_400

  # ── 规8-12：名额账本 / 展示投影 / 缓存漂移（ADR-0009 PR⑤ U7；R17；KD2；Fable 5 HIGH-1）
  #
  # 五条均经 Repo 直查（账本写路径全裸 SQL 不经 Ash action，对账读同口径；
  # 规3/6 的 oban_jobs 包读先例）。entity_type 复用 :event/:course，/admin
  # 对账页按既有投影实体链接渲染。Repo.query 返回的 uuid 列为 16 字节
  # 原始二进制，落 Finding 前一律 Ecto.UUID.load! 转字符串（Oban JSON 载荷同限）。

  # 规8：open offering 无账本行（launched 信号建行 + 报名懒建双路均未到达）。
  # 信号在途窗口（秒级）命中的瞬时 finding 下一拍自消（刷新语义兜底）。
  def detect_open_offering_without_ledger do
    {:ok, %{rows: rows}} =
      Repo.query("""
      SELECT 'event' AS kind, e.id, e.workspace_id, e.title
      FROM events e
      WHERE e.status = 'open'
        AND NOT EXISTS (
          SELECT 1 FROM admission_capacity_ledgers l
          WHERE l.offering_kind = 'event' AND l.offering_id = e.id
        )
      UNION ALL
      SELECT 'course', c.id, c.workspace_id, c.title
      FROM courses c
      WHERE c.status = 'open'
        AND NOT EXISTS (
          SELECT 1 FROM admission_capacity_ledgers l
          WHERE l.offering_kind = 'course' AND l.offering_id = c.id
        )
      """)

    Enum.map(rows, fn [kind, offering_id, workspace_id, title] ->
      %{
        entity_type: String.to_atom(kind),
        entity_id: Ecto.UUID.load!(offering_id),
        workspace_id: Ecto.UUID.load!(workspace_id),
        detail: %{title: title}
      }
    end)
  end

  # 规9：账本 occupancy ≠ 占位报名计数（占位态 = confirmed + payment_pending，
  # 与 Enrollment 占位/释放路径口径一致：payment_pending 已占位待付）。
  def detect_ledger_occupancy_mismatch do
    {:ok, %{rows: rows}} =
      Repo.query("""
      WITH occupying AS (
        SELECT 'event' AS kind, event_id AS offering_id, COUNT(*)::bigint AS n
        FROM enrollments
        WHERE status IN ('confirmed', 'payment_pending') AND event_id IS NOT NULL
        GROUP BY event_id
        UNION ALL
        SELECT 'course', course_id, COUNT(*)::bigint
        FROM enrollments
        WHERE status IN ('confirmed', 'payment_pending') AND course_id IS NOT NULL
        GROUP BY course_id
      )
      SELECT l.offering_kind, l.offering_id, l.workspace_id, l.occupancy,
             COALESCE(o.n, 0) AS enrollment_count
      FROM admission_capacity_ledgers l
      LEFT JOIN occupying o ON o.kind = l.offering_kind AND o.offering_id = l.offering_id
      WHERE l.occupancy <> COALESCE(o.n, 0)
      """)

    Enum.map(rows, fn [kind, offering_id, workspace_id, occupancy, enrollment_count] ->
      %{
        entity_type: String.to_atom(kind),
        entity_id: Ecto.UUID.load!(offering_id),
        workspace_id: Ecto.UUID.load!(workspace_id),
        detail: %{occupancy: occupancy, enrollment_count: enrollment_count}
      }
    end)
  end

  # 规10：展示投影漂移超一拍（R17「超 N 拍」= 与 cron 周期对齐的一拍宽限）——
  # 投影（confirmed_count / confirmed_count_sync_version）与账本不一致，且账本
  # 最近变更早于一个扫描周期（capacity.synced 异步在途的正常窗口不告警；
  # 超窗仍漂移 = 信号丢失/订阅方失败）。
  def detect_capacity_projection_drift do
    {:ok, %{rows: rows}} =
      Repo.query(
        """
        SELECT l.offering_kind, l.offering_id, l.workspace_id, l.occupancy,
               l.sync_version, e.confirmed_count, e.confirmed_count_sync_version
        FROM admission_capacity_ledgers l
        JOIN events e ON e.id = l.offering_id
        WHERE l.offering_kind = 'event'
          AND (e.confirmed_count <> l.occupancy
               OR e.confirmed_count_sync_version <> l.sync_version)
          AND l.updated_at < NOW() - ($1 * INTERVAL '1 second')
        UNION ALL
        SELECT l.offering_kind, l.offering_id, l.workspace_id, l.occupancy,
               l.sync_version, c.confirmed_count, c.confirmed_count_sync_version
        FROM admission_capacity_ledgers l
        JOIN courses c ON c.id = l.offering_id
        WHERE l.offering_kind = 'course'
          AND (c.confirmed_count <> l.occupancy
               OR c.confirmed_count_sync_version <> l.sync_version)
          AND l.updated_at < NOW() - ($1 * INTERVAL '1 second')
        """,
        [@drift_grace_seconds]
      )

    Enum.map(rows, fn [
                        kind,
                        offering_id,
                        workspace_id,
                        occupancy,
                        sync_version,
                        confirmed_count,
                        applied_version
                      ] ->
      %{
        entity_type: String.to_atom(kind),
        entity_id: Ecto.UUID.load!(offering_id),
        workspace_id: Ecto.UUID.load!(workspace_id),
        detail: %{
          occupancy: occupancy,
          sync_version: sync_version,
          confirmed_count: confirmed_count,
          confirmed_count_sync_version: applied_version
        }
      }
    end)
  end

  # 规11：occupancy > capacity（R16/AE4：capacity 调小低于 occupancy 放行后的
  # 合法超员窗口由本规则看护，存量占位自然释放收敛后 finding 自消）。
  def detect_occupancy_exceeds_capacity do
    {:ok, %{rows: rows}} =
      Repo.query("""
      SELECT offering_kind, offering_id, workspace_id, occupancy, capacity
      FROM admission_capacity_ledgers
      WHERE capacity IS NOT NULL AND occupancy > capacity
      """)

    Enum.map(rows, fn [kind, offering_id, workspace_id, occupancy, capacity] ->
      %{
        entity_type: String.to_atom(kind),
        entity_id: Ecto.UUID.load!(offering_id),
        workspace_id: Ecto.UUID.load!(workspace_id),
        detail: %{occupancy: occupancy, capacity: capacity}
      }
    end)
  end

  # 规12：账本三列缓存漂移于 offering 真值（ADR-0009 Fable 5 HIGH-1）——
  # status / capacity / registration_deadline 经 launched / offering.capacity_changed
  # / *.ended 信号异步覆盖写（KTD4/KTD5），丢投不重试窗口内缓存滞留旧值；规8-11
  # 只看护 occupancy 与下游投影，本规则补「缓存≈真值」新不变量的上游看护。
  # 无宽限（Fable 5 复审 MEDIUM 缝隙修复）：旧版锚 l.updated_at < NOW()-600s 会被
  # reserve/release 的 SET updated_at=NOW()（不占缓存列、不收敛漂移）持续刷新——
  # 报名活跃的 offering 宽限永不满足、永不告警，恰是超卖风险最高者。改为「缓存≠
  # 真值即出 finding」：信号在途（秒级）命中的瞬时 finding 由刷新语义（逐规则
  # upsert + 未命中删除）下一拍自消（规8 同款先例），误报窗口低、无害、自愈。
  def detect_ledger_cache_drift do
    {:ok, %{rows: rows}} =
      Repo.query(
        """
        SELECT l.offering_kind, l.offering_id, l.workspace_id,
               l.status, e.status,
               l.capacity, e.capacity,
               l.registration_deadline, e.registration_deadline
        FROM admission_capacity_ledgers l
        JOIN events e ON e.id = l.offering_id
        WHERE l.offering_kind = 'event'
          AND (l.status <> e.status
               OR l.capacity IS DISTINCT FROM e.capacity
               OR l.registration_deadline IS DISTINCT FROM e.registration_deadline)
        UNION ALL
        SELECT l.offering_kind, l.offering_id, l.workspace_id,
               l.status, c.status,
               l.capacity, c.capacity,
               l.registration_deadline, c.registration_deadline
        FROM admission_capacity_ledgers l
        JOIN courses c ON c.id = l.offering_id
        WHERE l.offering_kind = 'course'
          AND (l.status <> c.status
               OR l.capacity IS DISTINCT FROM c.capacity
               OR l.registration_deadline IS DISTINCT FROM c.registration_deadline)
        """,
        []
      )

    Enum.map(rows, fn [
                        kind,
                        offering_id,
                        workspace_id,
                        ledger_status,
                        truth_status,
                        ledger_capacity,
                        truth_capacity,
                        ledger_deadline,
                        truth_deadline
                      ] ->
      %{
        entity_type: String.to_atom(kind),
        entity_id: Ecto.UUID.load!(offering_id),
        workspace_id: Ecto.UUID.load!(workspace_id),
        detail: %{
          drifts:
            cache_drifts(
              status: {ledger_status, truth_status},
              capacity: {ledger_capacity, truth_capacity},
              registration_deadline: {ledger_deadline, truth_deadline}
            )
        }
      }
    end)
  end

  # 规12 detail：仅列漂移字段，逐字段双值（ledger 缓存值 / truth offering 真值）。
  # registration_deadline 裸 SQL 解出 NaiveDateTime（无时区，order.ex 同款注释），
  # 落 jsonb 前转 ISO8601 字符串（规7 last_activity_at 同款）。
  defp cache_drifts(pairs) do
    pairs
    |> Enum.reject(fn {_field, {ledger, truth}} -> ledger == truth end)
    |> Map.new(fn {field, {ledger, truth}} ->
      {Atom.to_string(field), %{"ledger" => drift_value(ledger), "truth" => drift_value(truth)}}
    end)
  end

  defp drift_value(%NaiveDateTime{} = value), do: NaiveDateTime.to_iso8601(value)
  defp drift_value(%DateTime{} = value), do: DateTime.to_iso8601(value)
  defp drift_value(value), do: value

  # ── 规13：资金写动作频次告警（R3；:fund_action_burst）-----------------------
  #
  # 近 window 秒内同一 actor 的同类资金写治理动作超 threshold 笔 → 按 actor
  # 一行 Finding（detail 带 per-action 计数与最近发生时间）。**纯查询**
  # admin_action_logs，不触碰资金链路任何写路径；Repo 直查与规8-12 同口径。
  # actor_id IS NULL 的系统动作（event/course_cancel_batch_refund 批量退款）
  # 显式排除——批量是系统驱动非人为滥用面，且本就不在监控枚举内。
  #
  # 窗口/阈值 app env 可调（config :cgc_2046, __MODULE__,
  # fund_action_burst_window_seconds: / fund_action_burst_threshold:），
  # 默认 3600 秒 / 5 笔（严格大于才命中）。Finding 刷新语义天然适配告警
  # 生命周期：爆发后频率回落 → 下一拍未命中删除（告警自消）；首次发现经
  # maybe_warn_new 补一条 Logger.warning（ops 日志告警通道），finding 存续
  # 期间 refresh 不重复刷——天然节流。

  def detect_fund_action_burst do
    {window, threshold} = fund_burst_config()

    {:ok, %{rows: rows}} =
      Repo.query(
        """
        SELECT actor_id, action, COUNT(*)::int AS n, MAX(inserted_at)::text AS latest_at
        FROM admin_action_logs
        WHERE action = ANY($1)
          AND actor_id IS NOT NULL
          AND inserted_at > NOW() - ($2 || ' seconds')::interval
        GROUP BY actor_id, action
        HAVING COUNT(*) > $3
        ORDER BY actor_id
        """,
        [Enum.map(@fund_burst_actions, &Atom.to_string/1), Integer.to_string(window), threshold]
      )

    rows
    |> Enum.group_by(fn [actor_id, _action, _n, _latest_at] -> actor_id end)
    |> Enum.map(fn {actor_id, action_rows} ->
      %{
        entity_type: :user,
        entity_id: Ecto.UUID.load!(actor_id),
        workspace_id: nil,
        detail: %{
          "actions" =>
            Enum.map(action_rows, fn [_actor_id, action, n, latest_at] ->
              %{"action" => action, "count" => n, "latest_at" => latest_at}
            end),
          "window_seconds" => window,
          "threshold" => threshold
        }
      }
    end)
  end

  # ── 规15（#556）：通知 outbox 终态失败面 ----------------------------------
  # 24h 内落 :failed 的 notification_deliveries 行逐行出 Finding（终态化本体
  # 在 DeliveryWorker 末拍）；窗口语义自清——超窗未命中删除（finding 消失 =
  # 失败已陈旧，与 Oban Pruner 窗口注释同义）。

  def detect_notification_delivery_failed do
    {:ok, %{rows: rows}} =
      Repo.query(
        """
        SELECT id::text, template_key, platform, last_error, attempts
        FROM notification_deliveries
        WHERE status = 'failed'
          AND updated_at > NOW() - ($1 || ' seconds')::interval
        ORDER BY updated_at DESC
        """,
        [Integer.to_string(@notification_failed_window_seconds)]
      )

    Enum.map(rows, fn [id, template_key, platform, last_error, attempts] ->
      %{
        entity_type: :notification_delivery,
        entity_id: id,
        workspace_id: nil,
        detail: %{
          "template_key" => template_key,
          "platform" => platform,
          "last_error" => last_error,
          "attempts" => attempts,
          "window_seconds" => @notification_failed_window_seconds
        }
      }
    end)
  end

  defp fund_burst_config do
    conf = Application.get_env(:cgc_2046, __MODULE__, [])

    {Keyword.get(conf, :fund_action_burst_window_seconds, @fund_burst_default_window_seconds),
     Keyword.get(conf, :fund_action_burst_threshold, @fund_burst_default_threshold)}
  end
end
