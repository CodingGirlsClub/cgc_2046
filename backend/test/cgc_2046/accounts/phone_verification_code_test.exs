defmodule Cgc2046.Accounts.PhoneVerificationCodeTest do
  @moduledoc """
  PhoneVerificationCode 单测（plan 002 U3 + #253 方案 A）：生命周期全
  边界——新旧码并存、5min 过期、3 次错码失效（仅最新码）、单次使用、
  并发消费防重放、任一命中作废全部。
  """
  use Cgc2046.DataCase, async: true

  alias Cgc2046.Accounts.PhoneVerificationCode

  @phone "+8613800138000"

  describe "issue/2" do
    test "生成 6 位数字码，落库 hash 而非明文" do
      {:ok, code, _rid} = PhoneVerificationCode.issue(@phone, :login)

      assert String.match?(code, ~r/^\d{6}$/)

      row = fetch_row(@phone, :login)
      # 明文码不落库：code_hash 是 SHA256(phone <> ":" <> code)
      expected = :crypto.hash(:sha256, @phone <> ":" <> code) |> Base.encode16(case: :lower)
      assert row.code_hash == expected
      assert row.consumed_at == nil
      assert row.attempts_left == 3
    end

    test "#253 方案 A：重发不作废旧码——两码并存且都活跃" do
      {:ok, _code1, _rid} = PhoneVerificationCode.issue(@phone, :login)
      {:ok, code2, _rid} = PhoneVerificationCode.issue(@phone, :login)

      rows = fetch_all_active(@phone, :login)
      # 新旧码都在活跃集合
      assert Enum.count(rows) == 2
      assert Enum.any?(rows, &(&1.code_hash == hash(@phone, code2)))
    end

    test "不同 purpose 互不作废" do
      {:ok, _login_code, _rid} = PhoneVerificationCode.issue(@phone, :login)
      {:ok, _bind_code, _rid} = PhoneVerificationCode.issue(@phone, :wechat_bind)

      assert Enum.count(fetch_all_active(@phone, :login)) == 1
      assert Enum.count(fetch_all_active(@phone, :wechat_bind)) == 1
    end
  end

  describe "consume_valid/3" do
    test "正确码消费成功，码单次使用" do
      {:ok, code, _rid} = PhoneVerificationCode.issue(@phone, :login)

      assert :ok = PhoneVerificationCode.consume_valid(@phone, code, :login)

      # 重放：同码已消费 → 不可用
      assert {:error, :code_not_available} =
               PhoneVerificationCode.consume_valid(@phone, code, :login)
    end

    test "错码不消费但可用；3 次错码后失效" do
      {:ok, code, _rid} = PhoneVerificationCode.issue(@phone, :login)
      wrong = if code == "000000", do: "111111", else: "000000"

      assert {:error, :invalid_code} = PhoneVerificationCode.consume_valid(@phone, wrong, :login)

      # 还有 2 次机会，正确码仍可用
      assert :ok = PhoneVerificationCode.consume_valid(@phone, code, :login)
    end

    test "连续 3 次错码 → 码失效（正确码也不可用）" do
      {:ok, code, _rid} = PhoneVerificationCode.issue(@phone, :login)
      wrong = if code == "000000", do: "111111", else: "000000"

      for _ <- 1..3,
          do: PhoneVerificationCode.consume_valid(@phone, wrong, :login)

      assert {:error, :code_not_available} =
               PhoneVerificationCode.consume_valid(@phone, code, :login)
    end

    test "码过期（expires_at 之后）→ 不可用" do
      {:ok, code, _rid} = PhoneVerificationCode.issue(@phone, :login)
      backdate_expiry(@phone, :login)

      assert {:error, :code_not_available} =
               PhoneVerificationCode.consume_valid(@phone, code, :login)
    end

    test "不存在码 / 其他 purpose → 统一 code_not_available" do
      assert {:error, :code_not_available} =
               PhoneVerificationCode.consume_valid(@phone, "123456", :login)

      {:ok, code, _rid} = PhoneVerificationCode.issue(@phone, :login)

      assert {:error, :code_not_available} =
               PhoneVerificationCode.consume_valid(@phone, code, :wechat_bind)
    end

    test "#253 A：重发后旧码仍可消费成功" do
      {:ok, code1, _rid} = PhoneVerificationCode.issue(@phone, :login)
      _ = PhoneVerificationCode.issue(@phone, :login)

      assert :ok = PhoneVerificationCode.consume_valid(@phone, code1, :login)
    end

    test "#253 A：旧码消费成功后，新码再试 → code_not_available（全部作废）" do
      {:ok, code1, _rid} = PhoneVerificationCode.issue(@phone, :login)
      {:ok, code2, _rid} = PhoneVerificationCode.issue(@phone, :login)

      assert :ok = PhoneVerificationCode.consume_valid(@phone, code1, :login)

      assert {:error, :code_not_available} =
               PhoneVerificationCode.consume_valid(@phone, code2, :login)
    end

    test "#253 A：错码 3 次仅作废最新码，旧码仍可用" do
      {:ok, code_old, _rid} = PhoneVerificationCode.issue(@phone, :login)
      {:ok, _code_new, _rid} = PhoneVerificationCode.issue(@phone, :login)
      wrong = if code_old == "000000", do: "111111", else: "000000"

      # 背靠背 issue 同秒平票：回拨旧码 inserted_at 1s，保证
      # decrement_latest_attempt 的「最新码」排序确定（flake 根因）
      backdate_inserted(@phone, :login)

      # 3 次错码 → 最新码 attempts 耗尽作废
      for _ <- 1..3,
          do: PhoneVerificationCode.consume_valid(@phone, wrong, :login)

      # 旧码不受错码递减影响，仍可成功
      assert :ok = PhoneVerificationCode.consume_valid(@phone, code_old, :login)
    end

    test "并发消费防重放：两进程同时用同码，至多一个成功" do
      {:ok, code, _rid} = PhoneVerificationCode.issue(@phone, :login)

      parent = self()

      tasks =
        for _ <- 1..2 do
          Task.async(fn ->
            send(parent, {:consume, PhoneVerificationCode.consume_valid(@phone, code, :login)})
          end)
        end

      results =
        for task <- tasks do
          Task.await(task)
          receive(do: ({:consume, r} -> r))
        end

      assert Enum.count(results, &(&1 == :ok)) == 1
      assert Enum.count(results, &match?({:error, :code_not_available}, &1)) == 1
    end
  end

  # ── helpers ─────────────────────────────────────────────────────────────

  defp fetch_row(phone, purpose) do
    {:ok, %Postgrex.Result{rows: [[id, code_hash, attempts, consumed]]}} =
      Ecto.Adapters.SQL.query(
        Cgc2046.Repo,
        "SELECT id, code_hash, attempts_left, consumed_at FROM phone_verification_codes WHERE phone = $1 AND purpose = $2 ORDER BY inserted_at DESC LIMIT 1",
        [phone, Atom.to_string(purpose)]
      )

    %{id: id, code_hash: code_hash, attempts_left: attempts, consumed_at: consumed}
  end

  defp fetch_all_active(phone, purpose) do
    {:ok, %Postgrex.Result{rows: rows}} =
      Ecto.Adapters.SQL.query(
        Cgc2046.Repo,
        "SELECT code_hash FROM phone_verification_codes WHERE phone = $1 AND purpose = $2 AND consumed_at IS NULL",
        [phone, Atom.to_string(purpose)]
      )

    Enum.map(rows, fn [hash] -> %{code_hash: hash} end)
  end

  # 两码同秒 inserted_at 平票：把较早 issue 的行（非最新）回拨 1s，
  # 使 ORDER BY inserted_at DESC 的「最新码」确定（#253 flake 修复）。
  # 只回拨 id 最小（先插入）那一行——PG 无显式 rowid，用 ctid 保插入序。
  defp backdate_inserted(phone, purpose) do
    {:ok, _} =
      Ecto.Adapters.SQL.query(
        Cgc2046.Repo,
        """
        UPDATE phone_verification_codes
        SET inserted_at = inserted_at - interval '1 second'
        WHERE id = (
          SELECT id FROM phone_verification_codes
          WHERE phone = $1 AND purpose = $2 AND consumed_at IS NULL
          ORDER BY inserted_at ASC, ctid ASC
          LIMIT 1
        )
        """,
        [phone, Atom.to_string(purpose)]
      )

    :ok
  end

  defp backdate_expiry(phone, purpose) do
    {:ok, _} =
      Ecto.Adapters.SQL.query(
        Cgc2046.Repo,
        "UPDATE phone_verification_codes SET expires_at = now() - interval '1 minute' WHERE phone = $1 AND purpose = $2",
        [phone, Atom.to_string(purpose)]
      )

    :ok
  end

  defp hash(phone, code),
    do: :crypto.hash(:sha256, phone <> ":" <> code) |> Base.encode16(case: :lower)
end
