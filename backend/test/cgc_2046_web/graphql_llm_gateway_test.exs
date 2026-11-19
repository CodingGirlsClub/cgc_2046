defmodule Cgc2046Web.GraphqlLlmGatewayTest do
  @moduledoc """
  Phase 3A GraphQL 面：个人钱包读、工作台池读/派发、PlatformAdmin 充值与
  个人赠予；同时验证金额写操作自动落 AdminActionLog。
  """

  use Cgc2046Web.ConnCase, async: true

  require Ash.Query

  alias Cgc2046.Accounts.AdminActionLog
  alias Cgc2046.AccountsFixtures, as: Fixtures
  alias Cgc2046.LlmGateway.Ledger

  @password Fixtures.password()

  defp sign_in_token(user) do
    query = """
    mutation {
      signIn(login: "#{user.email}", password: "#{@password}") {
        id
      }
    }
    """

    conn =
      build_conn()
      |> put_req_header("content-type", "application/json")
      |> post("/api/graphql", %{"query" => query})

    assert %{"data" => %{"signIn" => %{"id" => _id}}} = json_response(conn, 200)
    conn.resp_cookies["cgc_token"].value
  end

  defp graphql(query, token \\ nil, variables \\ nil) do
    conn = build_conn() |> put_req_header("content-type", "application/json")
    conn = if token, do: put_req_header(conn, "authorization", "Bearer #{token}"), else: conn

    payload =
      if variables, do: %{"query" => query, "variables" => variables}, else: %{"query" => query}

    conn |> post("/api/graphql", payload) |> json_response(200)
  end

  defp data!(body) do
    assert %{"data" => data} = body
    data
  end

  test "myLlmWallet: 钱包、活跃授信与可用额度；未登录 unauthorized" do
    user = Fixtures.register_user("llm-wallet")
    token = sign_in_token(user)

    {:ok, _wallet} =
      Ledger.grant_personal_credits(user.id, %{
        amount_mc: 10_000_000,
        source_type: :pack,
        expires_at: DateTime.add(DateTime.utc_now(), 86_400, :second)
      })

    assert %{
             "myLlmWallet" => %{
               "walletId" => wallet_id,
               "cachedBalanceMc" => 10_000_000,
               "heldMc" => 0,
               "availableMc" => 10_000_000,
               "maxConcurrentStreams" => 3,
               "status" => "active",
               "remainingPercentage" => 100,
               "activeGrants" => [grant]
             }
           } = data!(graphql(wallet_query(), token))

    assert is_binary(wallet_id)

    assert %{"sourceType" => "pack", "initialMc" => 10_000_000, "remainingMc" => 10_000_000} =
             grant

    assert %{"errors" => [%{"code" => "unauthorized"}]} = graphql(wallet_query())
  end

  test "workspaceLlmPool: Owner 与 PlatformAdmin 可读，普通成员 forbidden" do
    %{owner: owner, workspace: workspace, member: member} = Fixtures.workspace_with_member()
    {:ok, 50_000_000} = Ledger.topup_workspace_pool(workspace.id, 50_000_000)

    assert %{
             "workspaceLlmPool" => %{
               "workspaceId" => workspace_id,
               "creditPoolMc" => 50_000_000,
               "recentBatches" => []
             }
           } = data!(graphql(workspace_pool_query(workspace.id), sign_in_token(owner)))

    assert workspace_id == workspace.id

    assert %{"errors" => [%{"code" => "forbidden"}]} =
             graphql(workspace_pool_query(workspace.id), sign_in_token(member))

    admin = Fixtures.platform_admin("llm-pool-admin")

    assert %{"workspaceLlmPool" => %{"creditPoolMc" => 50_000_000}} =
             data!(graphql(workspace_pool_query(workspace.id), sign_in_token(admin)))
  end

  test "distributeWorkspaceLlmCredits: 扣池、入成员钱包、同 key 幂等、普通成员 forbidden" do
    %{owner: owner, workspace: workspace, member: member} = Fixtures.workspace_with_member()
    {:ok, 50_000_000} = Ledger.topup_workspace_pool(workspace.id, 50_000_000)

    owner_token = sign_in_token(owner)

    assert %{
             "distributeWorkspaceLlmCredits" => %{
               "id" => batch_id,
               "perMemberMc" => 15_000_000,
               "memberCount" => 2,
               "totalGrantedMc" => 30_000_000,
               "idempotentReplay" => false
             }
           } = data!(graphql(distribute_mutation(workspace.id, "batch-001"), owner_token))

    assert is_binary(batch_id)

    assert %{
             "distributeWorkspaceLlmCredits" => %{
               "id" => ^batch_id,
               "idempotentReplay" => true
             }
           } = data!(graphql(distribute_mutation(workspace.id, "batch-001"), owner_token))

    assert %{"workspaceLlmPool" => %{"creditPoolMc" => 20_000_000}} =
             data!(graphql(workspace_pool_query(workspace.id), owner_token))

    member_token = sign_in_token(member)

    assert %{"myLlmWallet" => %{"cachedBalanceMc" => 15_000_000, "activeGrants" => [grant]}} =
             data!(graphql(wallet_query(), member_token))

    assert %{"sourceType" => "workspace_grant", "remainingMc" => 15_000_000} = grant

    assert %{"errors" => [%{"code" => "forbidden"}]} =
             graphql(distribute_mutation(workspace.id, "batch-002"), member_token)
  end

  test "distributeWorkspaceLlmCredits: 算力池不足返回 insufficient_workspace_pool" do
    %{owner: owner, workspace: workspace} = Fixtures.workspace_with_member()
    owner_token = sign_in_token(owner)

    assert %{"errors" => [%{"code" => "insufficient_workspace_pool"}]} =
             graphql(distribute_mutation(workspace.id, "batch-empty"), owner_token)
  end

  test "adminTopupWorkspaceLlmPool: 充值并与 AdminActionLog 同事务" do
    %{workspace: workspace} = Fixtures.workspace_with_member()
    admin = Fixtures.platform_admin("llm-topup-admin")
    token = sign_in_token(admin)

    assert %{"adminTopupWorkspaceLlmPool" => %{"creditPoolMc" => 50_000_000}} =
             data!(
               graphql(
                 """
                 mutation {
                   adminTopupWorkspaceLlmPool(
                     workspaceId: "#{workspace.id}",
                     amountMc: 50000000
                   ) {
                     workspaceId
                     creditPoolMc
                   }
                 }
                 """,
                 token
               )
             )

    [log] = admin_logs(:llm_workspace_topup)
    assert log.actor_id == admin.id
    assert log.target_type == :workspace
    assert log.target_id == workspace.id
    assert log.metadata["amount_mc"] == 50_000_000
  end

  test "adminGrantUserLlmCredits: 赠予个人钱包并与 AdminActionLog 同事务；未知用户 user_not_found" do
    member = Fixtures.register_user("llm-grant-recipient")
    admin = Fixtures.platform_admin("llm-grant-admin")
    token = sign_in_token(admin)

    assert %{
             "adminGrantUserLlmCredits" => %{
               "cachedBalanceMc" => 10_000_000,
               "activeGrants" => [%{"sourceType" => "admin_gift"}]
             }
           } =
             data!(
               graphql(
                 """
                 mutation {
                   adminGrantUserLlmCredits(userId: "#{member.id}", amountMc: 10000000) {
                     walletId
                     cachedBalanceMc
                     activeGrants { sourceType initialMc remainingMc }
                   }
                 }
                 """,
                 token
               )
             )

    [log] = admin_logs(:llm_user_credit_grant)
    assert log.actor_id == admin.id
    assert log.target_type == :user
    assert log.target_id == member.id
    assert log.metadata["amount_mc"] == 10_000_000

    assert %{"errors" => [%{"code" => "user_not_found"}]} =
             graphql(
               """
               mutation {
                 adminGrantUserLlmCredits(userId: "#{Ecto.UUID.generate()}", amountMc: 1) {
                   walletId
                 }
               }
               """,
               token
             )
  end

  test "myLlmWallet: 排除已过期与零余额活跃授信，并把 availableMc 与 remainingPercentage 收敛到 0..100" do
    user = Fixtures.register_user("llm-wallet-expiry")
    token = sign_in_token(user)
    now = DateTime.utc_now()

    # 1. 已过期但状态仍为 active（过期清理 Worker 尚未跑）
    {:ok, _} =
      Ledger.grant_personal_credits(user.id, %{
        amount_mc: 10_000_000,
        source_type: :subscription,
        expires_at: DateTime.add(now, -3_600, :second)
      })

    # 2. 未过期有效授信
    {:ok, _} =
      Ledger.grant_personal_credits(user.id, %{
        amount_mc: 5_000_000,
        source_type: :pack,
        expires_at: DateTime.add(now, 86_400, :second)
      })

    # 3. remaining_mc = 0 但 status 仍为 active 的残留行（也应被过滤）
    {:ok, _} =
      Ledger.grant_personal_credits(user.id, %{
        amount_mc: 1_000_000,
        source_type: :admin_gift
      })

    wallet = Ledger.fetch_wallet!(user.id)

    Cgc2046.Repo.query!(
      """
      UPDATE llm_credit_grants
      SET remaining_mc = 0
      WHERE wallet_id = $1 AND source_type = 'admin_gift'
      """,
      [Ecto.UUID.dump!(wallet.id)]
    )

    # cached_balance_mc 仍含过期那笔（15M），远超未过期授信 initial_mc（5M）：
    # remainingPercentage 必须严格收敛到 100（不可算出 300），availableMc 仅计未过期 5M
    Cgc2046.Repo.query!(
      "UPDATE llm_wallets SET cached_balance_mc = 15000000, held_mc = 0 WHERE id = $1",
      [Ecto.UUID.dump!(wallet.id)]
    )

    assert %{
             "myLlmWallet" => %{
               "cachedBalanceMc" => 15_000_000,
               "heldMc" => 0,
               "availableMc" => 5_000_000,
               "remainingPercentage" => 100,
               "activeGrants" => [only_unexpired]
             }
           } = data!(graphql(wallet_query(), token))

    assert only_unexpired["sourceType"] == "pack"
    assert only_unexpired["remainingMc"] == 5_000_000

    # 把未过期授信扣成一半剩余（remaining=2.5M）并挂 0.5M hold：
    # availableMc = min(2.5M, 12.5M) - 0.5M = 2.0M，remainingPercentage = 50
    Cgc2046.Repo.query!(
      """
      UPDATE llm_credit_grants
      SET remaining_mc = 2500000
      WHERE wallet_id = $1 AND source_type = 'pack'
      """,
      [Ecto.UUID.dump!(wallet.id)]
    )

    Cgc2046.Repo.query!(
      "UPDATE llm_wallets SET cached_balance_mc = 12500000, held_mc = 500000 WHERE id = $1",
      [Ecto.UUID.dump!(wallet.id)]
    )

    assert %{
             "myLlmWallet" => %{
               "cachedBalanceMc" => 12_500_000,
               "heldMc" => 500_000,
               "availableMc" => 2_000_000,
               "remainingPercentage" => 50,
               "activeGrants" => [%{"sourceType" => "pack", "remainingMc" => 2_500_000}]
             }
           } = data!(graphql(wallet_query(), token))

    # 当未过期授信全部耗尽（只剩过期批次）时，activeGrants 为空且 availableMc / remainingPercentage 归零
    Cgc2046.Repo.query!(
      """
      UPDATE llm_credit_grants
      SET remaining_mc = 0
      WHERE wallet_id = $1 AND source_type = 'pack'
      """,
      [Ecto.UUID.dump!(wallet.id)]
    )

    assert %{
             "myLlmWallet" => %{
               "availableMc" => 0,
               "remainingPercentage" => 0,
               "activeGrants" => []
             }
           } = data!(graphql(wallet_query(), token))
  end

  test "BigInt > 2^31-1 (3_000_000_000 mc) 往返：adminTopupWorkspaceLlmPool 与 distributeWorkspaceLlmCredits" do
    %{owner: owner, workspace: workspace, member: member} = Fixtures.workspace_with_member()
    admin = Fixtures.platform_admin("llm-bigint-admin")
    admin_token = sign_in_token(admin)
    owner_token = sign_in_token(owner)
    member_token = sign_in_token(member)

    topup_mc = 7_000_000_000
    per_member_mc = 3_000_000_000
    total_granted_mc = 6_000_000_000
    remaining_pool_mc = 1_000_000_000

    # 1. 整型字面量 > 2^31-1
    assert %{"adminTopupWorkspaceLlmPool" => %{"creditPoolMc" => ^topup_mc}} =
             data!(
               graphql(
                 """
                 mutation {
                   adminTopupWorkspaceLlmPool(
                     workspaceId: "#{workspace.id}",
                     amountMc: #{topup_mc}
                   ) {
                     workspaceId
                     creditPoolMc
                   }
                 }
                 """,
                 admin_token
               )
             )

    # 2. 数字字符串入参同样被 BigInt 接受，序列化仍返回 JSON 整数
    assert %{
             "distributeWorkspaceLlmCredits" => %{
               "perMemberMc" => ^per_member_mc,
               "memberCount" => 2,
               "totalGrantedMc" => ^total_granted_mc,
               "idempotentReplay" => false
             }
           } =
             data!(
               graphql(
                 """
                 mutation DistributeBigInt($workspaceId: ID!, $perMemberMc: BigInt!, $key: String!) {
                   distributeWorkspaceLlmCredits(
                     workspaceId: $workspaceId,
                     perMemberMc: $perMemberMc,
                     idempotencyKey: $key
                   ) {
                     id
                     perMemberMc
                     memberCount
                     totalGrantedMc
                     idempotentReplay
                   }
                 }
                 """,
                 owner_token,
                 %{
                   "workspaceId" => workspace.id,
                   "perMemberMc" => Integer.to_string(per_member_mc),
                   "key" => "bigint-batch-001"
                 }
               )
             )

    assert %{"workspaceLlmPool" => %{"creditPoolMc" => ^remaining_pool_mc}} =
             data!(graphql(workspace_pool_query(workspace.id), owner_token))

    assert %{
             "myLlmWallet" => %{
               "cachedBalanceMc" => ^per_member_mc,
               "availableMc" => ^per_member_mc,
               "activeGrants" => [
                 %{"initialMc" => ^per_member_mc, "remainingMc" => ^per_member_mc}
               ]
             }
           } = data!(graphql(wallet_query(), member_token))

    # 3. 超过 signed 64-bit 上限或非数字字符串被 BigInt 标量拒绝
    assert %{"errors" => [_ | _]} =
             graphql(
               """
               mutation {
                 adminTopupWorkspaceLlmPool(
                   workspaceId: "#{workspace.id}",
                   amountMc: "9223372036854775808"
                 ) {
                   creditPoolMc
                 }
               }
               """,
               admin_token
             )

    assert %{"errors" => [_ | _]} =
             graphql(
               """
               mutation {
                 adminTopupWorkspaceLlmPool(
                   workspaceId: "#{workspace.id}",
                   amountMc: "not-a-number"
                 ) {
                   creditPoolMc
                 }
               }
               """,
               admin_token
             )
  end

  test "createLlmPaymentOrder: 个人加油包创单、凭据、同 key 幂等、订单查询" do
    user = Fixtures.register_user("llm-checkout")
    token = sign_in_token(user)
    key = "gql-#{Ecto.UUID.generate()}"

    assert %{
             "createLlmPaymentOrder" => %{
               "order" => %{
                 "id" => order_id,
                 "orderKind" => "llm_credit_pack",
                 "provider" => "wechat_native",
                 "outTradeNo" => out_trade_no,
                 "amountCents" => 1_000,
                 "creditsMc" => 10_000_000,
                 "status" => "pending",
                 "workspaceId" => nil
               },
               "credential" => %{"type" => "jsapi"}
             }
           } =
             data!(
               graphql(create_payment_order_mutation("wechat_native", 1_000, key, nil), token)
             )

    assert String.starts_with?(out_trade_no, "LLM_")

    assert %{"llmPaymentOrder" => %{"id" => ^order_id, "outTradeNo" => ^out_trade_no}} =
             data!(graphql(payment_order_query(order_id), token))

    assert %{
             "createLlmPaymentOrder" => %{
               "order" => %{"id" => ^order_id, "outTradeNo" => ^out_trade_no}
             }
           } =
             data!(
               graphql(create_payment_order_mutation("wechat_native", 1_000, key, nil), token)
             )

    # 同 key 不同金额返回 llm_payment_order_idempotency_conflict
    assert %{"errors" => [%{"code" => "llm_payment_order_idempotency_conflict"}]} =
             graphql(create_payment_order_mutation("wechat_native", 5_000, key, nil), token)

    # 未签约渠道与非法金额档位拒绝
    assert %{"errors" => [%{"code" => "llm_payment_order_invalid_provider"}]} =
             graphql(
               create_payment_order_mutation("alipay_page", 1_000, "gql-bad-prov-#{key}", nil),
               token
             )

    assert %{"errors" => [%{"code" => "llm_payment_order_invalid_amount"}]} =
             graphql(
               create_payment_order_mutation("wechat_native", 1, "gql-bad-amt-#{key}", nil),
               token
             )
  after
    Cgc2046.Payments.Providers.Fake.reset!()
  end

  test "createLlmPaymentOrder: 工作台充值需 Owner/Admin，普通成员 forbidden" do
    %{owner: owner, workspace: workspace, member: member} = Fixtures.workspace_with_member()

    assert %{
             "createLlmPaymentOrder" => %{
               "order" => %{
                 "workspaceId" => workspace_id,
                 "orderKind" => "llm_workspace_pool_topup"
               }
             }
           } =
             data!(
               graphql(
                 create_payment_order_mutation(
                   "alipay_qr",
                   10_000,
                   "gql-pool-#{Ecto.UUID.generate()}",
                   workspace.id
                 ),
                 sign_in_token(owner)
               )
             )

    assert workspace_id == workspace.id

    assert %{"errors" => [%{"code" => "llm_payment_order_forbidden"}]} =
             graphql(
               create_payment_order_mutation(
                 "alipay_qr",
                 10_000,
                 "gql-pool-member-#{Ecto.UUID.generate()}",
                 workspace.id
               ),
               sign_in_token(member)
             )
  after
    Cgc2046.Payments.Providers.Fake.reset!()
  end

  defp create_payment_order_mutation(provider, amount_cents, idempotency_key, workspace_id) do
    order_kind =
      if workspace_id, do: "llm_workspace_pool_topup", else: "llm_credit_pack"

    workspace_arg =
      if workspace_id, do: ~s(workspaceId: "#{workspace_id}",), else: ""

    """
    mutation {
      createLlmPaymentOrder(
        orderKind: "#{order_kind}",
        provider: "#{provider}",
        amountCents: #{amount_cents},
        idempotencyKey: "#{idempotency_key}",
        #{workspace_arg}
      ) {
        order {
          id
          workspaceId
          orderKind
          provider
          outTradeNo
          amountCents
          creditsMc
          status
        }
        credential
      }
    }
    """
  end

  defp payment_order_query(order_id) do
    """
    query {
      llmPaymentOrder(id: "#{order_id}") {
        id
        outTradeNo
        amountCents
        creditsMc
        status
      }
    }
    """
  end

  defp admin_logs(action) do
    AdminActionLog
    |> Ash.Query.filter(action == ^action)
    |> Ash.read!(authorize?: false)
  end

  defp wallet_query do
    """
    query {
      myLlmWallet {
        walletId
        cachedBalanceMc
        heldMc
        availableMc
        maxConcurrentStreams
        status
        remainingPercentage
        activeGrants {
          id
          sourceType
          initialMc
          remainingMc
          status
        }
      }
    }
    """
  end

  defp workspace_pool_query(workspace_id) do
    """
    query {
      workspaceLlmPool(workspaceId: "#{workspace_id}") {
        workspaceId
        creditPoolMc
        recentBatches { id perMemberMc memberCount totalGrantedMc idempotencyKey }
      }
    }
    """
  end

  defp distribute_mutation(workspace_id, idempotency_key) do
    """
    mutation {
      distributeWorkspaceLlmCredits(
        workspaceId: "#{workspace_id}",
        perMemberMc: 15000000,
        idempotencyKey: "#{idempotency_key}"
      ) {
        id
        perMemberMc
        memberCount
        totalGrantedMc
        idempotentReplay
      }
    }
    """
  end
end
