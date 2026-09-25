defmodule Cgc2046.Notifications.StalenessTest do
  @moduledoc """
  #847：Staleness 是两条投递路径共用的过期重查解释器（NotificationWorker
  与 DeliveryWorker 发送前同源判断，PR-B 迁移 stale 类键的前提）。stale
  三规格的行为级三态由 notification_worker_test 的表驱动行为测试锚定；
  这里钉解释器的模块直出面：现 4 个走 Delivery 的键（stale=nil）恒放行
  ——data 引用不存在的实体也照发，这 4 键在发送前重查接入后行为不变；
  以及 id 缺失 / 未知类型的兜底投递。
  """

  use Cgc2046.DataCase, async: false

  alias Cgc2046.Notifications.Staleness

  @delivery_keys ~w(
    event_schedule_changed
    event_qualification_confirmed
    event_qualification_underfilled
    event_qualification_manager
  )

  describe "4 个走 Delivery 的键（stale = nil）恒放行" do
    test "data 引用不存在的实体 id 也不重查（无 stale 规格 → 直接投递）" do
      for key <- @delivery_keys do
        refute Staleness.stale?(%{
                 "template_key" => key,
                 "data" => %{"event_id" => "00000000-0000-0000-0000-000000000000"}
               }),
               "#{key} 不应携带 stale 重查"
      end
    end
  end

  test "stale 规格存在但 data 缺 id（nil）→ 投递（catch-all 兜底）" do
    refute Staleness.stale?(%{
             "template_key" => "approval_reminder",
             "data" => %{"enrollment_id" => nil}
           })
  end

  test "未知 template_key → 不重查" do
    refute Staleness.stale?(%{"template_key" => "no_such_template", "data" => %{"x" => "1"}})
  end

  test "无 data → 不重查（catch-all）" do
    refute Staleness.stale?(%{"template_key" => "approval_reminder"})
  end
end
