defmodule Cgc2046.Sms.SendCloudTest do
  @moduledoc """
  SendCloud SMS 单测（plan 002 U3）：签名算法（官档 §API 验证机制规则锁定）+
  HTTP 契约（Req.Test stub：成功 / result:false / 5xx / 未配置门禁）。
  """
  use Cgc2046.DataCase, async: true

  alias Cgc2046.Sms.SendCloud

  @stub Cgc2046.SmsSendCloudStub

  describe "signature/2（官档规则锁定）" do
    test "参数按 key 字典序拼 k=v&…，前后包 SMS_KEY，SHA256 hex 小写" do
      params = %{
        "phone" => "13800138000",
        "smsUser" => "test_user",
        "templateId" => "1000",
        "vars" => "{\"code\":\"123456\"}",
        "timestamp" => "1700000000",
        "sendRequestId" => "req-1"
      }

      # 独立参考实现（与被测实现不同代码路径）：Enum.sort + join → KEY&plain&KEY → SHA256
      # （官档 §API 验证机制第 3 步：SMS_KEY + '&' + param_str + '&' + SMS_KEY）
      sorted_plain =
        params
        |> Enum.sort()
        |> Enum.map_join("&", fn {k, v} -> "#{k}=#{v}" end)

      expected =
        :crypto.hash(:sha256, "KEY&" <> sorted_plain <> "&KEY") |> Base.encode16(case: :lower)

      assert SendCloud.signature(params, "KEY") == expected
      assert String.length(expected) == 64
      assert expected == String.downcase(expected)
    end

    test "signature / smsKey 不参与签名" do
      base = %{"phone" => "1", "templateId" => "2", "timestamp" => "3"}

      with_sig = Map.put(base, "signature", "should-be-ignored")

      assert SendCloud.signature(with_sig, "K") == SendCloud.signature(base, "K")
    end
  end

  describe "send_template_sms/4" do
    setup do
      original = Application.get_env(:cgc_2046, :sms_sendcloud)

      Application.put_env(:cgc_2046, :sms_sendcloud,
        sms_user: "u",
        sms_key: "k",
        template_id: "t"
      )

      on_exit(fn ->
        Application.put_env(:cgc_2046, :sms_sendcloud, original)
      end)

      :ok
    end

    test "成功：result true → :ok" do
      Req.Test.stub(@stub, fn conn ->
        Req.Test.json(conn, %{"result" => true})
      end)

      assert :ok = SendCloud.send_template_sms("+8613800138000", "t", %{"code" => "123456"}, "r1")
    end

    test "业务失败：result false → {:error, {:send_cloud_sms, status, body}}" do
      Req.Test.stub(@stub, fn conn ->
        Req.Test.json(conn, %{"result" => false, "message" => "bad template"})
      end)

      assert {:error, {:send_cloud_sms, 200, _body}} =
               SendCloud.send_template_sms("+8613800138000", "t", %{}, "r2")
    end

    test "HTTP 500 → {:error, {:send_cloud_sms, 500, _}}" do
      Req.Test.stub(@stub, fn conn ->
        conn
        |> Plug.Conn.put_status(500)
        |> Req.Test.json(%{"result" => false})
      end)

      assert {:error, {:send_cloud_sms, 500, _}} =
               SendCloud.send_template_sms("+8613800138000", "t", %{}, "r3")
    end

    test "凭证缺失 → {:error, :sms_not_configured}（不发请求）" do
      Application.put_env(:cgc_2046, :sms_sendcloud,
        sms_user: nil,
        sms_key: nil,
        template_id: nil
      )

      assert {:error, :sms_not_configured} =
               SendCloud.send_template_sms("+8613800138000", "t", %{}, "r4")

      refute SendCloud.configured?()
    end
  end
end
