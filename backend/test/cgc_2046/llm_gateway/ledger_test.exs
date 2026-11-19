defmodule Cgc2046.LlmGateway.LedgerTest do
  use Cgc2046.DataCase, async: false

  import Cgc2046.AccountsFixtures

  alias Cgc2046.LlmGateway.{CreditGrant, Ledger, UsageLog}
  alias Cgc2046.LlmGateway.Workers.CreditExpiryWorker

  describe "personal credits & FIFO expiry deduction" do
    test "consumes expiring subscription credits before permanent pack credits" do
      user = register_user("ledger-fifo")

      {:ok, _} =
        Ledger.grant_personal_credits(user.id, %{amount_mc: 10_000, source_type: :pack})

      tomorrow = DateTime.add(DateTime.utc_now(), 86_400, :second)

      {:ok, wallet} =
        Ledger.grant_personal_credits(user.id, %{
          amount_mc: 5_000,
          source_type: :subscription,
          expires_at: tomorrow
        })

      assert wallet.cached_balance_mc == 15_000

      assert {:ok, held_wallet} = Ledger.acquire_hold(user.id, 8_000)
      assert held_wallet.held_mc == 8_000

      assert {:ok, settled_wallet} =
               Ledger.settle_usage(user.id, 8_000, %{
                 logical_model: "cgc-default",
                 upstream_channel: "deepseek_official_1",
                 upstream_model: "deepseek-chat",
                 billing_mode: :exact,
                 prompt_cache_hit_tokens: 4000,
                 prompt_cache_miss_tokens: 1000,
                 completion_tokens: 500,
                 charged_mc: 7_000,
                 upstream_cost_mc: 3_500
               })

      assert settled_wallet.cached_balance_mc == 8_000
      assert settled_wallet.held_mc == 0

      grants =
        CreditGrant
        |> Ash.read!(authorize?: false)
        |> Enum.filter(&(&1.user_id == user.id))
        |> Map.new(&{&1.source_type, &1})

      assert grants[:subscription].remaining_mc == 0
      assert grants[:subscription].status == :exhausted
      assert grants[:pack].remaining_mc == 8_000
      assert grants[:pack].status == :active
    end
  end

  describe "workspace Owner/Admin batch distribution" do
    test "distributes workspace pool credits to all members and rejects non-admins" do
      %{owner: owner, member: member, workspace: workspace} =
        workspace_with_member(member_roles: [:learner])

      outsider = register_user("ledger-outsider")

      assert {:ok, 50_000} = Ledger.topup_workspace_pool(workspace.id, 50_000)

      assert {:error, :forbidden} =
               Ledger.batch_grant_workspace_members(member, workspace.id, 10_000, "batch-001")

      assert {:error, :forbidden} =
               Ledger.batch_grant_workspace_members(outsider, workspace.id, 10_000, "batch-001")

      assert {:ok, batch_res} =
               Ledger.batch_grant_workspace_members(owner, workspace.id, 15_000, "batch-001")

      assert batch_res.member_count == 2
      assert batch_res.total_granted_mc == 30_000
      assert batch_res.idempotent_replay? == false

      assert {:ok, replay_res} =
               Ledger.batch_grant_workspace_members(owner, workspace.id, 15_000, "batch-001")

      assert replay_res.idempotent_replay? == true

      assert Ledger.fetch_wallet!(owner.id).cached_balance_mc == 15_000
      assert Ledger.fetch_wallet!(member.id).cached_balance_mc == 15_000
    end
  end

  describe "concurrency hold guard" do
    test "prevents concurrent streams from overdrawing a low balance" do
      user = register_user("ledger-concurrent")
      {:ok, _} = Ledger.grant_personal_credits(user.id, %{amount_mc: 10_000, source_type: :pack})

      results =
        1..5
        |> Task.async_stream(fn _ -> Ledger.acquire_hold(user.id, 6_000) end,
          max_concurrency: 5
        )
        |> Enum.map(fn {:ok, res} -> res end)

      successes = Enum.count(results, &match?({:ok, _}, &1))
      rejections = Enum.count(results, &(&1 == {:error, :insufficient_quota}))

      assert successes == 1
      assert rejections == 4
      assert Ledger.fetch_wallet!(user.id).held_mc == 6_000
    end
  end

  describe "settlement invariant" do
    test "caps the charge at balance minus other outstanding holds" do
      user = register_user("ledger-invariant")
      {:ok, _} = Ledger.grant_personal_credits(user.id, %{amount_mc: 10_000, source_type: :pack})

      assert {:ok, _} = Ledger.acquire_hold(user.id, 6_000)
      assert {:ok, _} = Ledger.acquire_hold(user.id, 4_000)

      assert {:ok, wallet} =
               Ledger.settle_usage(user.id, 6_000, %{
                 logical_model: "cgc-default",
                 upstream_channel: "deepseek_official_1",
                 upstream_model: "deepseek-chat",
                 billing_mode: :exact,
                 charged_mc: 10_000,
                 upstream_cost_mc: 5_000
               })

      assert wallet.cached_balance_mc == 4_000
      assert wallet.held_mc == 4_000

      [log] =
        UsageLog
        |> Ash.read!(authorize?: false)
        |> Enum.filter(&(&1.user_id == user.id))

      assert log.charged_mc == 6_000
    end

    test "reconciles past-due credits before computing the charge" do
      user = register_user("ledger-expired-settle")
      past = DateTime.add(DateTime.utc_now(), -60, :second)

      {:ok, _} =
        Ledger.grant_personal_credits(user.id, %{amount_mc: 10_000, source_type: :pack})

      {:ok, _} =
        Ledger.grant_personal_credits(user.id, %{
          amount_mc: 5_000,
          source_type: :subscription,
          expires_at: past
        })

      assert {:ok, _} = Ledger.acquire_hold(user.id, 5_000)

      assert {:ok, wallet} =
               Ledger.settle_usage(user.id, 5_000, %{
                 logical_model: "cgc-default",
                 upstream_channel: "deepseek_official_1",
                 upstream_model: "deepseek-chat",
                 billing_mode: :exact,
                 charged_mc: 10_000,
                 upstream_cost_mc: 5_000
               })

      assert wallet.cached_balance_mc == 0
      assert wallet.held_mc == 0

      grants =
        CreditGrant
        |> Ash.read!(authorize?: false)
        |> Enum.filter(&(&1.user_id == user.id))
        |> Map.new(&{&1.source_type, &1})

      assert grants[:subscription].status == :expired
      assert grants[:subscription].remaining_mc == 0
      assert grants[:pack].status == :exhausted
      assert grants[:pack].remaining_mc == 0

      [log] =
        UsageLog
        |> Ash.read!(authorize?: false)
        |> Enum.filter(&(&1.user_id == user.id))

      assert log.charged_mc == 10_000
    end

    test "never deducts more than the grant buckets actually cover" do
      user = register_user("ledger-underfunded")
      {:ok, _} = Ledger.grant_personal_credits(user.id, %{amount_mc: 10_000, source_type: :pack})

      # 模拟账本不一致：钱包缓存比批次多 5_000。正常写路径不会产生，
      # 这里钉住「扣费不得超过 grants 实际可扣额」的防御性上限。
      Repo.query!(
        "UPDATE llm_wallets SET cached_balance_mc = cached_balance_mc + $2 WHERE user_id = $1",
        [Ecto.UUID.dump!(user.id), 5_000]
      )

      assert {:ok, _} = Ledger.acquire_hold(user.id, 5_000)

      assert {:ok, wallet} =
               Ledger.settle_usage(user.id, 5_000, %{
                 logical_model: "cgc-default",
                 upstream_channel: "deepseek_official_1",
                 upstream_model: "deepseek-chat",
                 billing_mode: :exact,
                 charged_mc: 15_000,
                 upstream_cost_mc: 7_000
               })

      assert wallet.cached_balance_mc == 5_000
      assert wallet.held_mc == 0

      [grant] =
        CreditGrant
        |> Ash.read!(authorize?: false)
        |> Enum.filter(&(&1.user_id == user.id))

      assert grant.remaining_mc == 0
      assert grant.status == :exhausted

      [log] =
        UsageLog
        |> Ash.read!(authorize?: false)
        |> Enum.filter(&(&1.user_id == user.id))

      assert log.charged_mc == 10_000
    end
  end

  describe "CreditExpiryWorker" do
    test "expires past-due grants and deducts remaining balance from wallet" do
      user = register_user("ledger-expiry")
      past = DateTime.add(DateTime.utc_now(), -60, :second)

      {:ok, _} =
        Ledger.grant_personal_credits(user.id, %{
          amount_mc: 20_000,
          source_type: :subscription,
          expires_at: past
        })

      assert Ledger.fetch_wallet!(user.id).cached_balance_mc == 20_000
      assert :ok = CreditExpiryWorker.perform(%Oban.Job{})

      assert Ledger.fetch_wallet!(user.id).cached_balance_mc == 0

      [grant] =
        CreditGrant
        |> Ash.read!(authorize?: false)
        |> Enum.filter(&(&1.user_id == user.id))

      assert grant.status == :expired
      assert grant.remaining_mc == 0
    end
  end

  describe "expired hold guard" do
    test "rejects a hold when only expired credits remain" do
      user = register_user("ledger-expired-hold")
      past = DateTime.add(DateTime.utc_now(), -60, :second)

      {:ok, _} =
        Ledger.grant_personal_credits(user.id, %{
          amount_mc: 5_000,
          source_type: :subscription,
          expires_at: past
        })

      assert {:error, :insufficient_quota} = Ledger.acquire_hold(user.id, 1_000)

      wallet = Ledger.fetch_wallet!(user.id)
      assert wallet.cached_balance_mc == 0
      assert wallet.held_mc == 0

      [grant] =
        CreditGrant
        |> Ash.read!(authorize?: false)
        |> Enum.filter(&(&1.user_id == user.id))

      assert grant.status == :expired
      assert grant.remaining_mc == 0
    end
  end

  describe "in-flight holds" do
    test "preserves another request's hold when credits expire" do
      user = register_user("ledger-multi-hold-expiry")
      future = DateTime.add(DateTime.utc_now(), 3_600, :second)

      {:ok, _} =
        Ledger.grant_personal_credits(user.id, %{
          amount_mc: 100,
          source_type: :subscription,
          expires_at: future
        })

      {:ok, _} =
        Ledger.grant_personal_credits(user.id, %{amount_mc: 100, source_type: :pack})

      assert {:ok, _hold_a} = Ledger.acquire_hold(user.id, 100)
      assert {:ok, _hold_b} = Ledger.acquire_hold(user.id, 100)

      past = DateTime.add(DateTime.utc_now(), -60, :second)

      Repo.query!(
        """
        UPDATE llm_credit_grants
        SET expires_at = $2
        WHERE user_id = $1 AND source_type = 'subscription' AND status = 'active'
        """,
        [Ecto.UUID.dump!(user.id), past]
      )

      assert {:ok, wallet_a} =
               Ledger.settle_usage(user.id, 100, %{
                 logical_model: "cgc-default",
                 upstream_channel: "deepseek_official_1",
                 upstream_model: "deepseek-chat",
                 billing_mode: :waived_upstream_error,
                 charged_mc: 0,
                 upstream_cost_mc: 0
               })

      assert wallet_a.cached_balance_mc == 200
      assert wallet_a.held_mc == 100

      assert :ok = CreditExpiryWorker.perform(%Oban.Job{})

      wallet = Ledger.fetch_wallet!(user.id)
      assert wallet.cached_balance_mc == 200
      assert wallet.held_mc == 100

      assert {:ok, _hold_c} = Ledger.acquire_hold(user.id, 100)
      assert Ledger.fetch_wallet!(user.id).held_mc == 200

      assert {:ok, wallet_b} =
               Ledger.settle_usage(user.id, 100, %{
                 logical_model: "cgc-default",
                 upstream_channel: "deepseek_official_1",
                 upstream_model: "deepseek-chat",
                 billing_mode: :exact,
                 charged_mc: 100,
                 upstream_cost_mc: 50
               })

      assert wallet_b.cached_balance_mc == 100
      assert wallet_b.held_mc == 100

      assert {:ok, wallet_c} =
               Ledger.settle_usage(user.id, 100, %{
                 logical_model: "cgc-default",
                 upstream_channel: "deepseek_official_1",
                 upstream_model: "deepseek-chat",
                 billing_mode: :exact,
                 charged_mc: 100,
                 upstream_cost_mc: 50
               })

      assert wallet_c.cached_balance_mc == 0
      assert wallet_c.held_mc == 0
    end

    test "limits expired credit consumption to the reserved hold" do
      user = register_user("ledger-expired-budget")
      future = DateTime.add(DateTime.utc_now(), 3_600, :second)

      {:ok, _} =
        Ledger.grant_personal_credits(user.id, %{
          amount_mc: 100,
          source_type: :subscription,
          expires_at: future
        })

      assert {:ok, _} = Ledger.acquire_hold(user.id, 10)

      past = DateTime.add(DateTime.utc_now(), -60, :second)

      Repo.query!(
        "UPDATE llm_credit_grants SET expires_at = $2 WHERE user_id = $1 AND status = 'active'",
        [Ecto.UUID.dump!(user.id), past]
      )

      assert {:ok, wallet} =
               Ledger.settle_usage(user.id, 10, %{
                 logical_model: "cgc-default",
                 upstream_channel: "deepseek_official_1",
                 upstream_model: "deepseek-chat",
                 billing_mode: :exact,
                 charged_mc: 100,
                 upstream_cost_mc: 50
               })

      assert wallet.cached_balance_mc == 90
      assert wallet.held_mc == 0

      [log] =
        UsageLog
        |> Ash.read!(authorize?: false)
        |> Enum.filter(&(&1.user_id == user.id))

      assert log.charged_mc == 10

      [grant] =
        CreditGrant
        |> Ash.read!(authorize?: false)
        |> Enum.filter(&(&1.user_id == user.id))

      assert grant.remaining_mc == 90
      assert grant.status == :active
    end
  end
end
