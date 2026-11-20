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

  test "myLlmUsageLogs: 仅返回当前用户记录、支持 limit 与 before 游标，且不暴露上游渠道与成本" do
    user = Fixtures.register_user("llm-usage-owner")
    other = Fixtures.register_user("llm-usage-other")
    token = sign_in_token(user)
    wallet = Ledger.ensure_wallet!(user.id)
    other_wallet = Ledger.ensure_wallet!(other.id)

    now = DateTime.utc_now() |> DateTime.truncate(:second)
    t1 = DateTime.add(now, -300, :second)
    t2 = DateTime.add(now, -200, :second)
    t3 = DateTime.add(now, -100, :second)

    id1 =
      insert_usage_log!(wallet.id, user.id, %{session_id: "s1", charged_mc: 100, inserted_at: t1})

    id2 =
      insert_usage_log!(wallet.id, user.id, %{session_id: "s2", charged_mc: 200, inserted_at: t2})

    id3 =
      insert_usage_log!(wallet.id, user.id, %{session_id: "s3", charged_mc: 300, inserted_at: t3})

    _other_id =
      insert_usage_log!(other_wallet.id, other.id, %{
        session_id: "other",
        charged_mc: 999,
        inserted_at: now
      })

    # 未登录 unauthorized
    assert %{"errors" => [%{"code" => "unauthorized"}]} = graphql(usage_logs_query())

    # 第一页 limit: 2 -> [id3, id2]
    assert %{
             "myLlmUsageLogs" => [
               %{
                 "id" => ^id3,
                 "sessionId" => "s3",
                 "logicalModel" => "cgc-default",
                 "billingMode" => "exact",
                 "chargedMc" => 300,
                 "insertedAt" => inserted_at_3
               },
               %{
                 "id" => ^id2,
                 "sessionId" => "s2",
                 "chargedMc" => 200,
                 "insertedAt" => inserted_at_2
               }
             ]
           } = data!(graphql(usage_logs_query(), token, %{"limit" => 2}))

    assert is_binary(inserted_at_3) and is_binary(inserted_at_2)

    # 游标翻页 before: inserted_at_2 -> [id1]
    assert %{"myLlmUsageLogs" => [%{"id" => ^id1, "sessionId" => "s1", "chargedMc" => 100}]} =
             data!(graphql(usage_logs_query(), token, %{"limit" => 2, "before" => inserted_at_2}))

    # schema 层面不暴露 upstreamChannel / upstreamCostMc
    assert %{"errors" => [_ | _]} =
             graphql(
               """
               query {
                 myLlmUsageLogs {
                   id
                   upstreamChannel
                   upstreamCostMc
                 }
               }
               """,
               token
             )
  end

  test "adminLlmUsageAnalytics: 仅 PlatformAdmin 可读，按 UTC 日期与渠道准确聚合指标与毛利" do
    member = Fixtures.register_user("llm-analytics-member")
    admin = Fixtures.platform_admin("llm-analytics-admin")
    wallet = Ledger.ensure_wallet!(member.id)

    now = DateTime.utc_now() |> DateTime.truncate(:second)
    today = DateTime.to_date(now) |> Date.to_iso8601()
    yesterday_dt = DateTime.add(now, -86_400, :second)
    yesterday = DateTime.to_date(yesterday_dt) |> Date.to_iso8601()
    old_dt = DateTime.add(now, -20 * 86_400, :second)

    # 未登录 unauthorized / 普通成员 forbidden
    assert %{"errors" => [%{"code" => "unauthorized"}]} = graphql(analytics_query())

    assert %{"errors" => [%{"code" => "forbidden"}]} =
             graphql(analytics_query(), sign_in_token(member))

    insert_usage_log!(wallet.id, member.id, %{
      upstream_channel: "deepseek_official_1",
      billing_mode: "exact",
      prompt_cache_hit_tokens: 1_000,
      prompt_cache_miss_tokens: 500,
      completion_tokens: 200,
      charged_mc: 3_000_000_000,
      upstream_cost_mc: 2_000_000_000,
      inserted_at: now
    })

    insert_usage_log!(wallet.id, member.id, %{
      upstream_channel: "deepseek_official_1",
      billing_mode: "estimated_abort",
      prompt_cache_hit_tokens: 0,
      prompt_cache_miss_tokens: 300,
      completion_tokens: 50,
      charged_mc: 500,
      upstream_cost_mc: 300,
      inserted_at: now
    })

    insert_usage_log!(wallet.id, member.id, %{
      upstream_channel: "volcengine_ark_backup",
      billing_mode: "waived_upstream_error",
      prompt_cache_hit_tokens: 0,
      prompt_cache_miss_tokens: 100,
      completion_tokens: 0,
      charged_mc: 0,
      upstream_cost_mc: 0,
      inserted_at: yesterday_dt
    })

    # 超出 days: 7 窗口，应被排除
    insert_usage_log!(wallet.id, member.id, %{
      upstream_channel: "deepseek_official_1",
      billing_mode: "exact",
      charged_mc: 999_999,
      upstream_cost_mc: 111_111,
      inserted_at: old_dt
    })

    assert %{"adminLlmUsageAnalytics" => rows} =
             data!(graphql(analytics_query(), sign_in_token(admin), %{"days" => 7}))

    assert [
             %{
               "day" => ^today,
               "upstreamChannel" => "deepseek_official_1",
               "requestCount" => 2,
               "abortedCount" => 1,
               "waivedCount" => 0,
               "cacheHitTokens" => 1_000,
               "cacheMissTokens" => 800,
               "completionTokens" => 250,
               "totalChargedMc" => 3_000_000_500,
               "totalUpstreamCostMc" => 2_000_000_300,
               "grossMarginMc" => 1_000_000_200
             },
             %{
               "day" => ^yesterday,
               "upstreamChannel" => "volcengine_ark_backup",
               "requestCount" => 1,
               "abortedCount" => 0,
               "waivedCount" => 1,
               "cacheHitTokens" => 0,
               "cacheMissTokens" => 100,
               "completionTokens" => 0,
               "totalChargedMc" => 0,
               "totalUpstreamCostMc" => 0,
               "grossMarginMc" => 0
             }
           ] = rows
  end

  test "distributeWorkspaceLlmCredits 支持 targetUserIds/targetRoles 并通过 workspaceLlmPool.recentPoolEntries 暴露账本" do
    %{owner: owner, workspace: workspace, member: member} =
      Fixtures.workspace_with_member(member_roles: [:learner])

    outsider = Fixtures.register_user("gql-target-outsider")
    admin = Fixtures.platform_admin("gql-pool-entries-admin")

    admin_token = sign_in_token(admin)
    owner_token = sign_in_token(owner)
    member_token = sign_in_token(member)

    assert %{"adminTopupWorkspaceLlmPool" => %{"creditPoolMc" => 100_000_000}} =
             data!(
               graphql(
                 """
                 mutation {
                   adminTopupWorkspaceLlmPool(
                     workspaceId: "#{workspace.id}",
                     amountMc: 100000000
                   ) {
                     creditPoolMc
                   }
                 }
                 """,
                 admin_token
               )
             )

    # 非成员 targetUserIds 返回 invalid_target_members
    assert %{"errors" => [%{"code" => "invalid_target_members"}]} =
             graphql(
               """
               mutation DistributeTargeted($wsId: ID!, $ids: [ID!], $roles: [String!], $key: String!) {
                 distributeWorkspaceLlmCredits(
                   workspaceId: $wsId,
                   perMemberMc: 10000000,
                   idempotencyKey: $key,
                   targetUserIds: $ids,
                   targetRoles: $roles
                 ) {
                   id
                   memberCount
                   totalGrantedMc
                 }
               }
               """,
               owner_token,
               %{
                 "wsId" => workspace.id,
                 "ids" => [outsider.id],
                 "roles" => nil,
                 "key" => "gql-target-bad"
               }
             )

    # 按角色仅派发给 learner（1 人）
    assert %{
             "distributeWorkspaceLlmCredits" => %{
               "id" => batch_id,
               "memberCount" => 1,
               "totalGrantedMc" => 10_000_000
             }
           } =
             data!(
               graphql(
                 """
                 mutation DistributeByRole($wsId: ID!, $roles: [String!], $key: String!) {
                   distributeWorkspaceLlmCredits(
                     workspaceId: $wsId,
                     perMemberMc: 10000000,
                     idempotencyKey: $key,
                     targetRoles: $roles
                   ) {
                     id
                     memberCount
                     totalGrantedMc
                   }
                 }
                 """,
                 owner_token,
                 %{"wsId" => workspace.id, "roles" => ["learner"], "key" => "gql-role-learner"}
               )
             )

    assert %{"myLlmWallet" => %{"cachedBalanceMc" => 10_000_000}} =
             data!(graphql(wallet_query(), member_token))

    assert %{"myLlmWallet" => %{"cachedBalanceMc" => 0}} =
             data!(graphql(wallet_query(), owner_token))

    assert %{
             "workspaceLlmPool" => %{
               "creditPoolMc" => 90_000_000,
               "recentPoolEntries" => entries
             }
           } =
             data!(
               graphql(
                 """
                 query {
                   workspaceLlmPool(workspaceId: "#{workspace.id}") {
                     creditPoolMc
                     recentPoolEntries {
                       id
                       entryType
                       deltaMc
                       paymentOrderId
                       workspaceBatchId
                       actorUserId
                       insertedAt
                     }
                   }
                 }
                 """,
                 owner_token
               )
             )

    assert length(entries) == 2

    by_type = Map.new(entries, &{&1["entryType"], &1})
    assert by_type["admin_topup"]["deltaMc"] == 100_000_000
    assert by_type["admin_topup"]["actorUserId"] == admin.id
    assert by_type["batch_grant_debit"]["deltaMc"] == -10_000_000
    assert by_type["batch_grant_debit"]["workspaceBatchId"] == batch_id
    assert by_type["batch_grant_debit"]["actorUserId"] == owner.id
  end

  test "adminUpdateUserLlmWalletStatus & adminUpdateUserLlmConcurrency: 仅 PlatformAdmin 可用并写 AdminActionLog" do
    user = Fixtures.register_user("gql-risk-target")
    admin = Fixtures.platform_admin("gql-risk-admin")
    user_token = sign_in_token(user)
    admin_token = sign_in_token(admin)

    status_mutation = """
    mutation UpdateStatus($userId: ID!, $status: String!, $frozenReason: String) {
      adminUpdateUserLlmWalletStatus(
        userId: $userId,
        status: $status,
        frozenReason: $frozenReason
      ) {
        status
        frozenReason
        maxConcurrentStreams
      }
    }
    """

    concurrency_mutation = """
    mutation UpdateConcurrency($userId: ID!, $maxConcurrentStreams: Int!) {
      adminUpdateUserLlmConcurrency(
        userId: $userId,
        maxConcurrentStreams: $maxConcurrentStreams
      ) {
        status
        frozenReason
        maxConcurrentStreams
      }
    }
    """

    # 非管理员被拒
    assert %{"errors" => [%{"code" => "forbidden"}]} =
             graphql(status_mutation, user_token, %{
               "userId" => user.id,
               "status" => "frozen",
               "frozenReason" => "test"
             })

    assert %{"errors" => [%{"code" => "forbidden"}]} =
             graphql(concurrency_mutation, user_token, %{
               "userId" => user.id,
               "maxConcurrentStreams" => 8
             })

    # 管理员冻结账户并附带原因
    assert %{
             "adminUpdateUserLlmWalletStatus" => %{
               "status" => "frozen",
               "frozenReason" => "高频异常请求"
             }
           } =
             data!(
               graphql(status_mutation, admin_token, %{
                 "userId" => user.id,
                 "status" => "frozen",
                 "frozenReason" => "高频异常请求"
               })
             )

    # myLlmWallet 同步暴露 frozenReason
    assert %{"myLlmWallet" => %{"status" => "frozen", "frozenReason" => "高频异常请求"}} =
             data!(
               graphql(
                 "query { myLlmWallet { status frozenReason } }",
                 user_token
               )
             )

    # 管理员调整并发上限
    assert %{
             "adminUpdateUserLlmConcurrency" => %{
               "maxConcurrentStreams" => 8
             }
           } =
             data!(
               graphql(concurrency_mutation, admin_token, %{
                 "userId" => user.id,
                 "maxConcurrentStreams" => 8
               })
             )

    # 超出范围拒绝
    assert %{"errors" => [%{"code" => "invalid_concurrency_limit"}]} =
             graphql(concurrency_mutation, admin_token, %{
               "userId" => user.id,
               "maxConcurrentStreams" => 99
             })

    # 解冻后清空 frozenReason
    assert %{
             "adminUpdateUserLlmWalletStatus" => %{
               "status" => "active",
               "frozenReason" => nil
             }
           } =
             data!(
               graphql(status_mutation, admin_token, %{
                 "userId" => user.id,
                 "status" => "active"
               })
             )

    logs =
      Cgc2046.Accounts.AdminActionLog
      |> Ash.read!(authorize?: false)
      |> Enum.filter(&(&1.target_id == user.id))
      |> Enum.map(& &1.action)

    assert :llm_wallet_status_update in logs
    assert :llm_wallet_concurrency_update in logs
  end

  test "workspaceLlmPool 聚合派发批次消耗率与汇总余额（不泄露单成员明细）" do
    %{owner: owner, workspace: workspace, member: member} =
      Fixtures.workspace_with_member(member_roles: [:learner])

    owner_token = sign_in_token(owner)
    assert {:ok, 50_000_000} = Ledger.topup_workspace_pool(workspace.id, 50_000_000)

    assert {:ok, batch} =
             Ledger.batch_grant_workspace_members(
               owner,
               workspace.id,
               10_000_000,
               "batch-usage-analytics-1"
             )

    # 成员消耗 3,000,000 mc（¥3.00）
    {:ok, hold} = Ledger.acquire_hold(member.id, 3_000_000)

    {:ok, _} =
      Ledger.settle_usage(
        member.id,
        3_000_000,
        %{
          logical_model: "cgc-default",
          upstream_channel: "deepseek_official_1",
          upstream_model: "deepseek-chat",
          billing_mode: :exact,
          charged_mc: 3_000_000,
          upstream_cost_mc: 1_500_000
        },
        hold_id: hold.hold_id
      )

    assert %{
             "workspaceLlmPool" => %{
               "distributedTotalMc" => 20_000_000,
               "distributedConsumedMc" => 3_000_000,
               "distributedRemainingMc" => 17_000_000,
               "recentBatches" => [
                 %{
                   "id" => batch_id,
                   "totalGrantedMc" => 20_000_000,
                   "consumedMc" => 3_000_000,
                   "remainingMc" => 17_000_000,
                   "expiredMc" => 0
                 }
               ]
             }
           } =
             data!(
               graphql(
                 """
                 query {
                   workspaceLlmPool(workspaceId: "#{workspace.id}") {
                     distributedTotalMc
                     distributedConsumedMc
                     distributedRemainingMc
                     recentBatches {
                       id
                       totalGrantedMc
                       consumedMc
                       remainingMc
                       expiredMc
                     }
                   }
                 }
                 """,
                 owner_token
               )
             )

    assert batch_id == batch.batch_id
  end

  test "workspaceLlmPool 在部分消耗的派发批次过期并被 CreditExpiryWorker 清理后仍保留历史 consumedMc" do
    %{owner: owner, workspace: workspace, member: member} =
      Fixtures.workspace_with_member(member_roles: [:learner])

    owner_token = sign_in_token(owner)
    assert {:ok, 50_000_000} = Ledger.topup_workspace_pool(workspace.id, 50_000_000)

    future = DateTime.add(DateTime.utc_now(), 3_600, :second)

    assert {:ok, batch} =
             Ledger.batch_grant_workspace_members(
               owner,
               workspace.id,
               10_000_000,
               "batch-expire-preserve-consumed",
               expires_at: future
             )

    # 仅 member 消耗 ¥3.00（3,000,000 mc）
    {:ok, hold} = Ledger.acquire_hold(member.id, 3_000_000)

    {:ok, _} =
      Ledger.settle_usage(
        member.id,
        3_000_000,
        %{
          logical_model: "cgc-default",
          upstream_channel: "deepseek_official_1",
          upstream_model: "deepseek-chat",
          billing_mode: :exact,
          charged_mc: 3_000_000,
          upstream_cost_mc: 1_500_000
        },
        hold_id: hold.hold_id
      )

    # 模拟批次过期并运行 CreditExpiryWorker
    expired_at = DateTime.add(DateTime.utc_now(), -60, :second)

    Cgc2046.Repo.query!(
      "UPDATE llm_credit_grants SET expires_at = $2 WHERE workspace_batch_id = $1",
      [Ecto.UUID.dump!(batch.batch_id), expired_at]
    )

    assert :ok = Cgc2046.LlmGateway.Workers.CreditExpiryWorker.perform(%Oban.Job{})

    # 总派发 ¥20.00（2人 × ¥10），其中已消耗 ¥3.00、已过期 ¥17.00、剩余 0
    assert %{
             "workspaceLlmPool" => %{
               "distributedTotalMc" => 20_000_000,
               "distributedConsumedMc" => 3_000_000,
               "distributedRemainingMc" => 0,
               "recentBatches" => [
                 %{
                   "id" => batch_id,
                   "totalGrantedMc" => 20_000_000,
                   "consumedMc" => 3_000_000,
                   "remainingMc" => 0,
                   "expiredMc" => 17_000_000
                 }
               ]
             }
           } =
             data!(
               graphql(
                 """
                 query {
                   workspaceLlmPool(workspaceId: "#{workspace.id}") {
                     distributedTotalMc
                     distributedConsumedMc
                     distributedRemainingMc
                     recentBatches {
                       id
                       totalGrantedMc
                       consumedMc
                       remainingMc
                       expiredMc
                     }
                   }
                 }
                 """,
                 owner_token
               )
             )

    assert batch_id == batch.batch_id
  end

  defp insert_usage_log!(wallet_id, user_id, attrs) do
    id = Ecto.UUID.generate()

    Cgc2046.Repo.query!(
      """
      INSERT INTO llm_usage_logs (
        id, wallet_id, user_id, session_id, logical_model,
        upstream_channel, upstream_model, billing_mode,
        prompt_cache_hit_tokens, prompt_cache_miss_tokens,
        completion_tokens, reasoning_tokens,
        charged_mc, upstream_cost_mc, ttfb_ms, duration_ms, inserted_at
      )
      VALUES (
        $1, $2, $3, $4, $5,
        $6, $7, $8,
        $9, $10,
        $11, $12,
        $13, $14, $15, $16, $17
      )
      """,
      [
        Ecto.UUID.dump!(id),
        Ecto.UUID.dump!(wallet_id),
        Ecto.UUID.dump!(user_id),
        Map.get(attrs, :session_id),
        Map.get(attrs, :logical_model, "cgc-default"),
        Map.get(attrs, :upstream_channel, "deepseek_official_1"),
        Map.get(attrs, :upstream_model, "deepseek-chat"),
        Map.get(attrs, :billing_mode, "exact"),
        Map.get(attrs, :prompt_cache_hit_tokens, 0),
        Map.get(attrs, :prompt_cache_miss_tokens, 0),
        Map.get(attrs, :completion_tokens, 0),
        Map.get(attrs, :reasoning_tokens, 0),
        Map.get(attrs, :charged_mc, 0),
        Map.get(attrs, :upstream_cost_mc, 0),
        Map.get(attrs, :ttfb_ms, 120),
        Map.get(attrs, :duration_ms, 450),
        Map.get(attrs, :inserted_at, DateTime.utc_now())
      ]
    )

    id
  end

  defp usage_logs_query do
    """
    query MyLlmUsageLogs($limit: Int, $before: DateTime) {
      myLlmUsageLogs(limit: $limit, before: $before) {
        id
        sessionId
        logicalModel
        billingMode
        promptCacheHitTokens
        promptCacheMissTokens
        completionTokens
        reasoningTokens
        chargedMc
        ttfbMs
        durationMs
        insertedAt
      }
    }
    """
  end

  defp analytics_query do
    """
    query AdminLlmUsageAnalytics($days: Int) {
      adminLlmUsageAnalytics(days: $days) {
        day
        upstreamChannel
        requestCount
        abortedCount
        waivedCount
        cacheHitTokens
        cacheMissTokens
        completionTokens
        totalChargedMc
        totalUpstreamCostMc
        grossMarginMc
      }
    }
    """
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
          expiresAt
          status
          insertedAt
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
        updatedAt
        recentBatches { id perMemberMc memberCount totalGrantedMc expiresAt idempotencyKey insertedAt }
        recentPoolEntries { id entryType deltaMc paymentOrderId workspaceBatchId actorUserId insertedAt }
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
