defmodule Cgc2046Web.GraphqlLlmProvidersTest do
  use Cgc2046Web.ConnCase, async: true

  alias Cgc2046.AccountsFixtures, as: Fixtures
  alias Cgc2046.LlmGateway.ProviderCatalog

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

    assert %{"data" => %{"signIn" => %{"id" => _}}} = json_response(conn, 200)
    conn.resp_cookies["cgc_token"].value
  end

  defp graphql(query, token \\ nil, variables \\ nil) do
    conn = build_conn() |> put_req_header("content-type", "application/json")
    conn = if token, do: put_req_header(conn, "authorization", "Bearer #{token}"), else: conn

    payload =
      if variables, do: %{"query" => query, "variables" => variables}, else: %{"query" => query}

    conn |> post("/api/graphql", payload) |> json_response(200)
  end

  test "non-admin cannot access adminLlmProviders or provider mutations; availableLlmModels requires login" do
    user = Fixtures.register_user("llm-user")
    user_token = sign_in_token(user)

    assert %{"errors" => [%{"code" => "unauthorized"}]} =
             graphql("query { availableLlmModels { modelId } }")

    assert %{"data" => %{"availableLlmModels" => []}} =
             graphql("query { availableLlmModels { modelId } }", user_token)

    assert %{"errors" => [%{"code" => "forbidden"}]} =
             graphql("query { adminLlmProviders { id } }", user_token)

    assert %{"errors" => [%{"code" => "forbidden"}]} =
             graphql(
               """
               mutation($input: AdminLlmProviderInput!) {
                 adminCreateLlmProvider(input: $input) { id }
               }
               """,
               user_token,
               %{
                 "input" => %{
                   "name" => "Hack",
                   "slug" => "hack",
                   "protocol" => "openai_compatible",
                   "baseUrl" => "https://api.deepseek.com"
                 }
               }
             )
  end

  test "admin manages providers, API keys, upstream discovery, and models; regular user sees availableLlmModels" do
    admin = Fixtures.platform_admin("llm-gql-admin")
    admin_token = sign_in_token(admin)
    user = Fixtures.register_user("llm-gql-user")
    user_token = sign_in_token(user)

    presets_resp =
      graphql(
        "query { adminLlmPricingPresets { modelId displayName cacheMissPriceMc outputPriceMc } }",
        admin_token
      )

    assert length(presets_resp["data"]["adminLlmPricingPresets"]) > 5

    create_resp =
      graphql(
        """
        mutation($input: AdminLlmProviderInput!) {
          adminCreateLlmProvider(input: $input) {
            id
            name
            slug
            protocol
            baseUrl
            priority
            offPeakDiscountEnabled
            enabled
          }
        }
        """,
        admin_token,
        %{
          "input" => %{
            "name" => "DeepSeek",
            "slug" => "deepseek",
            "protocol" => "openai_compatible",
            "baseUrl" => "https://api.deepseek.com",
            "priority" => 10,
            "offPeakDiscountEnabled" => true,
            "enabled" => true
          }
        }
      )

    provider_id = create_resp["data"]["adminCreateLlmProvider"]["id"]
    assert is_binary(provider_id)

    key_resp =
      graphql(
        """
        mutation($providerId: ID!, $label: String!, $apiKey: String!) {
          adminAddLlmProviderApiKey(providerId: $providerId, label: $label, apiKey: $apiKey) {
            id
            label
            keyPreview
            enabled
          }
        }
        """,
        admin_token,
        %{
          "providerId" => provider_id,
          "label" => "Main Key",
          "apiKey" => "sk-live-deepseek-998877"
        }
      )

    assert key_resp["data"]["adminAddLlmProviderApiKey"]["keyPreview"] == "sk-l...8877"

    save_resp =
      graphql(
        """
        mutation($providerId: ID!, $models: [AdminLlmProviderModelInput!]!) {
          adminSaveLlmProviderModels(providerId: $providerId, models: $models) {
            id
            modelId
            displayName
            enabled
          }
        }
        """,
        admin_token,
        %{
          "providerId" => provider_id,
          "models" => [
            %{
              "modelId" => "deepseek-chat",
              "upstreamModelId" => "deepseek-chat",
              "displayName" => "DeepSeek V3",
              "enabled" => true,
              "contextWindow" => 128_000,
              "maxOutputTokens" => 8_192,
              "supportsThinking" => false,
              "supportsTools" => true,
              "supportsImages" => false,
              "reasoningEfforts" => [],
              "cacheHitPriceMc" => 200_000,
              "cacheMissPriceMc" => 2_000_000,
              "outputPriceMc" => 3_000_000,
              "markupRatio" => 1.5
            }
          ]
        }
      )

    [saved_model] = save_resp["data"]["adminSaveLlmProviderModels"]
    assert saved_model["modelId"] == "deepseek-chat"

    # Regular user queries availableLlmModels and sees marked-up user price without secrets.
    avail_resp =
      graphql(
        """
        query {
          availableLlmModels {
            modelId
            displayName
            contextWindow
            maxOutputTokens
            supportsThinking
            supportsTools
            supportsImages
            reasoningEfforts
            inputPriceMc
            cacheHitPriceMc
            outputPriceMc
          }
        }
        """,
        user_token
      )

    assert [
             %{
               "modelId" => "deepseek-chat",
               "displayName" => "DeepSeek V3",
               "inputPriceMc" => 3_000_000,
               "cacheHitPriceMc" => 300_000,
               "outputPriceMc" => 4_500_000
             }
           ] = avail_resp["data"]["availableLlmModels"]

    # Upstream discovery stubbed through config plug
    prev_plug = Application.get_env(:cgc_2046, :llm_gateway_discovery_req_plug)

    Application.put_env(:cgc_2046, :llm_gateway_discovery_req_plug, fn conn ->
      Req.Test.json(conn, %{"data" => [%{"id" => "deepseek-reasoner"}]})
    end)

    on_exit(fn ->
      if prev_plug,
        do: Application.put_env(:cgc_2046, :llm_gateway_discovery_req_plug, prev_plug),
        else: Application.delete_env(:cgc_2046, :llm_gateway_discovery_req_plug)
    end)

    fetch_resp =
      graphql(
        """
        mutation($providerId: ID!) {
          adminFetchLlmProviderUpstreamModels(providerId: $providerId) {
            modelId
            displayName
            presetMatched
            supportsThinking
          }
        }
        """,
        admin_token,
        %{"providerId" => provider_id}
      )

    assert [
             %{
               "modelId" => "deepseek-reasoner",
               "presetMatched" => true,
               "supportsThinking" => true
             }
           ] = fetch_resp["data"]["adminFetchLlmProviderUpstreamModels"]

    assert %{"data" => %{"adminDeleteLlmProviderModel" => true}} =
             graphql(
               "mutation($id: ID!) { adminDeleteLlmProviderModel(id: $id) }",
               admin_token,
               %{"id" => saved_model["id"]}
             )

    assert ProviderCatalog.list_available_models() == []
  end
end
