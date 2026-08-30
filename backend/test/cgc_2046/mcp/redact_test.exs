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
end
