defmodule Cgc2046.Workflows.LearningProgressTest do
  use ExUnit.Case, async: true

  alias Cgc2046.Workflows.LearningProgress

  test "按 node_def 顺序统计 manual steps，并用 Step 标题定位当前步骤" do
    node_def = %{
      "steps" => [
        %{"id" => "intro", "type" => "auto"},
        %{"id" => "outline", "type" => "manual"},
        %{"id" => "review", "type" => "manual"}
      ]
    }

    steps = [
      %{step_key: "review", title: "复盘作业"},
      %{step_key: "outline", title: "设计大纲"}
    ]

    assert LearningProgress.project(
             "run-1",
             "enrollment-1",
             "学习活动",
             :waiting,
             node_def,
             steps,
             %{}
           ) == %{
             run_id: "run-1",
             enrollment_id: "enrollment-1",
             target_title: "学习活动",
             status: "waiting",
             completed_manual_steps: 0,
             total_manual_steps: 2,
             current_step_title: "设计大纲"
           }
  end

  test "facts 乱序时按 manual key 计数，succeeded 可与 n-1/n 口径并存" do
    node_def = %{
      "steps" => [
        %{"id" => "first", "type" => "manual"},
        %{"id" => "auto", "type" => "auto"},
        %{"id" => "last", "type" => "manual"}
      ]
    }

    assert LearningProgress.project(
             "run-2",
             "enrollment-2",
             nil,
             :succeeded,
             node_def,
             [%{step_key: "first", title: "第一步"}, %{step_key: "last", title: "最后一步"}],
             %{"last" => %{"answer" => "ok"}}
           ) == %{
             run_id: "run-2",
             enrollment_id: "enrollment-2",
             target_title: nil,
             status: "succeeded",
             completed_manual_steps: 1,
             total_manual_steps: 2,
             current_step_title: "第一步"
           }
  end

  test "空 facts、无效 node_def 与缺失 Step 标题安全返回" do
    assert LearningProgress.project("run-3", "enrollment-3", "课程", "running", %{}, [], nil) == %{
             run_id: "run-3",
             enrollment_id: "enrollment-3",
             target_title: "课程",
             status: "running",
             completed_manual_steps: 0,
             total_manual_steps: 0,
             current_step_title: nil
           }

    assert LearningProgress.project(
             "run-4",
             "enrollment-4",
             "课程",
             :running,
             %{"steps" => [%{"id" => "missing", "type" => "manual"}]},
             [],
             %{}
           ).current_step_title == nil
  end
end
