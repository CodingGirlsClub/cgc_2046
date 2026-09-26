defmodule Cgc2046.Notifications.DeliveryKeyTest do
  @moduledoc """
  #902：DeliveryKey 纯函数面钉测——learning_stagnation 周桶的跨桶边界
  （同桶同键、跨桶新键重发的公式保证）。纯函数直测不经 DB/Fanout。
  """

  use ExUnit.Case, async: true

  alias Cgc2046.Notifications.DeliveryKey

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
end
