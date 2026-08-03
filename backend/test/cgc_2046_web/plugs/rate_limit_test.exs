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
end
