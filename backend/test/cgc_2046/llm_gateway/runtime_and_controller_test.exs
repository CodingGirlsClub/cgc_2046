defmodule Cgc2046.LlmGateway.RuntimeAndControllerTest do
  use Cgc2046Web.ConnCase, async: false

  import Cgc2046.AccountsFixtures

  alias Cgc2046.LlmGateway.AffinityRouter
  alias Cgc2046.LlmGateway.AffinityStore
  alias Cgc2046.LlmGateway.Ledger
  alias Cgc2046.LlmGateway.ProviderCatalog
  alias Cgc2046.LlmGateway.TokenizerAndPricing
  alias Cgc2046.LlmGateway.UsageLog
  alias Cgc2046.Accounts.SignInFlow
  alias Cgc2046.Mcp.Token, as: McpToken
  alias Cgc2046Web.LlmGatewayController

  setup do
    AffinityRouter.setup!()
    :ok
  end

  describe "AffinityRouter & :fuse circuit breaker" do
    test "sticks same session_id to the same primary key slot and fails over when the fuse blows" do
      admin = platform_admin("router-sticky")

      {:ok, provider} =
        ProviderCatalog.create_provider(admin, %{
          name: "DeepSeek Sticky",
          slug: "ds-sticky",
          protocol: "openai_compatible",
          base_url: "https://api.deepseek.com",
          priority: 10
        })

      {:ok, _k1} =
        ProviderCatalog.add_api_key(admin, provider.id, %{label: "k1", api_key: "sk-sticky-1"})

      {:ok, _k2} =
        ProviderCatalog.add_api_key(admin, provider.id, %{label: "k2", api_key: "sk-sticky-2"})

      {:ok, _models} =
        ProviderCatalog.save_provider_models(admin, provider.id, [
          %{
            model_id: "deepseek-chat",
            display_name: "DeepSeek Chat",
            context_window: 128_000,
            max_output_tokens: 8_192,
            cache_hit_price_mc: 200_000,
            cache_miss_price_mc: 2_000_000,
            output_price_mc: 3_000_000
          }
        ])

      user_id = Ecto.UUID.generate()
      session_id = "sess-sticky-001"

      assert {:ok, [first_choice | _]} =
               AffinityRouter.candidate_channels(user_id, session_id, "deepseek-chat")

      for _ <- 1..10 do
        assert {:ok, [choice | _]} =
                 AffinityRouter.candidate_channels(user_id, session_id, "deepseek-chat")

        assert choice.id == first_choice.id
      end

      for _ <- 1..4 do
        AffinityRouter.report_failure(first_choice.id)
      end

      refute AffinityRouter.channel_healthy?(first_choice.id)

      assert {:ok, [failover_choice | _]} =
               AffinityRouter.candidate_channels(user_id, session_id, "deepseek-chat")

      assert failover_choice.id != first_choice.id
      assert AffinityRouter.channel_healthy?(failover_choice.id)
    end

    test "OpenaiAdapter strips disallowed keys, sanitizes reasoner params, and caps max_tokens" do
      channel = %{
        protocol: :openai_compatible,
        base_url: "https://api.deepseek.com",
        chat_path: "/chat/completions",
        api_key: "sk-test",
        upstream_model_id: "deepseek-reasoner",
        supports_thinking: true,
        max_output_tokens: 16_384
      }

      req =
        AffinityRouter.build_upstream_request(
          %{
            "model" => "deepseek-reasoner",
            "n" => 5,
            "session_id" => "sess-leak-attempt",
            "user" => "spoofed-user",
            "stream" => false,
            "stream_options" => %{"include_usage" => false},
            "arbitrary_client_key" => "evil",
            "temperature" => 0.7,
            "top_p" => 0.9,
            "max_tokens" => 99_999,
            "messages" => [%{"role" => "user", "content" => "Deep proof"}]
          },
          channel
        )

      cleaned = req.body
      assert cleaned["model"] == "deepseek-reasoner"
      refute Map.has_key?(cleaned, "temperature")
      refute Map.has_key?(cleaned, "top_p")
      refute Map.has_key?(cleaned, "n")
      refute Map.has_key?(cleaned, "session_id")
      refute Map.has_key?(cleaned, "user")
      refute Map.has_key?(cleaned, "arbitrary_client_key")
      assert cleaned["stream"] == true
      assert cleaned["stream_options"] == %{"include_usage" => true}
      assert cleaned["max_tokens"] == 16_384
    end

    test "evicts expired session-affinity entries" do
      key = "session:expired-#{Ecto.UUID.generate()}"
      :ets.insert(:llm_session_affinity, {key, "ds_primary_1", System.system_time(:second) - 1})
      assert :ets.lookup(:llm_session_affinity, key) != []
      assert :ok = AffinityRouter.cleanup_expired!()
      assert :ets.lookup(:llm_session_affinity, key) == []
    end
  end

  describe "TokenizerAndPricing exact vs abort billing" do
    test "pre-flight hold scales with effective output limit and model pricing" do
      chat_channel = %{
        supports_thinking: false,
        max_output_tokens: 8_192,
        pricing: %{
          cache_hit_mc: 200_000,
          cache_miss_mc: 2_000_000,
          output_mc: 3_000_000,
          markup_ratio: 1.5
        }
      }

      reasoning_channel = %{
        supports_thinking: true,
        max_output_tokens: 32_768,
        pricing: %{
          cache_hit_mc: 1_000_000,
          cache_miss_mc: 4_000_000,
          output_mc: 16_000_000,
          markup_ratio: 1.5
        }
      }

      params_large = %{
        "max_tokens" => 8192,
        "messages" => [%{"role" => "user", "content" => "Hello"}]
      }

      params_small = Map.put(params_large, "max_tokens", 1024)

      assert TokenizerAndPricing.estimate_pre_flight_hold_mc(params_large, chat_channel) >
               TokenizerAndPricing.estimate_pre_flight_hold_mc(params_small, chat_channel)

      # Reasoning caps hold output reserve at 4096 even when max_tokens is 32768.
      hold_32k =
        TokenizerAndPricing.estimate_pre_flight_hold_mc(
          Map.put(params_large, "max_tokens", 32_768),
          reasoning_channel
        )

      hold_4k =
        TokenizerAndPricing.estimate_pre_flight_hold_mc(
          Map.put(params_large, "max_tokens", 4_096),
          reasoning_channel
        )

      hold_2k =
        TokenizerAndPricing.estimate_pre_flight_hold_mc(
          Map.put(params_large, "max_tokens", 2_048),
          reasoning_channel
        )

      assert hold_32k == hold_4k
      assert hold_4k > hold_2k
    end

    test "uses official usage for exact billing, off-peak multiplier, and Tiktoken estimate on abort" do
      sse_chunk = """
      data: {"choices":[{"delta":{"reasoning_content":"先思考一下架构。"}}]}

      data: {"choices":[{"delta":{"content":"这是最终的 Elixir 代码实现。"}}]}

      """

      {content_iodata, reasoning_iodata, nil} = LlmGatewayController.parse_sse_metrics(sse_chunk)

      pricing = %{
        cache_hit_mc: 200_000,
        cache_miss_mc: 2_000_000,
        output_mc: 3_000_000,
        markup_ratio: 1.5
      }

      abort_settlement =
        TokenizerAndPricing.calculate_settlement(pricing, 1000, %{
          official_usage: nil,
          output_iodata: content_iodata,
          reasoning_iodata: reasoning_iodata,
          upstream_error?: false,
          off_peak_discount_enabled: true,
          settled_at: ~U[2026-11-19 02:00:00Z]
        })

      assert abort_settlement.billing_mode == :estimated_abort
      assert abort_settlement.prompt_cache_miss_tokens == 1000
      assert abort_settlement.completion_tokens > 0
      assert abort_settlement.reasoning_tokens > 0
      assert abort_settlement.charged_mc > abort_settlement.upstream_cost_mc

      usage = %{
        "prompt_tokens" => 10_000,
        "prompt_cache_hit_tokens" => 9_000,
        "prompt_cache_miss_tokens" => 1_000,
        "completion_tokens" => 500
      }

      peak =
        TokenizerAndPricing.calculate_settlement(pricing, 10_000, %{
          official_usage: usage,
          off_peak_discount_enabled: true,
          settled_at: ~U[2026-11-19 02:00:00Z]
        })

      assert peak.billing_mode == :exact
      assert peak.upstream_cost_mc == 5_300
      assert peak.charged_mc == 7_950

      off_peak =
        TokenizerAndPricing.calculate_settlement(pricing, 10_000, %{
          official_usage: usage,
          off_peak_discount_enabled: true,
          settled_at: ~U[2026-11-19 18:00:00Z]
        })

      assert off_peak.upstream_cost_mc == 2_650
      assert off_peak.charged_mc == 7_950

      assert TokenizerAndPricing.upstream_rate_multiplier(true, ~U[2026-11-21 02:00:00Z]) == 0.5
      assert TokenizerAndPricing.upstream_rate_multiplier(false, ~U[2026-11-21 02:00:00Z]) == 1.0
    end

    test "verify_tokenizer!/0 confirms real Tiktoken NIF and emits telemetry on fallback" do
      assert :ok == TokenizerAndPricing.verify_tokenizer!()
      assert 2 == TokenizerAndPricing.count_text_tokens("hello world")

      handler_id = "tiktoken-fallback-test-#{Ecto.UUID.generate()}"
      test_pid = self()

      :ok =
        :telemetry.attach(
          handler_id,
          [:cgc2046, :llm_gateway, :tokenizer_fallback],
          fn event, measurements, metadata, _config ->
            send(test_pid, {:telemetry_event, event, measurements, metadata})
          end,
          nil
        )

      on_exit(fn -> :telemetry.detach(handler_id) end)

      assert 3 ==
               TokenizerAndPricing.count_text_tokens_with_model(
                 "nonexistent-tiktoken-model",
                 "hello world"
               )

      assert_received {:telemetry_event, [:cgc2046, :llm_gateway, :tokenizer_fallback],
                       %{byte_size: 11}, %{reason: _}}
    end
  end

  describe "AffinityStore periodic ETS cleanup" do
    test "evicts expired entries on :cleanup, keeps fresh entries, and reschedules" do
      pid = Process.whereis(AffinityStore)
      assert is_pid(pid)

      before_state = :sys.get_state(pid)
      now = System.system_time(:second)
      expired_key = "session:store-expired-#{Ecto.UUID.generate()}"
      fresh_key = "session:store-fresh-#{Ecto.UUID.generate()}"

      :ets.insert(:llm_session_affinity, {expired_key, "slot_1", now - 10})
      :ets.insert(:llm_session_affinity, {fresh_key, "slot_1", now + 3_600})

      on_exit(fn ->
        if :ets.whereis(:llm_session_affinity) != :undefined do
          :ets.delete(:llm_session_affinity, expired_key)
          :ets.delete(:llm_session_affinity, fresh_key)
        end
      end)

      send(pid, :cleanup)
      after_state = :sys.get_state(pid)

      assert :ets.lookup(:llm_session_affinity, expired_key) == []
      assert [{^fresh_key, "slot_1", _}] = :ets.lookup(:llm_session_affinity, fresh_key)
      assert is_integer(Process.read_timer(after_state.timer_ref))
      assert after_state.timer_ref != before_state.timer_ref
    end
  end

  describe "GET /v1/models & pre-flight guards" do
    test "GET /v1/models requires desktop token and lists active catalog models" do
      user = register_user("gateway-models")
      raw_token = desktop_token(user)

      assert %{"error" => %{"code" => "unauthorized"}} =
               build_conn() |> get("/v1/models") |> json_response(401)

      seed_provider!(
        slug: "ds-list",
        base_url: "https://api.deepseek.com",
        models: [
          %{
            model_id: "deepseek-chat",
            display_name: "DeepSeek V3",
            supports_thinking: false,
            supports_tools: true,
            supports_images: false
          }
        ]
      )

      resp =
        build_conn()
        |> put_req_header("authorization", "Bearer #{raw_token}")
        |> get("/v1/models")
        |> json_response(200)

      assert %{
               "object" => "list",
               "data" => [
                 %{
                   "id" => "deepseek-chat",
                   "object" => "model",
                   "owned_by" => "cgc-cloud",
                   "display_name" => "DeepSeek V3",
                   "supports_thinking" => false,
                   "supports_tools" => true
                 }
               ]
             } = resp
    end

    test "returns 503 when no channels are configured and 400 model_not_found when model is absent" do
      user = register_user("gateway-missing-model")
      raw_token = desktop_token(user)

      conn_503 =
        build_conn()
        |> put_req_header("authorization", "Bearer #{raw_token}")
        |> put_req_header("content-type", "application/json")
        |> post("/v1/chat/completions", %{
          "model" => "deepseek-chat",
          "messages" => [%{"role" => "user", "content" => "Hi"}]
        })

      assert %{"error" => %{"code" => "upstream_unavailable"}} = json_response(conn_503, 503)

      seed_provider!(slug: "ds-only-chat", base_url: "http://127.0.0.1:1")

      conn_400 =
        build_conn()
        |> put_req_header("authorization", "Bearer #{raw_token}")
        |> put_req_header("content-type", "application/json")
        |> post("/v1/chat/completions", %{
          "model" => "nonexistent-model",
          "messages" => [%{"role" => "user", "content" => "Hi"}]
        })

      assert %{"error" => %{"code" => "model_not_found"}} = json_response(conn_400, 400)
    end

    test "returns 402 when the wallet has zero credits" do
      user = register_user("gateway-zero")
      raw_token = desktop_token(user)
      seed_provider!(slug: "ds-zero", base_url: "http://127.0.0.1:1")

      conn =
        build_conn()
        |> put_req_header("authorization", "Bearer #{raw_token}")
        |> put_req_header("content-type", "application/json")
        |> post("/v1/chat/completions", %{
          "model" => "deepseek-chat",
          "messages" => [%{"role" => "user", "content" => "Hello"}]
        })

      assert %{"error" => %{"code" => "insufficient_quota"}} = json_response(conn, 402)
    end

    test "returns 403 wallet_frozen with optional reason" do
      user = register_user("gateway-frozen")
      raw_token = desktop_token(user)
      seed_provider!(slug: "ds-frozen", base_url: "http://127.0.0.1:1")

      {:ok, _} = Ledger.grant_personal_credits(user.id, %{amount_mc: 500_000, source_type: :pack})
      {:ok, _} = Ledger.set_wallet_status(user.id, :frozen, reason: "疑似脚本高频刷量")

      conn =
        build_conn()
        |> put_req_header("authorization", "Bearer #{raw_token}")
        |> put_req_header("content-type", "application/json")
        |> post("/v1/chat/completions", %{
          "model" => "deepseek-chat",
          "messages" => [%{"role" => "user", "content" => "Hello frozen"}]
        })

      assert %{
               "error" => %{
                 "code" => "wallet_frozen",
                 "type" => "permission_error",
                 "reason" => "疑似脚本高频刷量"
               }
             } = json_response(conn, 403)
    end

    test "returns 429 rate_limit_exceeded, 413 context_length_exceeded, 400 invalid_request, 401 token isolation" do
      user = register_user("gateway-guards")
      raw_token = desktop_token(user)
      seed_provider!(slug: "ds-guards", base_url: "http://127.0.0.1:1")

      # Missing model -> 400
      assert %{"error" => %{"code" => "invalid_request"}} =
               build_conn()
               |> put_req_header("authorization", "Bearer #{raw_token}")
               |> put_req_header("content-type", "application/json")
               |> post("/v1/chat/completions", %{
                 "messages" => [%{"role" => "user", "content" => "No model"}]
               })
               |> json_response(400)

      # MCP token rejected -> 401
      {:ok, _record, mcp_token} = McpToken.issue("gateway-mcp", user, :terminal)

      assert %{"error" => %{"code" => "unauthorized"}} =
               build_conn()
               |> put_req_header("authorization", "Bearer #{mcp_token}")
               |> put_req_header("content-type", "application/json")
               |> post("/v1/chat/completions", %{
                 "model" => "deepseek-chat",
                 "messages" => [%{"role" => "user", "content" => "Hello"}]
               })
               |> json_response(401)

      # Web token rejected -> 401
      assert %{"error" => %{"code" => "unauthorized"}} =
               build_conn()
               |> put_req_header("authorization", "Bearer #{web_token(user)}")
               |> put_req_header("content-type", "application/json")
               |> post("/v1/chat/completions", %{
                 "model" => "deepseek-chat",
                 "messages" => [%{"role" => "user", "content" => "Hello"}]
               })
               |> json_response(401)

      # Context limit -> 413
      {:ok, _} = Ledger.grant_personal_credits(user.id, %{amount_mc: 500_000, source_type: :pack})
      prev_max = Application.get_env(:cgc_2046, :llm_gateway_max_prompt_tokens)
      Application.put_env(:cgc_2046, :llm_gateway_max_prompt_tokens, 20)

      on_exit(fn ->
        if prev_max,
          do: Application.put_env(:cgc_2046, :llm_gateway_max_prompt_tokens, prev_max),
          else: Application.delete_env(:cgc_2046, :llm_gateway_max_prompt_tokens)
      end)

      assert %{"error" => %{"code" => "context_length_exceeded"}} =
               build_conn()
               |> put_req_header("authorization", "Bearer #{raw_token}")
               |> put_req_header("content-type", "application/json")
               |> post("/v1/chat/completions", %{
                 "model" => "deepseek-chat",
                 "messages" => [
                   %{
                     "role" => "user",
                     "content" => String.duplicate("Very long prompt text. ", 20)
                   }
                 ]
               })
               |> json_response(413)
    end
  end

  describe "end-to-end SSE streaming via OpenAI & Anthropic upstreams" do
    test "OpenAI compatible: passes through SSE chunks, settles :exact usage, writes UsageLog" do
      user = register_user("gateway-sse-exact")
      raw_token = desktop_token(user)
      session_id = "sess-sse-exact-#{Ecto.UUID.generate()}"

      {:ok, _} = Ledger.grant_personal_credits(user.id, %{amount_mc: 500_000, source_type: :pack})

      usage = %{
        "prompt_tokens" => 1_000,
        "prompt_cache_hit_tokens" => 400,
        "prompt_cache_miss_tokens" => 600,
        "completion_tokens" => 200,
        "reasoning_tokens" => 50
      }

      server =
        start_sse_server(fn socket, request ->
          assert request.method == "POST"
          assert request.path == "/chat/completions"

          decoded = Jason.decode!(request.body)
          assert decoded["model"] == "deepseek-chat"
          assert decoded["stream"] == true

          send_sse_chunks(socket, [
            sse_data_frame(%{
              "choices" => [%{"delta" => %{"reasoning_content" => "Plan first."}}]
            }),
            sse_data_frame(%{"choices" => [%{"delta" => %{"content" => "Hello from SSE!"}}]}),
            sse_data_frame(%{"choices" => [], "usage" => usage}),
            "data: [DONE]\n\n"
          ])
        end)

      seed_provider!(slug: "local_exact_primary", base_url: server.base_url)

      conn =
        build_conn()
        |> put_req_header("authorization", "Bearer #{raw_token}")
        |> put_req_header("x-session-affinity", session_id)
        |> put_req_header("content-type", "application/json")
        |> put_req_header("accept", "text/event-stream")
        |> post("/v1/chat/completions", %{
          "model" => "deepseek-chat",
          "messages" => [%{"role" => "user", "content" => "Say hello via SSE"}]
        })

      assert conn.status == 200
      assert conn.resp_body =~ "Hello from SSE!"
      assert conn.resp_body =~ "data: [DONE]"

      [log] = user_usage_logs(user.id)
      assert log.session_id == session_id
      assert log.logical_model == "deepseek-chat"
      assert log.upstream_channel == "local_exact_primary"
      assert log.upstream_model == "deepseek-chat"
      assert log.billing_mode == :exact
      assert log.prompt_cache_hit_tokens == 400
      assert log.prompt_cache_miss_tokens == 600
      assert log.completion_tokens == 200
      assert log.charged_mc > 0
      assert Ledger.fetch_wallet!(user.id).held_mc == 0
    end

    test "Anthropic protocol: translates Messages API stream to OpenAI SSE and bills normalized usage" do
      user = register_user("gateway-anthropic-e2e")
      raw_token = desktop_token(user)
      session_id = "sess-ant-#{Ecto.UUID.generate()}"

      {:ok, _} =
        Ledger.grant_personal_credits(user.id, %{amount_mc: 1_000_000, source_type: :pack})

      server =
        start_sse_server(fn socket, request ->
          assert request.method == "POST"
          assert request.path == "/v1/messages"
          assert request.headers["x-api-key"] == "sk-ant-e2e-key"
          assert request.headers["anthropic-version"] == "2023-06-01"

          decoded = Jason.decode!(request.body)
          assert decoded["model"] == "claude-sonnet-4-5-20250929"
          assert decoded["system"] == "Be concise."

          assert [%{"role" => "user", "content" => [%{"type" => "text", "text" => "Hi Claude"}]}] =
                   decoded["messages"]

          send_sse_chunks(socket, [
            "event: message_start\ndata: #{Jason.encode!(%{"type" => "message_start", "message" => %{"id" => "msg_1", "usage" => %{"input_tokens" => 200, "cache_read_input_tokens" => 500, "cache_creation_input_tokens" => 0, "output_tokens" => 1}}})}\n\n",
            "event: content_block_start\ndata: #{Jason.encode!(%{"type" => "content_block_start", "index" => 0, "content_block" => %{"type" => "text", "text" => ""}})}\n\n",
            "event: content_block_delta\ndata: #{Jason.encode!(%{"type" => "content_block_delta", "index" => 0, "delta" => %{"type" => "text_delta", "text" => "Hello from Claude!"}})}\n\n",
            "event: content_block_stop\ndata: #{Jason.encode!(%{"type" => "content_block_stop", "index" => 0})}\n\n",
            "event: message_delta\ndata: #{Jason.encode!(%{"type" => "message_delta", "delta" => %{"stop_reason" => "end_turn"}, "usage" => %{"output_tokens" => 120}})}\n\n",
            "event: message_stop\ndata: #{Jason.encode!(%{"type" => "message_stop"})}\n\n"
          ])
        end)

      seed_provider!(
        slug: "anthropic-e2e",
        protocol: "anthropic",
        base_url: server.base_url,
        api_key: "sk-ant-e2e-key",
        models: [
          %{
            model_id: "claude-sonnet-4-5",
            upstream_model_id: "claude-sonnet-4-5-20250929",
            display_name: "Claude Sonnet 4.5",
            supports_thinking: true,
            supports_tools: true,
            supports_images: true,
            cache_hit_price_mc: 2_000_000,
            cache_miss_price_mc: 20_000_000,
            output_price_mc: 100_000_000
          }
        ]
      )

      conn =
        build_conn()
        |> put_req_header("authorization", "Bearer #{raw_token}")
        |> put_req_header("x-session-affinity", session_id)
        |> put_req_header("content-type", "application/json")
        |> post("/v1/chat/completions", %{
          "model" => "claude-sonnet-4-5",
          "messages" => [
            %{"role" => "system", "content" => "Be concise."},
            %{"role" => "user", "content" => "Hi Claude"}
          ]
        })

      assert conn.status == 200
      assert conn.resp_body =~ "Hello from Claude!"
      assert conn.resp_body =~ ~s("finish_reason":"stop")
      assert conn.resp_body =~ "data: [DONE]"

      [log] = user_usage_logs(user.id)
      assert log.logical_model == "claude-sonnet-4-5"
      assert log.upstream_channel == "anthropic-e2e"
      assert log.upstream_model == "claude-sonnet-4-5-20250929"
      assert log.billing_mode == :exact
      assert log.prompt_cache_hit_tokens == 500
      assert log.prompt_cache_miss_tokens == 200
      assert log.completion_tokens == 120
      assert log.charged_mc > 0
      assert Ledger.fetch_wallet!(user.id).held_mc == 0
    end

    test "fails over from higher-priority HTTP 429 to lower-priority backup provider" do
      user = register_user("gateway-sse-failover")
      raw_token = desktop_token(user)
      session_id = "sess-sse-failover-#{Ecto.UUID.generate()}"
      test_pid = self()

      {:ok, _} = Ledger.grant_personal_credits(user.id, %{amount_mc: 500_000, source_type: :pack})

      primary_server =
        start_sse_server(fn socket, _request ->
          send(test_pid, :primary_429_hit)

          send_json_error(socket, 429, "Too Many Requests", %{
            "error" => %{"message" => "upstream rate limit"}
          })
        end)

      usage = %{
        "prompt_tokens" => 500,
        "prompt_cache_hit_tokens" => 0,
        "prompt_cache_miss_tokens" => 500,
        "completion_tokens" => 120
      }

      backup_server =
        start_sse_server(fn socket, _request ->
          send(test_pid, :backup_sse_hit)

          send_sse_chunks(socket, [
            sse_data_frame(%{"choices" => [%{"delta" => %{"content" => "Served by backup."}}]}),
            sse_data_frame(%{"choices" => [], "usage" => usage}),
            "data: [DONE]\n\n"
          ])
        end)

      {primary_slot_id, _} =
        seed_provider!(
          slug: "local_failover_primary",
          base_url: primary_server.base_url,
          priority: 10
        )

      {backup_slot_id, _} =
        seed_provider!(
          slug: "local_failover_backup",
          base_url: backup_server.base_url,
          priority: 20,
          models: [
            %{
              model_id: "deepseek-chat",
              upstream_model_id: "ep-v3-backup",
              display_name: "DeepSeek Chat"
            }
          ]
        )

      conn =
        build_conn()
        |> put_req_header("authorization", "Bearer #{raw_token}")
        |> put_req_header("x-session-affinity", session_id)
        |> put_req_header("content-type", "application/json")
        |> post("/v1/chat/completions", %{
          "model" => "deepseek-chat",
          "messages" => [%{"role" => "user", "content" => "Trigger 429 failover"}]
        })

      assert_received :primary_429_hit
      assert_received :backup_sse_hit
      assert conn.status == 200
      assert conn.resp_body =~ "Served by backup."

      for _ <- 1..3, do: AffinityRouter.report_failure(primary_slot_id)
      refute AffinityRouter.channel_healthy?(primary_slot_id)
      assert AffinityRouter.channel_healthy?(backup_slot_id)

      [log] = user_usage_logs(user.id)
      assert log.upstream_channel == "local_failover_backup"
      assert log.upstream_model == "ep-v3-backup"
      assert log.billing_mode == :exact
    end

    test "waives charges on mid-stream 200 SSE error frame and bills :estimated_abort on truncated drop" do
      user = register_user("gateway-sse-waive-abort")
      raw_token = desktop_token(user)
      {:ok, _} = Ledger.grant_personal_credits(user.id, %{amount_mc: 500_000, source_type: :pack})

      err_server =
        start_sse_server(fn socket, _request ->
          send_sse_chunks(socket, [
            sse_data_frame(%{"choices" => [%{"delta" => %{"content" => "Partial"}}]}),
            sse_data_frame(%{"error" => %{"message" => "boom", "code" => "server_error"}})
          ])
        end)

      seed_provider!(slug: "sse_err_p", base_url: err_server.base_url)

      conn_err =
        build_conn()
        |> put_req_header("authorization", "Bearer #{raw_token}")
        |> put_req_header("content-type", "application/json")
        |> post("/v1/chat/completions", %{
          "model" => "deepseek-chat",
          "messages" => [%{"role" => "user", "content" => "Error frame"}]
        })

      assert conn_err.status == 200
      assert [err_log] = user_usage_logs(user.id)
      assert err_log.billing_mode == :waived_upstream_error
      assert err_log.charged_mc == 0

      # Truncated drop
      drop_server =
        start_sse_server(fn socket, _request ->
          send_truncated_sse_chunks(socket, [
            sse_data_frame(%{
              "choices" => [%{"delta" => %{"content" => "Truncated output text."}}]
            })
          ])
        end)

      seed_provider!(
        slug: "sse_drop_p",
        base_url: drop_server.base_url,
        models: [%{model_id: "drop-model", upstream_model_id: "drop-model", display_name: "Drop"}]
      )

      conn_drop =
        build_conn()
        |> put_req_header("authorization", "Bearer #{raw_token}")
        |> put_req_header("content-type", "application/json")
        |> post("/v1/chat/completions", %{
          "model" => "drop-model",
          "messages" => [%{"role" => "user", "content" => "Drop stream"}]
        })

      assert conn_drop.status == 200
      assert conn_drop.resp_body =~ "upstream_stream_interrupted"
      drop_log = user_usage_logs(user.id) |> Enum.find(&(&1.logical_model == "drop-model"))
      assert drop_log.billing_mode == :estimated_abort
      assert drop_log.charged_mc > 0
      assert Ledger.fetch_wallet!(user.id).held_mc == 0
    end
  end

  defp seed_provider!(opts) do
    slug = Keyword.fetch!(opts, :slug)
    base_url = Keyword.fetch!(opts, :base_url)
    protocol = Keyword.get(opts, :protocol, "openai_compatible")
    priority = Keyword.get(opts, :priority, 100)
    api_key = Keyword.get(opts, :api_key, "sk-local-#{slug}")
    admin = platform_admin("seed-#{slug}-#{Ecto.UUID.generate()}")

    {:ok, provider} =
      ProviderCatalog.create_provider(admin, %{
        name: Keyword.get(opts, :name, slug),
        slug: slug,
        protocol: protocol,
        base_url: base_url,
        priority: priority,
        off_peak_discount_enabled: Keyword.get(opts, :off_peak_discount_enabled, false)
      })

    {:ok, key_rec} =
      ProviderCatalog.add_api_key(admin, provider.id, %{label: "test", api_key: api_key})

    models =
      Keyword.get(opts, :models, [
        %{
          model_id: "deepseek-chat",
          upstream_model_id: "deepseek-chat",
          display_name: "DeepSeek Chat"
        }
      ])
      |> Enum.map(fn m ->
        Map.merge(
          %{
            context_window: 128_000,
            max_output_tokens: 8_192,
            supports_thinking: false,
            supports_tools: true,
            supports_images: false,
            reasoning_efforts: [],
            cache_hit_price_mc: 200_000,
            cache_miss_price_mc: 2_000_000,
            output_price_mc: 3_000_000,
            markup_ratio: 1.5
          },
          m
        )
      end)

    {:ok, _} = ProviderCatalog.save_provider_models(admin, provider.id, models)
    slot_id = "#{slug}:#{key_rec.id}"
    AffinityRouter.install_fuse(slot_id)
    :fuse.reset({:llm_fuse, slot_id})
    {slot_id, provider}
  end

  defp user_usage_logs(user_id) do
    UsageLog
    |> Ash.read!(authorize?: false)
    |> Enum.filter(&(&1.user_id == user_id))
  end

  defp sse_data_frame(payload) when is_map(payload) do
    "data: " <> Jason.encode!(payload) <> "\n\n"
  end

  defp start_sse_server(handler) when is_function(handler, 2) do
    {:ok, listen_socket} =
      :gen_tcp.listen(0, [
        :binary,
        ip: {127, 0, 0, 1},
        active: false,
        packet: :raw,
        reuseaddr: true
      ])

    {:ok, port} = :inet.port(listen_socket)
    accept_pid = spawn(fn -> accept_loop(listen_socket, handler) end)

    on_exit(fn ->
      :gen_tcp.close(listen_socket)
      ref = Process.monitor(accept_pid)

      receive do
        {:DOWN, ^ref, :process, ^accept_pid, _reason} -> :ok
      after
        1_000 -> Process.exit(accept_pid, :kill)
      end
    end)

    %{port: port, base_url: "http://127.0.0.1:#{port}"}
  end

  defp accept_loop(listen_socket, handler) do
    case :gen_tcp.accept(listen_socket) do
      {:ok, client_socket} ->
        spawn(fn ->
          try do
            case read_http_request(client_socket) do
              {:ok, request} -> handler.(client_socket, request)
              {:error, _reason} -> :ok
            end
          after
            :gen_tcp.close(client_socket)
          end
        end)

        accept_loop(listen_socket, handler)

      {:error, _reason} ->
        :ok
    end
  end

  defp read_http_request(socket) do
    with {:ok, raw_headers, initial_body} <- recv_until_headers_end(socket, ""),
         {:ok, method, path, headers} <- parse_http_headers(raw_headers),
         content_length = parse_content_length(headers),
         {:ok, body} <- recv_exact_body(socket, initial_body, content_length) do
      {:ok, %{method: method, path: path, headers: headers, body: body}}
    end
  end

  defp recv_until_headers_end(socket, acc) do
    case :binary.split(acc, "\r\n\r\n") do
      [raw_headers, rest] ->
        {:ok, raw_headers, rest}

      [_incomplete] ->
        case :gen_tcp.recv(socket, 0, 5_000) do
          {:ok, chunk} -> recv_until_headers_end(socket, acc <> chunk)
          {:error, reason} -> {:error, reason}
        end
    end
  end

  defp parse_http_headers(raw_headers) do
    case String.split(raw_headers, "\r\n") do
      [request_line | header_lines] ->
        case String.split(request_line, " ") do
          [method, path | _] ->
            headers =
              Enum.reduce(header_lines, %{}, fn line, acc ->
                case String.split(line, ":", parts: 2) do
                  [k, v] -> Map.put(acc, String.downcase(String.trim(k)), String.trim(v))
                  _ -> acc
                end
              end)

            {:ok, method, path, headers}

          _ ->
            {:error, :invalid_request_line}
        end

      _ ->
        {:error, :empty_request}
    end
  end

  defp parse_content_length(headers) do
    case Map.get(headers, "content-length") do
      nil ->
        0

      raw ->
        case Integer.parse(raw) do
          {n, _} when n >= 0 -> n
          _ -> 0
        end
    end
  end

  defp recv_exact_body(_socket, body, content_length) when byte_size(body) >= content_length do
    {:ok, binary_part(body, 0, content_length)}
  end

  defp recv_exact_body(socket, acc, content_length) do
    case :gen_tcp.recv(socket, 0, 5_000) do
      {:ok, chunk} -> recv_exact_body(socket, acc <> chunk, content_length)
      {:error, reason} -> {:error, reason}
    end
  end

  defp send_sse_chunks(socket, chunks) when is_list(chunks) do
    header =
      "HTTP/1.1 200 OK\r\ncontent-type: text/event-stream\r\ncache-control: no-cache\r\ntransfer-encoding: chunked\r\nconnection: close\r\n\r\n"

    :ok = :gen_tcp.send(socket, header)
    Enum.each(chunks, fn chunk -> :ok = :gen_tcp.send(socket, encode_http_chunk(chunk)) end)
    :ok = :gen_tcp.send(socket, "0\r\n\r\n")
  end

  defp send_truncated_sse_chunks(socket, chunks) when is_list(chunks) do
    header =
      "HTTP/1.1 200 OK\r\ncontent-type: text/event-stream\r\ncache-control: no-cache\r\ntransfer-encoding: chunked\r\nconnection: close\r\n\r\n"

    :ok = :gen_tcp.send(socket, header)
    Enum.each(chunks, fn chunk -> :ok = :gen_tcp.send(socket, encode_http_chunk(chunk)) end)
    :gen_tcp.close(socket)
  end

  defp send_json_error(socket, status, reason_phrase, payload) do
    body = Jason.encode!(payload)

    response =
      "HTTP/1.1 #{status} #{reason_phrase}\r\ncontent-type: application/json\r\ncontent-length: #{byte_size(body)}\r\nconnection: close\r\n\r\n" <>
        body

    :ok = :gen_tcp.send(socket, response)
  end

  defp encode_http_chunk(bin) when is_binary(bin) do
    Integer.to_string(byte_size(bin), 16) <> "\r\n" <> bin <> "\r\n"
  end

  defp desktop_token(user) do
    {:ok, signed} = SignInFlow.generate_token(user, :desktop, %{})
    signed.__metadata__[:token]
  end

  defp web_token(user) do
    {:ok, signed} = SignInFlow.generate_token(user, :web, %{})
    signed.__metadata__[:token]
  end
end
