defmodule Cgc2046.LlmGateway.AnthropicAdapterTest do
  use ExUnit.Case, async: true

  alias Cgc2046.LlmGateway.Protocol.AnthropicAdapter

  test "build_request converts OpenAI messages, tools, images, tool_results, and thinking" do
    channel = %{
      base_url: "https://api.anthropic.com",
      chat_path: nil,
      api_key: "sk-ant-test",
      upstream_model_id: "claude-sonnet-4-5",
      max_output_tokens: 16_384,
      supports_thinking: true
    }

    params = %{
      "model" => "claude-sonnet-4-5",
      "max_tokens" => 8_192,
      "reasoning_effort" => "medium",
      "temperature" => 0.7,
      "tool_choice" => %{"type" => "function", "function" => %{"name" => "read_file"}},
      "stop" => ["END"],
      "tools" => [
        %{
          "type" => "function",
          "function" => %{
            "name" => "read_file",
            "description" => "Read a file",
            "parameters" => %{
              "type" => "object",
              "properties" => %{"path" => %{"type" => "string"}}
            }
          }
        }
      ],
      "messages" => [
        %{"role" => "system", "content" => "You are helpful."},
        %{"role" => "user", "content" => "Check a.txt"},
        %{
          "role" => "assistant",
          "reasoning_content" => "ignore me",
          "content" => "Calling read_file.",
          "tool_calls" => [
            %{
              "id" => "call_1",
              "type" => "function",
              "function" => %{"name" => "read_file", "arguments" => ~s({"path":"a.txt"})}
            }
          ]
        },
        %{
          "role" => "tool",
          "tool_call_id" => "call_1",
          "content" => "file contents"
        },
        %{"role" => "assistant", "content" => "Done."},
        %{
          "role" => "user",
          "content" => [
            %{"type" => "text", "text" => "Look at this"},
            %{
              "type" => "image_url",
              "image_url" => %{"url" => "data:image/png;base64,QUJD"}
            }
          ]
        }
      ]
    }

    req = AnthropicAdapter.build_request(params, channel)

    assert req.url == "https://api.anthropic.com/v1/messages"
    assert {"x-api-key", "sk-ant-test"} in req.headers
    assert {"anthropic-version", "2023-06-01"} in req.headers

    body = req.body
    assert body["model"] == "claude-sonnet-4-5"
    assert body["system"] == "You are helpful."
    assert body["max_tokens"] == 8_192
    assert body["thinking"] == %{"type" => "enabled", "budget_tokens" => 4_096}
    refute Map.has_key?(body, "temperature")
    assert body["stop_sequences"] == ["END"]
    assert body["tool_choice"] == %{"type" => "tool", "name" => "read_file"}

    assert [
             %{
               "name" => "read_file",
               "description" => "Read a file",
               "input_schema" => %{"type" => "object"}
             }
           ] = body["tools"]

    assert [
             %{"role" => "user", "content" => [%{"type" => "text", "text" => "Check a.txt"}]},
             %{
               "role" => "assistant",
               "content" => [
                 %{"type" => "text", "text" => "Calling read_file."},
                 %{
                   "type" => "tool_use",
                   "id" => "call_1",
                   "name" => "read_file",
                   "input" => %{"path" => "a.txt"}
                 }
               ]
             },
             %{
               "role" => "user",
               "content" => [
                 %{
                   "type" => "tool_result",
                   "tool_use_id" => "call_1",
                   "content" => "file contents"
                 }
               ]
             },
             %{"role" => "assistant", "content" => [%{"type" => "text", "text" => "Done."}]},
             %{
               "role" => "user",
               "content" => [
                 %{"type" => "text", "text" => "Look at this"},
                 %{
                   "type" => "image",
                   "source" => %{
                     "type" => "base64",
                     "media_type" => "image/png",
                     "data" => "QUJD"
                   }
                 }
               ]
             }
           ] = body["messages"]
  end

  test "translate_sse_frames converts Anthropic SSE stream into OpenAI SSE chunks and normalized usage" do
    state = AnthropicAdapter.new_stream_state("claude-sonnet-4-5")

    frames = [
      sse("message_start", %{
        "type" => "message_start",
        "message" => %{
          "id" => "msg_123",
          "usage" => %{
            "input_tokens" => 100,
            "cache_read_input_tokens" => 800,
            "cache_creation_input_tokens" => 50,
            "output_tokens" => 1
          }
        }
      }),
      sse("content_block_start", %{
        "type" => "content_block_start",
        "index" => 0,
        "content_block" => %{"type" => "thinking", "thinking" => ""}
      }),
      sse("content_block_delta", %{
        "type" => "content_block_delta",
        "index" => 0,
        "delta" => %{"type" => "thinking_delta", "thinking" => "Step 1"}
      }),
      sse("content_block_stop", %{"type" => "content_block_stop", "index" => 0}),
      sse("content_block_start", %{
        "type" => "content_block_start",
        "index" => 1,
        "content_block" => %{"type" => "text", "text" => ""}
      }),
      sse("content_block_delta", %{
        "type" => "content_block_delta",
        "index" => 1,
        "delta" => %{"type" => "text_delta", "text" => "Hello "}
      }),
      sse("content_block_stop", %{"type" => "content_block_stop", "index" => 1}),
      sse("content_block_start", %{
        "type" => "content_block_start",
        "index" => 2,
        "content_block" => %{
          "type" => "tool_use",
          "id" => "toolu_1",
          "name" => "read_file",
          "input" => %{}
        }
      }),
      sse("content_block_delta", %{
        "type" => "content_block_delta",
        "index" => 2,
        "delta" => %{"type" => "input_json_delta", "partial_json" => ~s({"path":"x"})}
      }),
      sse("content_block_stop", %{"type" => "content_block_stop", "index" => 2}),
      sse("message_delta", %{
        "type" => "message_delta",
        "delta" => %{"stop_reason" => "tool_use"},
        "usage" => %{"output_tokens" => 42}
      }),
      sse("message_stop", %{"type" => "message_stop"})
    ]

    {out_iodata, c_frags, r_frags, usage, sse_error?, next_state} =
      AnthropicAdapter.translate_sse_frames(frames, state)

    refute sse_error?
    assert next_state.done_sent? == true
    assert IO.iodata_to_binary(c_frags) == ~s(Hello {"path":"x"})
    assert IO.iodata_to_binary(r_frags) == "Step 1"

    assert usage == %{
             "prompt_tokens" => 950,
             "prompt_cache_hit_tokens" => 800,
             "prompt_cache_miss_tokens" => 150,
             "prompt_tokens_details" => %{"cached_tokens" => 800},
             "completion_tokens" => 42,
             "total_tokens" => 992
           }

    out = IO.iodata_to_binary(out_iodata)
    assert out =~ ~s("reasoning_content":"Step 1")
    assert out =~ ~s("content":"Hello ")
    assert out =~ ~s("name":"read_file")
    assert out =~ ~s("finish_reason":"tool_calls")
    assert out =~ "data: [DONE]\n\n"
  end

  test "translate_sse_frames flags sse_error? on Anthropic error event" do
    state = AnthropicAdapter.new_stream_state("claude-sonnet-4-5")

    frames = [
      sse("error", %{
        "type" => "error",
        "error" => %{"type" => "overloaded_error", "message" => "Overloaded"}
      })
    ]

    {out_iodata, _c, _r, _usage, sse_error?, _next_state} =
      AnthropicAdapter.translate_sse_frames(frames, state)

    assert sse_error? == true
    assert IO.iodata_to_binary(out_iodata) =~ "overloaded_error"
  end

  test "AnthropicStream preserves multi-chunk signatures and redacted_thinking across tool continuation round trip" do
    state = AnthropicAdapter.new_stream_state("claude-sonnet-4-5")

    frames = [
      sse("message_start", %{
        "type" => "message_start",
        "message" => %{
          "id" => "msg_sig",
          "usage" => %{"input_tokens" => 50, "output_tokens" => 1}
        }
      }),
      sse("content_block_start", %{
        "type" => "content_block_start",
        "index" => 0,
        "content_block" => %{"type" => "thinking", "thinking" => ""}
      }),
      sse("content_block_delta", %{
        "type" => "content_block_delta",
        "index" => 0,
        "delta" => %{"type" => "thinking_delta", "thinking" => "Part A "}
      }),
      sse("content_block_delta", %{
        "type" => "content_block_delta",
        "index" => 0,
        "delta" => %{"type" => "thinking_delta", "thinking" => "Part B"}
      }),
      sse("content_block_delta", %{
        "type" => "content_block_delta",
        "index" => 0,
        "delta" => %{"type" => "signature_delta", "signature" => "sig_part_1_"}
      }),
      sse("content_block_delta", %{
        "type" => "content_block_delta",
        "index" => 0,
        "delta" => %{"type" => "signature_delta", "signature" => "sig_part_2"}
      }),
      sse("content_block_stop", %{"type" => "content_block_stop", "index" => 0}),
      sse("content_block_start", %{
        "type" => "content_block_start",
        "index" => 1,
        "content_block" => %{"type" => "redacted_thinking", "data" => "opaque_redacted_blob"}
      }),
      sse("content_block_stop", %{"type" => "content_block_stop", "index" => 1}),
      sse("content_block_start", %{
        "type" => "content_block_start",
        "index" => 2,
        "content_block" => %{"type" => "text", "text" => ""}
      }),
      sse("content_block_delta", %{
        "type" => "content_block_delta",
        "index" => 2,
        "delta" => %{"type" => "text_delta", "text" => "Checking file"}
      }),
      sse("content_block_stop", %{"type" => "content_block_stop", "index" => 2}),
      sse("content_block_start", %{
        "type" => "content_block_start",
        "index" => 3,
        "content_block" => %{
          "type" => "tool_use",
          "id" => "toolu_sig",
          "name" => "read_file",
          "input" => %{"path" => "README.md"}
        }
      }),
      sse("content_block_stop", %{"type" => "content_block_stop", "index" => 3}),
      sse("message_delta", %{
        "type" => "message_delta",
        "delta" => %{"stop_reason" => "tool_use"},
        "usage" => %{"output_tokens" => 25}
      }),
      sse("message_stop", %{"type" => "message_stop"})
    ]

    {out_iodata, _c_frags, r_frags, _usage, sse_error?, _next_state} =
      AnthropicAdapter.translate_sse_frames(frames, state)

    refute sse_error?
    assert IO.iodata_to_binary(r_frags) == "Part A Part B"

    deltas =
      out_iodata
      |> IO.iodata_to_binary()
      |> String.split("\n\n", trim: true)
      |> Enum.reject(&(&1 == "data: [DONE]"))
      |> Enum.map(fn line ->
        line
        |> String.replace_prefix("data: ", "")
        |> Jason.decode!()
        |> get_in(["choices", Access.at(0), "delta"])
      end)
      |> Enum.reject(&is_nil/1)

    thinking_blocks =
      Enum.flat_map(deltas, fn d -> Map.get(d, "thinking_blocks", []) end)

    assert thinking_blocks == [
             %{
               "type" => "thinking",
               "thinking" => "Part A Part B",
               "signature" => "sig_part_1_sig_part_2"
             },
             %{
               "type" => "redacted_thinking",
               "data" => "opaque_redacted_blob"
             }
           ]

    channel = %{
      base_url: "https://api.anthropic.com",
      chat_path: nil,
      api_key: "sk-ant-test",
      upstream_model_id: "claude-sonnet-4-5",
      max_output_tokens: 16_384,
      supports_thinking: true
    }

    continuation =
      AnthropicAdapter.build_request(
        %{
          "model" => "claude-sonnet-4-5",
          "max_tokens" => 12_000,
          "reasoning_effort" => "high",
          "messages" => [
            %{"role" => "user", "content" => "Inspect README"},
            %{
              "role" => "assistant",
              "reasoning_content" => "Part A Part B",
              "thinking_blocks" => thinking_blocks,
              "content" => "Checking file",
              "tool_calls" => [
                %{
                  "id" => "toolu_sig",
                  "type" => "function",
                  "function" => %{
                    "name" => "read_file",
                    "arguments" => ~s({"path":"README.md"})
                  }
                }
              ]
            },
            %{
              "role" => "tool",
              "tool_call_id" => "toolu_sig",
              "content" => "README contents"
            }
          ]
        },
        channel
      )

    assert continuation.body["thinking"] == %{"type" => "enabled", "budget_tokens" => 8_192}

    assert [
             %{"role" => "user", "content" => [%{"type" => "text", "text" => "Inspect README"}]},
             %{
               "role" => "assistant",
               "content" => [
                 %{
                   "type" => "thinking",
                   "thinking" => "Part A Part B",
                   "signature" => "sig_part_1_sig_part_2"
                 },
                 %{
                   "type" => "redacted_thinking",
                   "data" => "opaque_redacted_blob"
                 },
                 %{"type" => "text", "text" => "Checking file"},
                 %{
                   "type" => "tool_use",
                   "id" => "toolu_sig",
                   "name" => "read_file",
                   "input" => %{"path" => "README.md"}
                 }
               ]
             },
             %{
               "role" => "user",
               "content" => [
                 %{
                   "type" => "tool_result",
                   "tool_use_id" => "toolu_sig",
                   "content" => "README contents"
                 }
               ]
             }
           ] = continuation.body["messages"]
  end

  test "build_request omits thinking on tool continuation when assistant lacks signed thinking" do
    channel = %{
      base_url: "https://api.anthropic.com",
      chat_path: nil,
      api_key: "sk-ant-test",
      upstream_model_id: "claude-sonnet-4-5",
      max_output_tokens: 16_384,
      supports_thinking: true
    }

    req =
      AnthropicAdapter.build_request(
        %{
          "model" => "claude-sonnet-4-5",
          "max_tokens" => 8_192,
          "reasoning_effort" => "high",
          "messages" => [
            %{"role" => "user", "content" => "Hi"},
            %{
              "role" => "assistant",
              "reasoning_content" => "unsigned reasoning from non-Anthropic shape",
              "content" => "",
              "tool_calls" => [
                %{
                  "id" => "call_unsigned",
                  "type" => "function",
                  "function" => %{"name" => "ping", "arguments" => "{}"}
                }
              ]
            },
            %{"role" => "tool", "tool_call_id" => "call_unsigned", "content" => "pong"}
          ]
        },
        channel
      )

    refute Map.has_key?(req.body, "thinking")

    assert [
             _,
             %{
               "role" => "assistant",
               "content" => [%{"type" => "tool_use", "id" => "call_unsigned"}]
             },
             _
           ] = req.body["messages"]
  end

  defp sse(event, payload) do
    "event: #{event}\ndata: #{Jason.encode!(payload)}"
  end
end
