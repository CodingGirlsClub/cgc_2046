defmodule Cgc2046.Notifications.DeliveryKeyTest do
  @moduledoc """
  #902：DeliveryKey 纯函数面钉测——learning_stagnation 周桶的跨桶边界
  （同桶同键、跨桶新键重发的公式保证）。纯函数直测不经 DB/Fanout。
  """

  use ExUnit.Case, async: true

  alias Cgc2046.Notifications.DeliveryKey
  alias Cgc2046.Notifications.NotificationWorker

  describe "stagnation_bucket/1（epoch 对齐 7 天桶）" do
    test "桶锚点：epoch 零点（周四）起桶 0，整 7 天边界翻桶" do
      assert DeliveryKey.stagnation_bucket(~U[1970-01-01T00:00:00Z]) == 0
      assert DeliveryKey.stagnation_bucket(~U[1970-01-07T23:59:59Z]) == 0
      assert DeliveryKey.stagnation_bucket(~U[1970-01-08T00:00:00Z]) == 1
    end

    test "桶边界周四 00:00 UTC：边界前后差一桶（2026-09-24 为周四）" do
      # 同桶：桶内任意时刻（上周四 00:00 与本周三 23:59:59）
      assert DeliveryKey.stagnation_bucket(~U[2026-09-23T23:59:59Z]) ==
               DeliveryKey.stagnation_bucket(~U[2026-09-17T00:00:00Z])

      # 跨桶：边界后 1 秒即新桶
      assert DeliveryKey.stagnation_bucket(~U[2026-09-24T00:00:00Z]) ==
               DeliveryKey.stagnation_bucket(~U[2026-09-23T23:59:59Z]) + 1
    end

    test "同桶同键、跨桶新键（跨桶重发的公式保证）" do
      run_id = "run-#{System.unique_integer([:positive])}"

      key_at = fn dt ->
        "learning.stagnation:#{run_id}:w#{DeliveryKey.stagnation_bucket(dt)}"
      end

      # 同桶（2026-09-24 周四 12:00 与 2026-09-29 周二 23:59:59）→ 同键
      assert key_at.(~U[2026-09-24T12:00:00Z]) == key_at.(~U[2026-09-29T23:59:59Z])

      # 跨桶（下一周四 2026-10-01 00:00）→ 新键
      refute key_at.(~U[2026-09-29T23:59:59Z]) == key_at.(~U[2026-10-01T00:00:00Z])
    end
  end

  describe "speaker_completed 显式腿标记（#902）" do
    test "两腿同信号键靠 leg 成分防撞：managers/speaker 各派一键" do
      meta = %{"speaker_invitation_id" => "inv-1", "idempotency_key" => "speaker.completed:inv-1"}

      # 与旧「data 含 title」启发式对同一输入派生相同键（等价性钉测）：
      # managers 腿 data 带 title，speaker 腿不带。
      assert DeliveryKey.event_key(
               "speaker_completed",
               %{"speaker_invitation_id" => "inv-1", "title" => "t"},
               Map.put(meta, "leg", "managers")
             ) == "speaker.completed:inv-1:managers"

      assert DeliveryKey.event_key(
               "speaker_completed",
               %{"speaker_invitation_id" => "inv-1"},
               Map.put(meta, "leg", "speaker")
             ) == "speaker.completed:inv-1:speaker"
    end

    test "job_meta 缺 leg → raise（fail loud，不静默并腿）" do
      assert_raise KeyError, ~r/"leg"/, fn ->
        DeliveryKey.event_key(
          "speaker_completed",
          %{"speaker_invitation_id" => "inv-1"},
          %{"speaker_invitation_id" => "inv-1", "idempotency_key" => "speaker.completed:inv-1"}
        )
      end
    end
  end

  # #853（C10 缩小版）：registry × DeliveryKey 双向守卫。catalog 已裁定不做
  # （渲染本质 per-platform，wechat 槽位 vs tt/xhs 透传无法单源），完备性靠
  # 守卫钉死：durable 漏登记新键会静默走旧直插路径，event_key 缺子句只在
  # 生产运行时 FunctionClauseError——两者都必须先在测试红。

  # 直插白名单：registry 里尚未迁耐久投递的键，逐名报备。flashback_wish_echo
  # 为 #834 回执契约例外（保留直插，见 delivery_key.ex moduledoc）；其余四键
  # 为 qualification/schedule 类未迁耐久。
  @legacy_direct_keys [
    "event_qualification_confirmed",
    "event_qualification_underfilled",
    "event_qualification_manager",
    "event_schedule_changed",
    "flashback_wish_echo"
  ]

  # event_key/3 对全部 durable 键的最小可派生输入 {data, job_meta}。手写而非
  # 从 registry data_keys/job_meta_keys 机械构造：event_reminder 的 event_id
  # 由 Fanout 调用处补入 job_meta、不在 registry 声明里，机械构造会假绿。
  @durable_event_fixtures %{
    # 专有子句键
    "approval_result" => {%{"enrollment_id" => "enr-1", "status" => "approved"}, %{}},
    "approval_reminder" => {%{}, %{"enrollment_id" => "enr-1"}},
    "learning_stagnation" => {%{}, %{"run_id" => "run-1"}},
    "event_reminder" => {%{"starts_at" => "2026-10-01T00:00:00Z"}, %{"event_id" => "evt-1"}},
    "event_moderator_assigned" => {%{}, %{"event_id" => "evt-1"}},
    "event_moderator_removed" => {%{}, %{"event_id" => "evt-1"}},
    "speaker_completed" => {%{}, %{"idempotency_key" => "spk-1", "leg" => "managers"}},
    # from_meta 兜底子句键（事件键 = job_meta 幂等键直用）
    "enrollment_submitted" => {%{}, %{"idempotency_key" => "k-enrollment_submitted"}},
    "enrollment_completed" => {%{}, %{"idempotency_key" => "k-enrollment_completed"}},
    "enrollment_check_in_code" => {%{}, %{"idempotency_key" => "k-enrollment_check_in_code"}},
    "speaker_accepted" => {%{}, %{"idempotency_key" => "k-speaker_accepted"}},
    "payment_succeeded" => {%{}, %{"idempotency_key" => "k-payment_succeeded"}},
    "payment_received" => {%{}, %{"idempotency_key" => "k-payment_received"}},
    "payment_expired" => {%{}, %{"idempotency_key" => "k-payment_expired"}},
    "refund_succeeded" => {%{}, %{"idempotency_key" => "k-refund_succeeded"}},
    "refund_failed" => {%{}, %{"idempotency_key" => "k-refund_failed"}},
    "volunteer_application_submitted" =>
      {%{}, %{"idempotency_key" => "k-volunteer_application_submitted"}},
    "volunteer_application_interview" =>
      {%{}, %{"idempotency_key" => "k-volunteer_application_interview"}},
    "volunteer_application_training" =>
      {%{}, %{"idempotency_key" => "k-volunteer_application_training"}},
    "volunteer_application_assigned" =>
      {%{}, %{"idempotency_key" => "k-volunteer_application_assigned"}},
    "volunteer_application_rejected" =>
      {%{}, %{"idempotency_key" => "k-volunteer_application_rejected"}},
    "volunteer_application_canceled" =>
      {%{}, %{"idempotency_key" => "k-volunteer_application_canceled"}}
  }

  describe "registry × DeliveryKey 守卫（#853）" do
    test "durable ⊆ registry 且非 durable 键逐名报备（漏登记 durable 即红）" do
      registry =
        NotificationWorker.types()
        |> Enum.map(& &1.template_key)
        |> MapSet.new()

      durable = DeliveryKey.durable_keys() |> MapSet.new()

      # 正向：durable 里的每个键都是 registry 真实类型——delivery_key 侧删类型/
      # 拼写漂移后残留的孤儿 durable 键会静默走耐久路径
      assert MapSet.subset?(durable, registry),
             "durable 有 registry 不存在的键（孤儿 durable，静默走耐久路径）：" <>
               inspect(MapSet.difference(durable, registry) |> Enum.sort())

      # 反向：registry − durable 必须逐名等于直插白名单——新通知类型漏登记
      # durable（或白名单漏报备）即红，不允许第三态
      legacy = MapSet.difference(registry, durable)
      allowlist = MapSet.new(@legacy_direct_keys)

      assert legacy == allowlist,
             "registry 未迁耐久的键集 ≠ 直插白名单\n" <>
               "  仅 registry 有：#{inspect(MapSet.difference(legacy, allowlist) |> Enum.sort())}\n" <>
               "  仅白名单有：#{inspect(MapSet.difference(allowlist, legacy) |> Enum.sort())}"
    end

    test "from_meta ⊆ durable（兜底子句只对 durable 键合法）" do
      durable = DeliveryKey.durable_keys() |> MapSet.new()
      from_meta = DeliveryKey.from_meta_keys() |> MapSet.new()

      assert MapSet.subset?(from_meta, durable),
             "from_meta 出现非 durable 键（Fanout 委托层永远走不到该兜底子句）：" <>
               inspect(MapSet.difference(from_meta, durable) |> Enum.sort())
    end

    test "event_key/3 对全部 durable 键可派生（缺子句在此红，不等运行时 FunctionClauseError）" do
      durable = DeliveryKey.durable_keys() |> MapSet.new()
      fixtures = @durable_event_fixtures |> Map.keys() |> MapSet.new()

      # fixture 键集与 durable 全等：新增 durable 键没配 fixture（本测试无法
      # 派生）/ fixture 配了非 durable 键（配了也走不到）都红
      assert fixtures == durable,
             "event_key fixture 键集 ≠ durable 键集\n" <>
               "  仅 fixture 有：#{inspect(MapSet.difference(fixtures, durable) |> Enum.sort())}\n" <>
               "  仅 durable 有：#{inspect(MapSet.difference(durable, fixtures) |> Enum.sort())}"

      for {key, {data, job_meta}} <- @durable_event_fixtures do
        event_key = DeliveryKey.event_key(key, data, job_meta)
        assert is_binary(event_key) and event_key != "", "#{key} 派生出空事件键"
      end
    end
  end
end
