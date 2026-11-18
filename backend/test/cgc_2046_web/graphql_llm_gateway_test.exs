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

  defp graphql(query, token \\ nil) do
    conn = build_conn() |> put_req_header("content-type", "application/json")
    conn = if token, do: put_req_header(conn, "authorization", "Bearer #{token}"), else: conn

    conn |> post("/api/graphql", %{"query" => query}) |> json_response(200)
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
