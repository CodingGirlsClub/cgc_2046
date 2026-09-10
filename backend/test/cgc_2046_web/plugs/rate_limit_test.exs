defmodule Cgc2046Web.Plugs.RateLimitTest do
  use ExUnit.Case, async: false

  setup do
    :ets.delete_all_objects(Cgc2046Web.Plugs.RateLimit.table())
    Application.put_env(:cgc_2046, Cgc2046Web.Plugs.RateLimit, max_attempts: 3)

    on_exit(fn ->
      Application.put_env(:cgc_2046, Cgc2046Web.Plugs.RateLimit, max_attempts: 999_999)
    end)

    :ok
  end

  describe "check/1" do
    test "allows requests under the limit" do
      assert :ok = Cgc2046Web.Plugs.RateLimit.check("test:1.2.3.4:a@b.com")
      assert :ok = Cgc2046Web.Plugs.RateLimit.check("test:1.2.3.4:a@b.com")
      assert :ok = Cgc2046Web.Plugs.RateLimit.check("test:1.2.3.4:a@b.com")
    end

    test "blocks when over the limit" do
      for _ <- 1..3 do
        assert :ok = Cgc2046Web.Plugs.RateLimit.check("test:1.2.3.4:b@b.com")
      end

      assert :error = Cgc2046Web.Plugs.RateLimit.check("test:1.2.3.4:b@b.com")
    end

    test "different keys have independent counters" do
      for _ <- 1..3 do
        assert :ok = Cgc2046Web.Plugs.RateLimit.check("test:1.2.3.4:c@b.com")
      end

      assert :error = Cgc2046Web.Plugs.RateLimit.check("test:1.2.3.4:c@b.com")
      assert :ok = Cgc2046Web.Plugs.RateLimit.check("test:1.2.3.4:d@b.com")
    end

    test "window expiry resets the counter" do
      key = "test:1.2.3.4:e@b.com"

      for _ <- 1..3 do
        assert :ok = Cgc2046Web.Plugs.RateLimit.check(key)
      end

      assert :error = Cgc2046Web.Plugs.RateLimit.check(key)

      # 模拟窗口过期：把 window_start 设为 15 分钟前
      now = System.system_time(:second)
      :ets.insert(Cgc2046Web.Plugs.RateLimit.table(), {key, 3, now - 901})

      assert :ok = Cgc2046Web.Plugs.RateLimit.check(key)
    end
  end

  # 017 审计加固：键含攻击者可控输入（手机号/邮箱/IP），无修剪时每个新键
  # 永久占一行——公开端点上可被缓慢撑爆内存。:sys.get_state 同步确保
  # :prune 处理完成（repo 测试规范禁 Process.sleep）。
  describe "prune（GenServer 定期清扫）" do
    test "超过 24h 水平线的条目被删，活跃窗口条目保留" do
      table = Cgc2046Web.Plugs.RateLimit.table()
      now = System.system_time(:second)

      stale_key = "test:1.2.3.4:stale@b.com"
      fresh_key = "test:1.2.3.4:fresh@b.com"

      assert :ets.insert(table, {stale_key, 1, now - 100_000})
      assert :ets.insert(table, {fresh_key, 1, now})

      pid = Process.whereis(Cgc2046Web.Plugs.RateLimit)
      send(pid, :prune)
      _ = :sys.get_state(pid)

      refute :ets.member(table, stale_key)
      assert :ets.member(table, fresh_key)
    end
  end
end
