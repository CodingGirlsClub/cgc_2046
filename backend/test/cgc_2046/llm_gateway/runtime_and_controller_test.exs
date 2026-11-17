defmodule Cgc2046.LlmGateway.RuntimeAndControllerTest do
  use Cgc2046Web.ConnCase, async: false

  import Cgc2046.AccountsFixtures

  alias Cgc2046.LlmGateway.AffinityRouter
  alias Cgc2046.LlmGateway.LeaseManager
  alias Cgc2046.LlmGateway.Ledger
  alias Cgc2046.LlmGateway.TokenizerAndPricing
  alias Cgc2046.Mcp.Token, as: McpToken
  alias Cgc2046Web.LlmGatewayController

  setup do
    previous_channels = Application.get_env(:cgc_2046, :llm_gateway_channels)

    test_channels = [
      %{
        id: "ds_primary_1",
        provider: :deepseek,
        base_url: "https://api.deepseek.com",
        api_key: "sk-test-primary-1",
        chat_path: "/chat/completions",
        models: %{
          "cgc-default" => "deepseek-chat",
          "cgc-reasoning" => "deepseek-reasoner",
          "cgc-background" => "deepseek-chat"
        }
      },
      %{
        id: "ds_primary_2",
        provider: :deepseek,
        base_url: "https://api.deepseek.com",
        api_key: "sk-test-primary-2",
        chat_path: "/chat/completions",
        models: %{
          "cgc-default" => "deepseek-chat",
          "cgc-reasoning" => "deepseek-reasoner",
          "cgc-background" => "deepseek-chat"
        }
      },
      %{
        id: "volcengine_backup",
        provider: :volcengine,
        base_url: "https://ark.cn-beijing.volces.com/api/v3",
        api_key: "ark-test-backup",
        chat_path: "/chat/completions",
        models: %{
          "cgc-default" => "ep-v3-backup",
          "cgc-reasoning" => "ep-r1-backup",
          "cgc-background" => "ep-v3-backup"
        }
      }
    ]

    Application.put_env(:cgc_2046, :llm_gateway_channels, test_channels)
    AffinityRouter.setup!()
    :fuse.reset(:llm_fuse_ds_primary_1)
    :fuse.reset(:llm_fuse_ds_primary_2)
    :fuse.reset(:llm_fuse_volcengine_backup)

    on_exit(fn ->
      if previous_channels do
        Application.put_env(:cgc_2046, :llm_gateway_channels, previous_channels)
      else
        Application.delete_env(:cgc_2046, :llm_gateway_channels)
      end
    end)

    :ok
  end

  describe "AffinityRouter & :fuse circuit breaker" do
    test "sticks same session_id to the same primary and fails over when the fuse blows" do
      user_id = Ecto.UUID.generate()
      session_id = "sess-sticky-001"

      [first_choice | _] = AffinityRouter.candidate_channels(user_id, session_id)
      assert first_choice.id in ["ds_primary_1", "ds_primary_2"]

      for _ <- 1..10 do
        [choice | _] = AffinityRouter.candidate_channels(user_id, session_id)
        assert choice.id == first_choice.id
      end

      for _ <- 1..4 do
        AffinityRouter.report_failure(first_choice.id)
      end

      refute AffinityRouter.channel_healthy?(first_choice.id)

      [failover_choice | _] = AffinityRouter.candidate_channels(user_id, session_id)
      assert failover_choice.id != first_choice.id
      assert AffinityRouter.channel_healthy?(failover_choice.id)
    end

    test "sanitizes cgc-reasoning sampling params and caps cgc-background max_tokens" do
      [channel | _] = AffinityRouter.configured_channels()

      {logical, physical, cleaned} =
        AffinityRouter.prepare_upstream_payload(
          %{
            "model" => "cgc-reasoning",
            "temperature" => 0.7,
            "top_p" => 0.9,
            "messages" => [%{"role" => "user", "content" => "Solve this"}]
          },
          channel
        )

      assert logical == "cgc-reasoning"
      assert physical == "deepseek-reasoner"
      refute Map.has_key?(cleaned, "temperature")
      refute Map.has_key?(cleaned, "top_p")
      assert cleaned["stream"] == true
      assert cleaned["stream_options"] == %{"include_usage" => true}

      {_, _, bg_cleaned} =
        AffinityRouter.prepare_upstream_payload(
          %{
            "model" => "cgc-background",
            "max_tokens" => 8192,
            "messages" => [%{"role" => "user", "content" => "Summarize"}]
          },
          channel
        )

      assert bg_cleaned["max_tokens"] == 1024
    end
  end

  describe "TokenizerAndPricing exact vs abort billing" do
    test "uses official usage for exact billing and Tiktoken estimate when usage is nil" do
      sse_chunk = """
      data: {"choices":[{"delta":{"reasoning_content":"先思考一下架构。"}}]}

      data: {"choices":[{"delta":{"content":"这是最终的 Elixir 代码实现。"}}]}

      """

      {content_iodata, reasoning_iodata, nil} =
        LlmGatewayController.parse_sse_metrics(sse_chunk)

      abort_settlement =
        TokenizerAndPricing.calculate_settlement("deepseek-chat", 1000, %{
          official_usage: nil,
          output_iodata: content_iodata,
          reasoning_iodata: reasoning_iodata,
          upstream_error?: false
        })

      assert abort_settlement.billing_mode == :estimated_abort
      assert abort_settlement.prompt_cache_miss_tokens == 1000
      assert abort_settlement.completion_tokens > 0
      assert abort_settlement.reasoning_tokens > 0
      assert abort_settlement.charged_mc > abort_settlement.upstream_cost_mc

      exact_settlement =
        TokenizerAndPricing.calculate_settlement("deepseek-chat", 10_000, %{
          official_usage: %{
            "prompt_tokens" => 10_000,
            "prompt_cache_hit_tokens" => 9_000,
            "prompt_cache_miss_tokens" => 1_000,
            "completion_tokens" => 500
          },
          output_iodata: content_iodata,
          reasoning_iodata: reasoning_iodata
        })

      assert exact_settlement.billing_mode == :exact
      assert exact_settlement.prompt_cache_hit_tokens == 9_000
      assert exact_settlement.prompt_cache_miss_tokens == 1_000
      assert exact_settlement.completion_tokens == 500
      assert exact_settlement.upstream_cost_mc == 5_300
      assert exact_settlement.charged_mc > exact_settlement.upstream_cost_mc
    end
  end

  describe "LeaseManager & /v1/chat/completions pre-flight guards" do
    test "returns 402 when the wallet has zero credits" do
      user = register_user("gateway-zero")
      {:ok, _record, raw_token} = McpToken.issue("gateway-test", user, :terminal)

      conn =
        build_conn()
        |> put_req_header("authorization", "Bearer #{raw_token}")
        |> put_req_header("content-type", "application/json")
        |> put_req_header("accept", "text/event-stream")
        |> post("/v1/chat/completions", %{
          "model" => "cgc-default",
          "messages" => [%{"role" => "user", "content" => "Hello DeepSeek"}]
        })

      assert %{"error" => %{"code" => "insufficient_quota"}} = json_response(conn, 402)
    end

    test "returns 429 when concurrent stream slots are exhausted" do
      user = register_user("gateway-concurrent")
      {:ok, _record, raw_token} = McpToken.issue("gateway-test", user, :terminal)

      {:ok, _} =
        Ledger.grant_personal_credits(user.id, %{amount_mc: 500_000, source_type: :pack})

      assert :ok = LeaseManager.acquire_slot(user.id, 3)
      assert :ok = LeaseManager.acquire_slot(user.id, 3)
      assert :ok = LeaseManager.acquire_slot(user.id, 3)

      conn =
        build_conn()
        |> put_req_header("authorization", "Bearer #{raw_token}")
        |> put_req_header("content-type", "application/json")
        |> put_req_header("accept", "application/json")
        |> post("/v1/chat/completions", %{
          "model" => "cgc-default",
          "messages" => [%{"role" => "user", "content" => "Hello"}]
        })

      assert %{"error" => %{"code" => "concurrency_limit_exceeded"}} =
               json_response(conn, 429)

      LeaseManager.release_slot(user.id)
      assert LeaseManager.active_streams_count(user.id) == 0
    end
  end
end
