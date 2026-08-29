defmodule Cgc2046.Learning.ProgressTest do
  @moduledoc """
  LearningProgress issue 级投影测试(切片 H U4, #180)。

  - project/project_issues:doneIssues/totalIssues/currentIssueTitle(+id)派生
  - 三态口径:Todo(无记录)/ In Progress(部分)/ Done(全部)
  - issue key 派生(KTD6 形状)
  - all_issues_done?:完成判定纯函数(worker 消费)
  """
  use ExUnit.Case, async: true

  alias Cgc2046.Learning.Progress

  defp content_fixture do
    %{
      "goals" => ["能写程序"],
      "issues" => [
        %{
          "id" => "py-first",
          "kind" => "handwork",
          "title" => "第一个程序",
          "story" => %{
            "checklist" => [
              %{"id" => "c1", "text" => "能运行"},
              %{"id" => "c2", "text" => "能讲懂"}
            ]
          }
        },
        %{
          "id" => "py-vars",
          "kind" => "thoughtwork",
          "title" => "变量与数据",
          "story" => %{
            "checklist" => [%{"id" => "c1", "text" => "能解释绑定"}]
          }
        }
      ]
    }
  end

  defp record(issue_id, item_id, done) do
    %{issue_id: issue_id, item_id: item_id, done: done}
  end

  describe "issue 级投影" do
    test "无记录 → Todo 全量,currentIssue = 首张" do
      assert Progress.project_issues(content_fixture(), []) == %{
               done_issues: 0,
               total_issues: 2,
               current_issue_id: "py-first",
               current_issue_title: "第一个程序"
             }
    end

    test "部分 done → In Progress,当前 issue 仍是首张" do
      records = [record("py-first", "c1", true)]

      assert Progress.project_issues(content_fixture(), records) == %{
               done_issues: 0,
               total_issues: 2,
               current_issue_id: "py-first",
               current_issue_title: "第一个程序"
             }
    end

    test "首张全 done → done=1,当前 issue 切到第二张" do
      records = [
        record("py-first", "c1", true),
        record("py-first", "c2", true)
      ]

      assert Progress.project_issues(content_fixture(), records) == %{
               done_issues: 1,
               total_issues: 2,
               current_issue_id: "py-vars",
               current_issue_title: "变量与数据"
             }
    end

    test "全部 issue Done → currentIssue nil(课程 Done 态)" do
      records = [
        record("py-first", "c1", true),
        record("py-first", "c2", true),
        record("py-vars", "c1", true)
      ]

      assert Progress.project_issues(content_fixture(), records) == %{
               done_issues: 2,
               total_issues: 2,
               current_issue_id: nil,
               current_issue_title: nil
             }
    end

    test "run 级 project:run 元信息 + issue 投影合并" do
      records = [record("py-first", "c1", true)]

      assert Progress.project(
               "run-1",
               "enrollment-1",
               "Python 入门",
               :running,
               content_fixture(),
               records
             ) == %{
               run_id: "run-1",
               enrollment_id: "enrollment-1",
               target_title: "Python 入门",
               status: "running",
               done_issues: 0,
               total_issues: 2,
               current_issue_id: "py-first",
               current_issue_title: "第一个程序"
             }
    end

    test "无内容/畸形内容安全返回 0/n(currentIssue nil)" do
      for content <- [nil, %{}, %{"issues" => []}, "garbage"] do
        assert Progress.project_issues(content, [
                 record("any", "any", true)
               ]) == %{
                 done_issues: 0,
                 total_issues: 0,
                 current_issue_id: nil,
                 current_issue_title: nil
               }
      end
    end

    test "宽存记录(内容外 issue/item)不参与投影" do
      records = [
        record("ghost-issue", "c9", true),
        record("py-first", "ghost-item", true)
      ]

      projection = Progress.project_issues(content_fixture(), records)
      assert projection.done_issues == 0
      assert projection.current_issue_id == "py-first"
    end
  end

  describe "issue key 派生(KTD6)" do
    test "slug 短码大写 + 序号补零两位" do
      assert Progress.issue_key("python-intro", 1) == "PYTH-01"
      assert Progress.issue_key("python-intro", 2) == "PYTH-02"
      assert Progress.issue_key("py", 12) == "PY-12"
    end

    test "无 slug / 纯符号 slug → C 前缀;非法序号 → 空串" do
      assert Progress.issue_key(nil, 3) == "C-03"
      assert Progress.issue_key("中文课", 3) == "C-03"
      assert Progress.issue_key("py", 0) == ""
    end
  end

  describe "完成判定纯函数" do
    test "all_issues_done?:全部条目 done 才 true" do
      content = content_fixture()

      refute Progress.all_issues_done?(content, [])
      refute Progress.all_issues_done?(content, [record("py-first", "c1", true)])

      assert Progress.all_issues_done?(content, [
               record("py-first", "c1", true),
               record("py-first", "c2", true),
               record("py-vars", "c1", true)
             ])

      # done=false 的记录不算完成
      refute Progress.all_issues_done?(content, [
               record("py-first", "c1", true),
               record("py-first", "c2", false),
               record("py-vars", "c1", true)
             ])
    end

    test "无内容课程恒 false(不判完成)" do
      refute Progress.all_issues_done?(nil, [])
      refute Progress.all_issues_done?(%{"issues" => []}, [])
    end
  end
end
