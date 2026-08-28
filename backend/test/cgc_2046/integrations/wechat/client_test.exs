defmodule Cgc2046.Integrations.Wechat.ClientTest do
  # Tesla.Mock 为 process dict + wechat client 走 :persistent_term 缓存
  # （与 miniprogram_code_test 同约束，串行防跨用例污染）
  use ExUnit.Case, async: false

  alias Cgc2046.Integrations.Wechat.Client

  @skipped_event [:cgc_2046, :content_check, :skipped]
  @msg_check_url "https://api.weixin.qq.com/wxa/msg_sec_check"
  @openid "test-wechat-openid"

  setup do
    test_pid = self()

    # 默认 mock：msgSecCheck v2 通过（errcode 0 + result.suggest=pass），并把
    # 请求体回传给测试进程供断言（plan 008 零外呼红线同款：未匹配请求直接 raise）。
    Tesla.Mock.mock(fn
      %{method: :post, url: @msg_check_url <> _} = env ->
        send(test_pid, {:msg_check_request, Jason.decode!(env.body)})
        Tesla.Mock.json(%{"errcode" => 0, "result" => %{"suggest" => "pass", "label" => 100}})
    end)

    :ok
  end

  defp attach_skipped_telemetry(test_pid) do
    handler_id = "content-check-skipped-#{System.unique_integer([:positive])}"

    :ok =
      :telemetry.attach(
        handler_id,
        @skipped_event,
        fn event, measurements, metadata, _config ->
          send(test_pid, {:content_check_skipped, event, measurements, metadata})
        end,
        nil
      )

    on_exit(fn -> :telemetry.detach(handler_id) end)
  end

  describe "content_check/3" do
    test "wechat v2 通过（suggest=pass）：返回 {:ok, :passed}，请求体为 v2 形状" do
      assert {:ok, :passed} = Client.content_check(:wechat, "我很期待参加这次活动", @openid)

      # v2 契约：content/version/scene/openid 必带（SDK msg_check v1 不可达）
      assert_receive {:msg_check_request,
                      %{
                        "content" => "我很期待参加这次活动",
                        "version" => 2,
                        "scene" => 2,
                        "openid" => @openid
                      }}
    end

    test "wechat v2 违规（suggest=risky，label 20002 色情）：fail-closed 拒绝" do
      Tesla.Mock.mock(fn
        %{method: :post, url: @msg_check_url <> _} ->
          Tesla.Mock.json(%{
            "errcode" => 0,
            "result" => %{"suggest" => "risky", "label" => 20002},
            "detail" => [
              %{"strategy" => "20002", "errcode" => 0, "suggest" => "risky", "label" => 20002}
            ]
          })
      end)

      assert {:error, :content_rejected} = Client.content_check(:wechat, "违规内容样例", @openid)
    end

    test "wechat v2 待审（suggest=review）：fail-closed 拒绝" do
      Tesla.Mock.mock(fn
        %{method: :post, url: @msg_check_url <> _} ->
          Tesla.Mock.json(%{
            "errcode" => 0,
            "result" => %{"suggest" => "review", "label" => 20002}
          })
      end)

      assert {:error, :content_rejected} = Client.content_check(:wechat, "待审内容样例", @openid)
    end

    test "wechat 限流（45009）：fail-open 返回 {:ok, :skipped}，telemetry 记 rate_limited" do
      test_pid = self()
      attach_skipped_telemetry(test_pid)

      Tesla.Mock.mock(fn
        %{method: :post, url: @msg_check_url <> _} ->
          Tesla.Mock.json(%{"errcode" => 45009, "errmsg" => "reach max api daily quota limit"})
      end)

      assert {:ok, :skipped} = Client.content_check(:wechat, "正常报名理由", @openid)

      assert_receive {:content_check_skipped, @skipped_event, %{count: 1},
                      %{reason: :rate_limited}}
    end

    test "wechat 未知 errcode（47001 需 POST）：fail-open 返回 {:ok, :skipped}，telemetry 记 unknown_errcode" do
      test_pid = self()
      attach_skipped_telemetry(test_pid)

      Tesla.Mock.mock(fn
        %{method: :post, url: @msg_check_url <> _} ->
          Tesla.Mock.json(%{"errcode" => 47001, "errmsg" => "data format error"})
      end)

      assert {:ok, :skipped} = Client.content_check(:wechat, "正常报名理由", @openid)

      assert_receive {:content_check_skipped, @skipped_event, %{count: 1},
                      %{reason: :unknown_errcode}}
    end

    test "wechat 网络错误：fail-open 返回 {:ok, :skipped}，telemetry 记 network" do
      test_pid = self()
      attach_skipped_telemetry(test_pid)

      Tesla.Mock.mock(fn
        %{method: :post, url: @msg_check_url <> _} ->
          {:error, :timeout}
      end)

      assert {:ok, :skipped} = Client.content_check(:wechat, "正常报名理由", @openid)

      assert_receive {:content_check_skipped, @skipped_event, %{count: 1}, %{reason: :network}}
    end

    test "wechat 非 200：fail-open 返回 {:ok, :skipped}，telemetry 记 http_status" do
      test_pid = self()
      attach_skipped_telemetry(test_pid)

      Tesla.Mock.mock(fn
        %{method: :post, url: @msg_check_url <> _} ->
          Tesla.Mock.json(%{"errcode" => -1}, status: 500)
      end)

      assert {:ok, :skipped} = Client.content_check(:wechat, "正常报名理由", @openid)

      assert_receive {:content_check_skipped, @skipped_event, %{count: 1},
                      %{reason: :http_status}}
    end

    test "tt/xhs 显式 pass-through：返回 {:ok, :unchecked} 零外呼（未 mock 直接调用不炸）" do
      # 不 mock msgSecCheck：若实现误发请求，Tesla.Mock 无匹配即 raise——结构性证明零外呼。
      assert {:ok, :unchecked} = Client.content_check(:tt, "任何内容都不检查", "tt-openid")
      assert {:ok, :unchecked} = Client.content_check(:xhs, "任何内容都不检查", "xhs-openid")
      refute_receive {:msg_check_request, _}
    end
  end
end
