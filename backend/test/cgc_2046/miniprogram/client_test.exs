defmodule Cgc2046.Miniprogram.ClientTest do
  # Tesla.Mock 为 process dict + wechat client 走 :persistent_term 缓存
  # （与 miniprogram_code_test 同约束，串行防跨用例污染）
  use ExUnit.Case, async: false

  alias Cgc2046.Miniprogram.Client

  @skipped_event [:cgc_2046, :content_check, :skipped]
  @msg_check_url "https://api.weixin.qq.com/wxa/msg_sec_check"

  setup do
    test_pid = self()

    # 默认 mock：msgSecCheck 通过（errcode 0），并把请求体回传给测试进程
    # 供断言（plan 008 零外呼红线同款：未匹配的请求直接 raise，绝不真实出网）。
    Tesla.Mock.mock(fn
      %{method: :post, url: @msg_check_url <> _} = env ->
        send(test_pid, {:msg_check_request, Jason.decode!(env.body)})
        Tesla.Mock.json(%{"errcode" => 0})
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

  describe "content_check/2" do
    test "wechat 通过（errcode 0）：返回 {:ok, :passed}，请求体为原始 content" do
      assert {:ok, :passed} = Client.content_check(:wechat, "我很期待参加这次活动")

      assert_receive {:msg_check_request, %{"content" => "我很期待参加这次活动"}}
    end

    test "wechat 违规（87014）：fail-closed 返回 {:error, {:content_rejected, 87014}}" do
      Tesla.Mock.mock(fn
        %{method: :post, url: @msg_check_url <> _} ->
          Tesla.Mock.json(%{"errcode" => 87014, "errmsg" => "risky content"})
      end)

      assert {:error, {:content_rejected, 87014}} = Client.content_check(:wechat, "违规内容样例")
    end

    test "wechat 限流（45009）：fail-open 返回 {:ok, :skipped}，telemetry 记 rate_limited" do
      test_pid = self()
      attach_skipped_telemetry(test_pid)

      Tesla.Mock.mock(fn
        %{method: :post, url: @msg_check_url <> _} ->
          Tesla.Mock.json(%{"errcode" => 45009, "errmsg" => "reach max api daily quota limit"})
      end)

      assert {:ok, :skipped} = Client.content_check(:wechat, "正常报名理由")

      assert_receive {:content_check_skipped, @skipped_event, %{count: 1},
                      %{reason: :rate_limited}}
    end

    test "wechat 网络错误：fail-open 返回 {:ok, :skipped}，telemetry 记 network" do
      test_pid = self()
      attach_skipped_telemetry(test_pid)

      Tesla.Mock.mock(fn
        %{method: :post, url: @msg_check_url <> _} ->
          {:error, :timeout}
      end)

      assert {:ok, :skipped} = Client.content_check(:wechat, "正常报名理由")

      assert_receive {:content_check_skipped, @skipped_event, %{count: 1}, %{reason: :network}}
    end

    test "wechat 非 200：fail-open 返回 {:ok, :skipped}，telemetry 记 http_status" do
      test_pid = self()
      attach_skipped_telemetry(test_pid)

      Tesla.Mock.mock(fn
        %{method: :post, url: @msg_check_url <> _} ->
          Tesla.Mock.json(%{"errcode" => -1}, status: 500)
      end)

      assert {:ok, :skipped} = Client.content_check(:wechat, "正常报名理由")

      assert_receive {:content_check_skipped, @skipped_event, %{count: 1},
                      %{reason: :http_status}}
    end

    test "tt/xhs 显式 pass-through：返回 {:ok, :unchecked} 零外呼（未 mock 直接调用不炸）" do
      # 不 mock msgSecCheck：若实现误发请求，Tesla.Mock 无匹配即 raise——结构性证明零外呼。
      assert {:ok, :unchecked} = Client.content_check(:tt, "任何内容都不检查")
      assert {:ok, :unchecked} = Client.content_check(:xhs, "任何内容都不检查")
      refute_receive {:msg_check_request, _}
    end

    test "content 超 2500 字节时 clamp 后再外呼（官方 msgSecCheck 上限，防御性截断）" do
      long_content = String.duplicate("很期待", 1_000)

      assert {:ok, :passed} = Client.content_check(:wechat, long_content)

      assert_receive {:msg_check_request, %{"content" => clamped}}

      # 官方上限 2500 字节；截断回退到完整 UTF-8 字符边界（≤2500，且明显小于原始 9000 字节）
      assert byte_size(clamped) <= 2500
      assert byte_size(clamped) > 2400
      assert String.valid?(clamped)
    end
  end
end
