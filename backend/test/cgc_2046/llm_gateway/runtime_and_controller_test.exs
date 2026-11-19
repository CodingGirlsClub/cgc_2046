defmodule Cgc2046.LlmGateway.RuntimeAndControllerTest do
  use Cgc2046Web.ConnCase, async: false

  import Cgc2046.AccountsFixtures

  alias Cgc2046.LlmGateway.AffinityRouter
  alias Cgc2046.LlmGateway.AffinityStore
  alias Cgc2046.LlmGateway.LeaseManager
  alias Cgc2046.LlmGateway.Ledger
  alias Cgc2046.LlmGateway.TokenizerAndPricing
  alias Cgc2046.LlmGateway.UsageLog
  alias Cgc2046.Accounts.SignInFlow
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
        pricing_model: %{
          "cgc-default" => "deepseek-chat",
          "cgc-reasoning" => "deepseek-reasoner",
          "cgc-background" => "deepseek-chat"
        },
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
        pricing_model: %{
          "cgc-default" => "deepseek-chat",
          "cgc-reasoning" => "deepseek-reasoner",
          "cgc-background" => "deepseek-chat"
        },
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
        pricing_model: %{
          "cgc-default" => "deepseek-chat",
          "cgc-reasoning" => "deepseek-reasoner",
          "cgc-background" => "deepseek-chat"
        },
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

    test "evicts expired session-affinity entries" do
      key = "session:expired-#{Ecto.UUID.generate()}"

      :ets.insert(
        :llm_session_affinity,
        {key, "ds_primary_1", System.system_time(:second) - 1}
      )

      assert :ets.lookup(:llm_session_affinity, key) != []
      assert :ok = AffinityRouter.cleanup_expired!()
      assert :ets.lookup(:llm_session_affinity, key) == []
    end

    test "uses the explicit pricing model for opaque endpoint IDs" do
      channel = %{
        id: "volcengine_opaque",
        provider: :volcengine,
        base_url: "http://127.0.0.1:1",
        api_key: "test",
        chat_path: "/chat/completions",
        pricing_model: %{
          "cgc-default" => "deepseek-chat",
          "cgc-reasoning" => "deepseek-reasoner",
          "cgc-background" => "deepseek-chat"
        },
        models: %{
          "cgc-default" => "ep-v3-20261117",
          "cgc-reasoning" => "ep-20261117-abc",
          "cgc-background" => "ep-v3-20261117"
        }
      }

      {_, upstream_model, _} =
        AffinityRouter.prepare_upstream_payload(
          %{"model" => "cgc-reasoning", "messages" => [%{"role" => "user", "content" => "Hi"}]},
          channel
        )

      assert upstream_model == "ep-20261117-abc"
      assert AffinityRouter.pricing_model(channel, "cgc-reasoning") == "deepseek-reasoner"

      usage = %{
        "prompt_tokens" => 1_000,
        "prompt_cache_hit_tokens" => 0,
        "prompt_cache_miss_tokens" => 1_000,
        "completion_tokens" => 1_000
      }

      chat_settlement =
        TokenizerAndPricing.calculate_settlement("deepseek-chat", 1_000, %{
          official_usage: usage
        })

      reasoner_settlement =
        TokenizerAndPricing.calculate_settlement(
          AffinityRouter.pricing_model(channel, "cgc-reasoning"),
          1_000,
          %{official_usage: usage}
        )

      assert reasoner_settlement.charged_mc > chat_settlement.charged_mc
    end
  end

  describe "TokenizerAndPricing exact vs abort billing" do
    test "pre-flight hold scales with the effective output limit" do
      [channel | _] = AffinityRouter.configured_channels()

      params = %{
        "model" => "cgc-default",
        "max_tokens" => 8192,
        "messages" => [%{"role" => "user", "content" => "Hello"}]
      }

      {_, _, prepared} = AffinityRouter.prepare_upstream_payload(params, channel)
      assert prepared["max_tokens"] == 8192

      hold_large =
        TokenizerAndPricing.estimate_pre_flight_hold_mc(prepared, "deepseek-chat")

      hold_small =
        TokenizerAndPricing.estimate_pre_flight_hold_mc(
          Map.put(prepared, "max_tokens", 1024),
          "deepseek-chat"
        )

      assert hold_large > hold_small

      {_, _, capped} =
        AffinityRouter.prepare_upstream_payload(
          %{"model" => "cgc-default", "max_tokens" => 100_000, "messages" => params["messages"]},
          channel
        )

      assert capped["max_tokens"] == 8192

      {_, _, defaulted} =
        AffinityRouter.prepare_upstream_payload(
          %{"model" => "cgc-default", "messages" => params["messages"]},
          channel
        )

      assert defaulted["max_tokens"] == 4096
    end

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

    test "estimate_pre_flight_hold_mc/3 with pre-computed prompt_tokens matches /2" do
      payloads = [
        %{
          "model" => "deepseek-chat",
          "max_tokens" => 2048,
          "messages" => [
            %{"role" => "system", "content" => "You are a concise coding assistant."},
            %{"role" => "user", "content" => "Explain Elixir supervisors in two sentences."}
          ]
        },
        %{
          "model" => "deepseek-reasoner",
          "messages" => [%{"role" => "user", "content" => "Derive the recurrence."}],
          "tools" => [
            %{
              "type" => "function",
              "function" => %{"name" => "lookup", "parameters" => %{"type" => "object"}}
            }
          ]
        }
      ]

      for payload <- payloads, pricing_model <- ["deepseek-chat", "deepseek-reasoner"] do
        prompt_tokens = TokenizerAndPricing.count_request_prompt_tokens(payload)

        assert TokenizerAndPricing.estimate_pre_flight_hold_mc(
                 payload,
                 pricing_model,
                 prompt_tokens
               ) ==
                 TokenizerAndPricing.estimate_pre_flight_hold_mc(payload, pricing_model)
      end

      assert TokenizerAndPricing.estimate_pre_flight_hold_mc(%{}, "deepseek-chat", 0) >= 100

      assert_raise FunctionClauseError, fn ->
        TokenizerAndPricing.estimate_pre_flight_hold_mc(%{}, "deepseek-chat", -1)
      end
    end
  end

  describe "AffinityStore periodic ETS cleanup" do
    test "evicts expired entries on :cleanup, keeps fresh entries, and reschedules" do
      pid = Process.whereis(AffinityStore)
      assert is_pid(pid)

      before_state = :sys.get_state(pid)
      assert before_state.cleanup_interval_ms == 600_000
      assert is_reference(before_state.timer_ref)

      now = System.system_time(:second)
      expired_key = "session:store-expired-#{Ecto.UUID.generate()}"
      fresh_key = "session:store-fresh-#{Ecto.UUID.generate()}"

      :ets.insert(:llm_session_affinity, {expired_key, "ds_primary_1", now - 10})
      :ets.insert(:llm_session_affinity, {fresh_key, "ds_primary_1", now + 3_600})

      on_exit(fn ->
        if :ets.whereis(:llm_session_affinity) != :undefined do
          :ets.delete(:llm_session_affinity, expired_key)
          :ets.delete(:llm_session_affinity, fresh_key)
        end
      end)

      send(pid, :cleanup)
      after_state = :sys.get_state(pid)

      assert :ets.lookup(:llm_session_affinity, expired_key) == []
      assert [{^fresh_key, "ds_primary_1", _}] = :ets.lookup(:llm_session_affinity, fresh_key)
      assert is_reference(after_state.timer_ref)
      assert after_state.timer_ref != before_state.timer_ref
      assert is_integer(Process.read_timer(after_state.timer_ref))
    end

    test "allows overriding cleanup_interval_ms via opts" do
      custom_pid =
        start_supervised!(
          {AffinityStore, name: nil, cleanup_interval_ms: 123_456},
          id: :custom_affinity_store_test
        )

      state = :sys.get_state(custom_pid)
      assert state.cleanup_interval_ms == 123_456
      assert is_integer(Process.read_timer(state.timer_ref))
    end
  end

  describe "LeaseManager & /v1/chat/completions pre-flight guards" do
    test "returns 402 when the wallet has zero credits" do
      user = register_user("gateway-zero")
      raw_token = desktop_token(user)

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

    test "rejects an MCP token before spending credits" do
      user = register_user("gateway-mcp-token")
      {:ok, _record, raw_token} = McpToken.issue("gateway-mcp", user, :terminal)

      {:ok, _} =
        Ledger.grant_personal_credits(user.id, %{amount_mc: 500_000, source_type: :pack})

      conn =
        build_conn()
        |> put_req_header("authorization", "Bearer #{raw_token}")
        |> put_req_header("content-type", "application/json")
        |> put_req_header("accept", "text/event-stream")
        |> post("/v1/chat/completions", %{
          "model" => "cgc-default",
          "messages" => [%{"role" => "user", "content" => "Hello"}]
        })

      assert %{"error" => %{"code" => "unauthorized"}} = json_response(conn, 401)

      wallet = Ledger.fetch_wallet!(user.id)
      assert wallet.cached_balance_mc == 500_000
    end

    test "rejects a web session token on the desktop gateway" do
      user = register_user("gateway-web-token")
      raw_token = web_token(user)

      conn =
        build_conn()
        |> put_req_header("authorization", "Bearer #{raw_token}")
        |> put_req_header("content-type", "application/json")
        |> put_req_header("accept", "text/event-stream")
        |> post("/v1/chat/completions", %{
          "model" => "cgc-default",
          "messages" => [%{"role" => "user", "content" => "Hello"}]
        })

      assert %{"error" => %{"code" => "unauthorized"}} = json_response(conn, 401)
    end

    test "rejects duplicate authorization headers instead of trusting the first user" do
      user = register_user("gateway-duplicate-auth")
      raw_token = web_token(user)

      conn =
        build_conn()
        |> put_req_header("authorization", "Bearer #{raw_token}")
        |> prepend_req_headers([{"authorization", "Bearer not-a-token"}])
        |> put_req_header("content-type", "application/json")
        |> put_req_header("accept", "text/event-stream")
        |> post("/v1/chat/completions", %{
          "model" => "cgc-default",
          "messages" => [%{"role" => "user", "content" => "Hello"}]
        })

      assert %{"error" => %{"code" => "unauthorized"}} = json_response(conn, 401)
    end

    test "returns 429 when concurrent stream slots are exhausted" do
      user = register_user("gateway-concurrent")
      raw_token = desktop_token(user)

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

    test "waives the charge when the upstream transport is unreachable" do
      user = register_user("gateway-dead-upstream")
      raw_token = desktop_token(user)

      {:ok, _} =
        Ledger.grant_personal_credits(user.id, %{amount_mc: 500_000, source_type: :pack})

      dead_channels = [
        %{
          id: "dead_upstream",
          provider: :deepseek,
          base_url: "http://127.0.0.1:1",
          api_key: "test-dead",
          chat_path: "/chat/completions",
          pricing_model: %{
            "cgc-default" => "deepseek-chat",
            "cgc-reasoning" => "deepseek-reasoner",
            "cgc-background" => "deepseek-chat"
          },
          models: %{
            "cgc-default" => "deepseek-chat",
            "cgc-reasoning" => "deepseek-reasoner",
            "cgc-background" => "deepseek-chat"
          }
        }
      ]

      Application.put_env(:cgc_2046, :llm_gateway_channels, dead_channels)
      AffinityRouter.setup!()
      :fuse.reset(:llm_fuse_dead_upstream)

      conn =
        build_conn()
        |> put_req_header("authorization", "Bearer #{raw_token}")
        |> put_req_header("content-type", "application/json")
        |> put_req_header("accept", "text/event-stream")
        |> post("/v1/chat/completions", %{
          "model" => "cgc-default",
          "messages" => [%{"role" => "user", "content" => "Hello"}]
        })

      assert %{"error" => %{"code" => "upstream_unavailable"}} = json_response(conn, 502)

      wallet = Ledger.fetch_wallet!(user.id)
      assert wallet.cached_balance_mc == 500_000
      assert wallet.held_mc == 0
    end
  end

  describe "end-to-end SSE streaming via local :gen_tcp upstream" do
    test "passes through SSE chunks, settles :exact usage, writes UsageLog, and releases hold & slot" do
      user = register_user("gateway-sse-exact")
      raw_token = desktop_token(user)
      session_id = "sess-sse-exact-#{Ecto.UUID.generate()}"

      {:ok, _} =
        Ledger.grant_personal_credits(user.id, %{amount_mc: 500_000, source_type: :pack})

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
          assert decoded["stream"] == true
          assert decoded["stream_options"] == %{"include_usage" => true}

          send_sse_chunks(socket, [
            sse_data_frame(%{
              "choices" => [%{"delta" => %{"reasoning_content" => "Plan first."}}]
            }),
            sse_data_frame(%{"choices" => [%{"delta" => %{"content" => "Hello from SSE!"}}]}),
            sse_data_frame(%{"choices" => [], "usage" => usage}),
            "data: [DONE]\n\n"
          ])
        end)

      configure_local_channels([local_channel("local_exact_primary", server.base_url)])

      conn =
        build_conn()
        |> put_req_header("authorization", "Bearer #{raw_token}")
        |> put_req_header("x-session-affinity", session_id)
        |> put_req_header("content-type", "application/json")
        |> put_req_header("accept", "text/event-stream")
        |> post("/v1/chat/completions", %{
          "model" => "cgc-default",
          "messages" => [%{"role" => "user", "content" => "Say hello via SSE"}]
        })

      assert conn.status == 200
      assert [content_type | _] = get_resp_header(conn, "content-type")
      assert String.starts_with?(content_type, "text/event-stream")
      assert conn.resp_body =~ "Hello from SSE!"
      assert conn.resp_body =~ "data: [DONE]"

      expected =
        TokenizerAndPricing.calculate_settlement("deepseek-chat", 0, %{official_usage: usage})

      wallet = Ledger.fetch_wallet!(user.id)
      assert wallet.held_mc == 0
      assert wallet.cached_balance_mc == 500_000 - expected.charged_mc
      assert LeaseManager.active_streams_count(user.id) == 0

      [log] = user_usage_logs(user.id)
      assert log.session_id == session_id
      assert log.logical_model == "cgc-default"
      assert log.upstream_channel == "local_exact_primary"
      assert log.upstream_model == "deepseek-chat"
      assert log.billing_mode == :exact
      assert log.prompt_cache_hit_tokens == 400
      assert log.prompt_cache_miss_tokens == 600
      assert log.completion_tokens == 200
      assert log.reasoning_tokens == 50
      assert log.charged_mc == expected.charged_mc
      assert log.upstream_cost_mc == expected.upstream_cost_mc
      assert is_integer(log.ttfb_ms) and log.ttfb_ms >= 0
      assert is_integer(log.duration_ms) and log.duration_ms >= 0
    end

    test "fails over from primary HTTP 429 before first chunk to backup, melts primary fuse, and logs backup channel" do
      user = register_user("gateway-sse-failover")
      raw_token = desktop_token(user)
      session_id = "sess-sse-failover-#{Ecto.UUID.generate()}"
      test_pid = self()

      {:ok, _} =
        Ledger.grant_personal_credits(user.id, %{amount_mc: 500_000, source_type: :pack})

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

      configure_local_channels([
        local_channel("local_failover_primary", primary_server.base_url),
        local_channel("local_failover_backup", backup_server.base_url,
          provider: :volcengine,
          models: %{
            "cgc-default" => "ep-v3-backup",
            "cgc-reasoning" => "ep-r1-backup",
            "cgc-background" => "ep-v3-backup"
          }
        )
      ])

      conn =
        build_conn()
        |> put_req_header("authorization", "Bearer #{raw_token}")
        |> put_req_header("x-session-affinity", session_id)
        |> put_req_header("content-type", "application/json")
        |> put_req_header("accept", "text/event-stream")
        |> post("/v1/chat/completions", %{
          "model" => "cgc-default",
          "messages" => [%{"role" => "user", "content" => "Trigger 429 failover"}]
        })

      assert_received :primary_429_hit
      assert_received :backup_sse_hit

      assert conn.status == 200
      assert conn.resp_body =~ "Served by backup."
      assert conn.resp_body =~ "data: [DONE]"

      # :fuse is configured as {:standard, 3, 10_000} (blows on the 4th melt).
      # Because the 429 already recorded 1 melt, 3 additional failures blow it
      # immediately (whereas an unmelted fuse remains healthy after 3 failures).
      assert AffinityRouter.channel_healthy?("local_failover_primary")

      for _ <- 1..3 do
        AffinityRouter.report_failure("local_failover_primary")
      end

      refute AffinityRouter.channel_healthy?("local_failover_primary")
      assert AffinityRouter.channel_healthy?("local_failover_backup")

      wallet = Ledger.fetch_wallet!(user.id)
      assert wallet.held_mc == 0
      assert LeaseManager.active_streams_count(user.id) == 0

      [log] = user_usage_logs(user.id)
      assert log.upstream_channel == "local_failover_backup"
      assert log.upstream_model == "ep-v3-backup"
      assert log.billing_mode == :exact
      assert log.charged_mc > 0
    end

    test "emits upstream_stream_interrupted frame, bills :estimated_abort, and releases hold on mid-stream drop" do
      user = register_user("gateway-sse-mid-drop")
      raw_token = desktop_token(user)
      session_id = "sess-sse-drop-#{Ecto.UUID.generate()}"

      {:ok, _} =
        Ledger.grant_personal_credits(user.id, %{amount_mc: 500_000, source_type: :pack})

      server =
        start_sse_server(fn socket, _request ->
          send_truncated_sse_chunks(socket, [
            sse_data_frame(%{
              "choices" => [
                %{"delta" => %{"reasoning_content" => "Thinking about the answer..."}}
              ]
            }),
            sse_data_frame(%{
              "choices" => [%{"delta" => %{"content" => "Partial output before upstream drop."}}]
            })
          ])
        end)

      configure_local_channels([local_channel("local_mid_drop_primary", server.base_url)])

      conn =
        build_conn()
        |> put_req_header("authorization", "Bearer #{raw_token}")
        |> put_req_header("x-session-affinity", session_id)
        |> put_req_header("content-type", "application/json")
        |> put_req_header("accept", "text/event-stream")
        |> post("/v1/chat/completions", %{
          "model" => "cgc-default",
          "messages" => [%{"role" => "user", "content" => "Stream until drop"}]
        })

      assert conn.status == 200
      assert conn.resp_body =~ "Partial output before upstream drop."
      assert conn.resp_body =~ "upstream_stream_interrupted"

      [log] = user_usage_logs(user.id)
      assert log.upstream_channel == "local_mid_drop_primary"
      assert log.billing_mode == :estimated_abort
      assert log.completion_tokens > 0
      assert log.reasoning_tokens > 0
      assert log.charged_mc > 0
      assert log.upstream_cost_mc > 0

      wallet = Ledger.fetch_wallet!(user.id)
      assert wallet.held_mc == 0
      assert wallet.cached_balance_mc == 500_000 - log.charged_mc
      assert LeaseManager.active_streams_count(user.id) == 0
    end

    test "returns 413 context_length_exceeded on upstream 400 context overflow without melting fuse and waives billing" do
      user = register_user("gateway-sse-413-context")
      raw_token = desktop_token(user)
      session_id = "sess-sse-413-#{Ecto.UUID.generate()}"

      {:ok, _} =
        Ledger.grant_personal_credits(user.id, %{amount_mc: 500_000, source_type: :pack})

      server =
        start_sse_server(fn socket, _request ->
          send_json_error(socket, 400, "Bad Request", %{
            "error" => %{
              "message" =>
                "This model's maximum context length is 131072 tokens. However, you requested 140000 tokens.",
              "type" => "invalid_request_error",
              "code" => "invalid_request_error"
            }
          })
        end)

      configure_local_channels([local_channel("local_413_primary", server.base_url)])

      conn =
        build_conn()
        |> put_req_header("authorization", "Bearer #{raw_token}")
        |> put_req_header("x-session-affinity", session_id)
        |> put_req_header("content-type", "application/json")
        |> put_req_header("accept", "text/event-stream")
        |> post("/v1/chat/completions", %{
          "model" => "cgc-default",
          "messages" => [%{"role" => "user", "content" => "Prompt too long"}]
        })

      assert %{
               "error" => %{
                 "code" => "context_length_exceeded",
                 "type" => "invalid_request_error",
                 "message" => message
               }
             } = json_response(conn, 413)

      assert message =~ "maximum context length is 131072 tokens"

      # 400 client error must NOT melt :fuse: 3 failures stay healthy (4th blows).
      for _ <- 1..3 do
        AffinityRouter.report_failure("local_413_primary")
      end

      assert AffinityRouter.channel_healthy?("local_413_primary")

      wallet = Ledger.fetch_wallet!(user.id)
      assert wallet.held_mc == 0
      assert wallet.cached_balance_mc == 500_000
      assert LeaseManager.active_streams_count(user.id) == 0

      [log] = user_usage_logs(user.id)
      assert log.billing_mode == :waived_upstream_error
      assert log.charged_mc == 0
    end

    test "returns 400 invalid_request with sanitized message on upstream 400 tool schema error and waives billing" do
      user = register_user("gateway-sse-400-schema")
      raw_token = desktop_token(user)
      session_id = "sess-sse-400-#{Ecto.UUID.generate()}"

      {:ok, _} =
        Ledger.grant_personal_credits(user.id, %{amount_mc: 500_000, source_type: :pack})

      long_suffix = String.duplicate("x", 600)

      server =
        start_sse_server(fn socket, _request ->
          send_json_error(socket, 400, "Bad Request", %{
            "error" => %{
              "message" =>
                "Invalid tool schema at https://internal.upstream.local/v1 using sk-secret123456: #{long_suffix}",
              "code" => "invalid_tool_schema"
            }
          })
        end)

      configure_local_channels([local_channel("local_400_primary", server.base_url)])

      conn =
        build_conn()
        |> put_req_header("authorization", "Bearer #{raw_token}")
        |> put_req_header("x-session-affinity", session_id)
        |> put_req_header("content-type", "application/json")
        |> put_req_header("accept", "text/event-stream")
        |> post("/v1/chat/completions", %{
          "model" => "cgc-default",
          "messages" => [%{"role" => "user", "content" => "Bad tool schema"}]
        })

      assert %{
               "error" => %{
                 "code" => "invalid_request",
                 "type" => "invalid_request_error",
                 "message" => message
               }
             } = json_response(conn, 400)

      assert message =~ "Invalid tool schema"
      assert String.length(message) <= 500
      refute message =~ "https://internal.upstream.local"
      refute message =~ "sk-secret123456"

      for _ <- 1..3 do
        AffinityRouter.report_failure("local_400_primary")
      end

      assert AffinityRouter.channel_healthy?("local_400_primary")

      wallet = Ledger.fetch_wallet!(user.id)
      assert wallet.held_mc == 0
      assert wallet.cached_balance_mc == 500_000
      assert LeaseManager.active_streams_count(user.id) == 0

      [log] = user_usage_logs(user.id)
      assert log.billing_mode == :waived_upstream_error
      assert log.charged_mc == 0
    end

    test "fails over from primary HTTP 401 to backup channel, melts primary fuse, and returns 200 SSE" do
      user = register_user("gateway-sse-401-failover")
      raw_token = desktop_token(user)
      session_id = "sess-sse-401-#{Ecto.UUID.generate()}"
      test_pid = self()

      {:ok, _} =
        Ledger.grant_personal_credits(user.id, %{amount_mc: 500_000, source_type: :pack})

      primary_server =
        start_sse_server(fn socket, _request ->
          send(test_pid, :primary_401_hit)

          send_json_error(socket, 401, "Unauthorized", %{
            "error" => %{"message" => "Authentication Fails (invalid api key)"}
          })
        end)

      usage = %{
        "prompt_tokens" => 300,
        "prompt_cache_hit_tokens" => 0,
        "prompt_cache_miss_tokens" => 300,
        "completion_tokens" => 80
      }

      backup_server =
        start_sse_server(fn socket, _request ->
          send(test_pid, :backup_401_sse_hit)

          send_sse_chunks(socket, [
            sse_data_frame(%{
              "choices" => [%{"delta" => %{"content" => "Recovered on backup after 401."}}]
            }),
            sse_data_frame(%{"choices" => [], "usage" => usage}),
            "data: [DONE]\n\n"
          ])
        end)

      configure_local_channels([
        local_channel("local_401_primary", primary_server.base_url),
        local_channel("local_401_backup", backup_server.base_url,
          provider: :volcengine,
          models: %{
            "cgc-default" => "ep-v3-backup",
            "cgc-reasoning" => "ep-r1-backup",
            "cgc-background" => "ep-v3-backup"
          }
        )
      ])

      conn =
        build_conn()
        |> put_req_header("authorization", "Bearer #{raw_token}")
        |> put_req_header("x-session-affinity", session_id)
        |> put_req_header("content-type", "application/json")
        |> put_req_header("accept", "text/event-stream")
        |> post("/v1/chat/completions", %{
          "model" => "cgc-default",
          "messages" => [%{"role" => "user", "content" => "Trigger 401 failover"}]
        })

      assert_received :primary_401_hit
      assert_received :backup_401_sse_hit

      assert conn.status == 200
      assert conn.resp_body =~ "Recovered on backup after 401."
      assert conn.resp_body =~ "data: [DONE]"

      # 401 must melt :fuse once, so 3 additional failures blow it.
      assert AffinityRouter.channel_healthy?("local_401_primary")

      for _ <- 1..3 do
        AffinityRouter.report_failure("local_401_primary")
      end

      refute AffinityRouter.channel_healthy?("local_401_primary")
      assert AffinityRouter.channel_healthy?("local_401_backup")

      wallet = Ledger.fetch_wallet!(user.id)
      assert wallet.held_mc == 0
      assert LeaseManager.active_streams_count(user.id) == 0

      [log] = user_usage_logs(user.id)
      assert log.upstream_channel == "local_401_backup"
      assert log.upstream_model == "ep-v3-backup"
      assert log.billing_mode == :exact
      assert log.charged_mc > 0
    end
  end

  defp local_channel(id, base_url, overrides \\ []) do
    Map.merge(
      %{
        id: id,
        provider: :deepseek,
        base_url: base_url,
        api_key: "sk-local-test",
        chat_path: "/chat/completions",
        pricing_model: %{
          "cgc-default" => "deepseek-chat",
          "cgc-reasoning" => "deepseek-reasoner",
          "cgc-background" => "deepseek-chat"
        },
        models: %{
          "cgc-default" => "deepseek-chat",
          "cgc-reasoning" => "deepseek-reasoner",
          "cgc-background" => "deepseek-chat"
        }
      },
      Map.new(overrides)
    )
  end

  defp configure_local_channels(channels) do
    Application.put_env(:cgc_2046, :llm_gateway_channels, channels)
    AffinityRouter.setup!()

    Enum.each(channels, fn channel ->
      :fuse.reset(:"llm_fuse_#{channel.id}")
    end)
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

    accept_pid =
      spawn(fn ->
        accept_loop(listen_socket, handler)
      end)

    on_exit(fn ->
      :gen_tcp.close(listen_socket)
      ref = Process.monitor(accept_pid)

      receive do
        {:DOWN, ^ref, :process, ^accept_pid, _reason} -> :ok
      after
        1_000 ->
          Process.exit(accept_pid, :kill)
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
      "HTTP/1.1 200 OK\r\n" <>
        "content-type: text/event-stream\r\n" <>
        "cache-control: no-cache\r\n" <>
        "transfer-encoding: chunked\r\n" <>
        "connection: close\r\n\r\n"

    :ok = :gen_tcp.send(socket, header)

    Enum.each(chunks, fn chunk ->
      :ok = :gen_tcp.send(socket, encode_http_chunk(chunk))
    end)

    :ok = :gen_tcp.send(socket, "0\r\n\r\n")
  end

  defp send_truncated_sse_chunks(socket, chunks) when is_list(chunks) do
    header =
      "HTTP/1.1 200 OK\r\n" <>
        "content-type: text/event-stream\r\n" <>
        "cache-control: no-cache\r\n" <>
        "transfer-encoding: chunked\r\n" <>
        "connection: close\r\n\r\n"

    :ok = :gen_tcp.send(socket, header)

    Enum.each(chunks, fn chunk ->
      :ok = :gen_tcp.send(socket, encode_http_chunk(chunk))
    end)

    :gen_tcp.close(socket)
  end

  defp send_json_error(socket, status, reason_phrase, payload) do
    body = Jason.encode!(payload)

    response =
      "HTTP/1.1 #{status} #{reason_phrase}\r\n" <>
        "content-type: application/json\r\n" <>
        "content-length: #{byte_size(body)}\r\n" <>
        "connection: close\r\n\r\n" <>
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
