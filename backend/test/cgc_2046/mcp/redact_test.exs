defmodule Cgc2046.Mcp.RedactTest do
  @moduledoc "参数脱敏（D-D8）：snake_case / camelCase / 嵌套 / 边界不误伤"
  use ExUnit.Case, async: true

  alias Cgc2046.Mcp.Redact

  test "snake_case 后缀与精确键命中" do
    assert Redact.call(%{
             "api_key" => "k1",
             "user_token" => "t",
             "password" => "p",
             "nested" => %{"refresh_token" => "r", "name" => "ok"}
           }) == %{
             "api_key" => "[REDACTED]",
             "user_token" => "[REDACTED]",
             "password" => "[REDACTED]",
             "nested" => %{"refresh_token" => "[REDACTED]", "name" => "ok"}
           }
  end

  test "camelCase 后缀命中（apiToken / userPassword / authToken）" do
    assert Redact.call(%{
             "apiToken" => "t",
             "userPassword" => "p",
             "authToken" => "a"
           }) == %{
             "apiToken" => "[REDACTED]",
             "userPassword" => "[REDACTED]",
             "authToken" => "[REDACTED]"
           }
  end

  test "不误伤：纯小写非敏感词、仅前缀含敏感词、原子键" do
    assert Redact.call(%{
             "monkey" => "ok",
             "tokenizer" => "ok",
             "name" => "ok",
             email: "a@b.com"
           }) == %{
             "monkey" => "ok",
             "tokenizer" => "ok",
             "name" => "ok",
             email: "a@b.com"
           }
  end

  test "list 递归与非 map 原样" do
    assert Redact.call([%{"secret" => "s"}, %{"x" => 1}]) == [
             %{"secret" => "[REDACTED]"},
             %{"x" => 1}
           ]

    assert Redact.call("plain") == "plain"
    assert Redact.call(nil) == nil
  end

  describe "按工具收窄（S10，R48/AE12/AE13）" do
    test "submit_learning_attempt：只留引用白名单，evidence/rubric/rationale/agent_meta 不落审计" do
      params = %{
        "workspace_id" => "ws-1",
        "course_id" => "c-1",
        "objective_id" => "obj-run",
        "passed" => true,
        "confidence" => 0.9,
        "evidence" => "实机跑通,输出正确",
        "rubric_results" => [%{"criterion_id" => "r1", "met" => true, "note" => "逐行讲清"}],
        "rationale" => "证据可复核,标准达成",
        "agent_meta" => %{"client" => "agent"}
      }

      assert Redact.call("submit_learning_attempt", params) == %{
               "workspace_id" => "ws-1",
               "course_id" => "c-1",
               "objective_id" => "obj-run",
               "passed" => true,
               "confidence" => 0.9
             }
    end

    test "submit_learning_attempt：atom 键兼容 + 敏感键先脱敏再收窄（白名单外敏感键消失）" do
      params = %{
        workspace_id: "ws-1",
        course_id: "c-1",
        objective_id: "obj-run",
        passed: false,
        confidence: 0.5,
        evidence: "作答正文",
        api_token: "secret-token"
      }

      assert Redact.call("submit_learning_attempt", params) == %{
               workspace_id: "ws-1",
               course_id: "c-1",
               objective_id: "obj-run",
               passed: false,
               confidence: 0.5
             }
    end

    test "其他工具 params 原样通过（收窄仅作用于具名工具；call/1 默认路径不收窄）" do
      params = %{
        "workspace_id" => "ws-1",
        "objective_id" => "obj-run",
        "evidence" => "证据正文照留",
        "rationale" => "理由照留"
      }

      assert Redact.call("submit_prep_quality_report", params) == params
    end
  end

  describe "字节上限（P2 防审计放大）" do
    test "超长字符串值截断为元数据（truncated 标记 + 原长度 + preview 前缀）" do
      big = String.duplicate("a", 5_000)

      assert %{"content" => meta} = Redact.call(%{"content" => big})
      assert meta["truncated"] == true
      assert meta["byte_size"] == 5_000
      assert byte_size(meta["preview"]) <= 256
      assert String.starts_with?(big, meta["preview"])
    end

    test "恰好等于上限的字符串不截断；嵌套 map / list 内超长值同样截断" do
      at_cap = String.duplicate("b", 1_024)

      result =
        Redact.call(%{
          "ok" => at_cap,
          "nested" => %{"deep" => String.duplicate("c", 2_000)},
          "list" => [String.duplicate("d", 2_000)]
        })

      assert result["ok"] == at_cap
      assert %{"truncated" => true, "byte_size" => 2_000} = result["nested"]["deep"]
      assert [%{"truncated" => true, "byte_size" => 2_000}] = result["list"]
    end

    test "多字节 UTF-8 字符串截断不产生非法字节序列" do
      big = String.duplicate("汉", 1_000)

      assert %{"content" => %{"preview" => preview}} = Redact.call(%{"content" => big})
      assert String.valid?(preview)
      assert byte_size(preview) <= 256
    end

    test "整条 params JSON 超总上限 → 整体退化为截断元数据摘要" do
      params = Map.new(1..20, fn i -> {"key_#{i}", String.duplicate("x", 900)} end)

      result = Redact.call(params)

      assert Enum.all?(result, fn
               {"key_" <> _i, %{"truncated" => true, "byte_size" => 900}} -> true
               _ -> false
             end)
    end

    test "metadata_only：小标量与查询锚保留，大值只留长度与截断标记" do
      ws_id = Ecto.UUID.generate()

      result =
        Redact.metadata_only(%{
          "workspace_id" => ws_id,
          "count" => 3,
          "flag" => false,
          "big" => String.duplicate("e", 10_000),
          "nested" => %{"a" => 1},
          "token" => "[REDACTED]"
        })

      assert result["workspace_id"] == ws_id
      assert result["count"] == 3
      assert result["flag"] == false
      assert result["token"] == "[REDACTED]"
      assert result["big"] == %{"truncated" => true, "byte_size" => 10_000}
      assert %{"truncated" => true, "byte_size" => bs} = result["nested"]
      assert bs > 0
    end

    test "metadata_only：键数与键长均有界（攻击者可控维度不放大）" do
      params =
        1..80
        |> Map.new(fn i -> {"key_#{i}", i} end)
        |> Map.put(String.duplicate("a", 500), "v")

      result = Redact.metadata_only(params)

      assert result["_dropped_keys"] == 31
      long_key = Enum.find(Map.keys(result), &(String.length(&1) > 50))
      assert byte_size(long_key) <= 67
      assert String.ends_with?(long_key, "…")
    end
  end
end
