defmodule Cgc2046.Mcp.ConfirmationRaceTest do
  @moduledoc """
  确认流并发/失败路径回归测试（review findings MEDIUM-1 / MEDIUM-2）。

  - MEDIUM-1：并发 confirm 同一 pending → 执行器恰好执行一次（原子条件更新）
  - MEDIUM-2：执行器失败 → pending 回到 :pending 可重试（不留 confirmed-but-no-effect）
  """
  use Cgc2046.DataCase, async: false

  alias Cgc2046.Mcp.{Confirmation, PendingOperation}

  defp register_user(email) do
    strategy = AshAuthentication.Info.strategy!(Cgc2046.Accounts.User, :password)

    {:ok, user} =
      AshAuthentication.Strategy.action(strategy, :register, %{
        email: email,
        password: "sup3r-secret-password"
      })

    user
  end

  defp pend(user, tool \\ "race_probe") do
    {:ok, op} =
      PendingOperation
      |> Ash.Changeset.for_create(
        :pend,
        %{user_id: user.id, tool: tool, params: %{}, summary: "probe"},
        authorize?: false
      )
      |> Ash.create()

    op
  end

  # 直接测 PendingOperation :confirm action 的 DB 层条件更新原子性，隔离 executor 副作用
  # （MEDIUM-2 已用真实 create_invitation 路径覆盖 confirm 全链）
  describe "MEDIUM-1 并发双确认" do
    test "并发 confirm 同一 pending：数据库层条件更新保证只有一个成功" do
      user = register_user("race-1@example.com")
      op = pend(user)

      # 直接对 :confirm action 并发发起（不经 Confirmation.confirm，隔离测 action 原子性）
      results =
        1..8
        |> Task.async_stream(
          fn _ ->
            op
            |> Ash.Changeset.for_update(:confirm, %{}, actor: user)
            |> Ash.update()
          end,
          max_concurrency: 8
        )
        |> Enum.map(fn {:ok, r} -> r end)

      oks = Enum.count(results, &match?({:ok, _}, &1))
      errs = Enum.count(results, &match?({:error, _}, &1))

      assert oks == 1
      assert errs == 7

      reloaded = Ash.get!(PendingOperation, op.id, authorize?: false)
      assert reloaded.status == :confirmed
    end
  end

  describe "MEDIUM-2 执行器失败" do
    test "执行器返回 error → pending 恢复为 :pending 可重试" do
      user = register_user("race-2@example.com")
      op = pend(user, "create_invitation")

      # create_invitation 执行器需要 workspace_id；params 缺它 → 执行器 error
      assert {:error, msg} = Confirmation.confirm(user, op.id)
      assert is_binary(msg)

      reloaded = Ash.get!(PendingOperation, op.id, authorize?: false)
      assert reloaded.status == :pending
      assert reloaded.resolved_at == nil

      # 可再次发起 confirm（重试不被「已确认」卡死）
      assert {:error, _} = Confirmation.confirm(user, op.id)
    end
  end

  describe "MEDIUM-3 未知 tool dispatch fallback" do
    test "confirm 未知 tool → 明确错误，pending 仍可恢复" do
      user = register_user("unknown-tool@example.com")

      # 直接造一条 tool 字段为未知值的 pending（绕过 request，模拟数据异常）
      op = pend(user, "no_such_tool")

      assert {:error, msg} = Confirmation.confirm(user, op.id)
      assert msg =~ "no executor"

      # mark_confirmed 已成功 → execute/3 fallback 失败 → revert 回 pending，
      # 不留 confirmed-but-no-effect（与 MEDIUM-2 同不变式）
      reloaded = Ash.get!(PendingOperation, op.id, authorize?: false)
      assert reloaded.status == :pending
      assert reloaded.resolved_at == nil
    end
  end
end
