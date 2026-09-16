defmodule Cgc2046.RepoTest do
  @moduledoc """
  Repo 层单测（PR-I D6 / #621）：acquire_lock 双 hash 域各自加锁成功 / 同事务重复
  加锁幂等 / uuid! 值校验。

  锁失败路径（lock_timeout 5s 后 lock_not_available、死锁 deadlock_detected）是
  真并发构造，不在本文件（本文件 async: true，sandbox 事务内锁只是 savepoint）——
  见 `test/cgc_2046/lock_error_surfaces_test.exs`（async: false + unboxed 真事务）。

  注：DataCase sandbox 使每个测试处于事务内，pg_advisory_xact_lock 的事务级
  语义天然满足；锁在测试事务回滚时自动释放。
  """

  use Cgc2046.DataCase, async: true

  alias Cgc2046.Repo

  describe "acquire_lock/2 双 hash 域" do
    test "hashtext（默认）域加锁成功" do
      assert :ok = Repo.acquire_lock("workspace-test-key")
    end

    test "hashtextextended 域加锁成功（miniprogram_code 键域）" do
      assert :ok = Repo.acquire_lock("inv:platform", hash: :hashtextextended)
    end

    test "同 key 两种 hash 域分离（hashtext 与 hashtextextended 产出不同 int8，无碰撞）" do
      {:ok, %{rows: [[hashtext_hash]]}} = Repo.query("SELECT hashtext($1)", ["k"])
      {:ok, %{rows: [[hashtextended_hash]]}} = Repo.query("SELECT hashtextextended($1, 0)", ["k"])

      refute hashtext_hash == hashtextended_hash
    end
  end

  describe "acquire_lock/2 幂等" do
    test "同事务重复加锁幂等（已持锁再取成功，不报错）" do
      assert :ok = Repo.acquire_lock("idempotent-key")
      assert :ok = Repo.acquire_lock("idempotent-key")
    end

    test "双 hash 域各自重复加锁幂等" do
      assert :ok = Repo.acquire_lock("idem-k", hash: :hashtextextended)
      assert :ok = Repo.acquire_lock("idem-k", hash: :hashtextextended)
    end
  end

  describe "uuid!/1" do
    test "合法 uuid dump 为 raw bytes" do
      uuid = "1b2d3c4e-5f6a-4b7c-8d9e-0f1a2b3c4d5e"
      assert Repo.uuid!(uuid) == Ecto.UUID.dump!(uuid)
      assert byte_size(Repo.uuid!(uuid)) == 16
    end

    test "非法输入抛 ArgumentError（明确错误，不吞）" do
      assert_raise ArgumentError, fn -> Repo.uuid!("not-a-uuid") end
      assert_raise ArgumentError, fn -> Repo.uuid!("") end
    end
  end
end
