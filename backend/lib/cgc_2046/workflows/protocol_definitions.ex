defmodule Cgc2046.Workflows.ProtocolDefinitions do
  @moduledoc """
  三份协议 workflow 定义的唯一定义源（#348 双拷贝收口）。

  消费方（各持一种建入纪律，attrs 形状由本模块单源保证）：

  - `Cgc2046.Accounts.Workspace` `:create` after_action `seed_workflow_definitions/1`
    ——新建 workspace 同事务 seed（产品常驻路径）；
  - `priv/repo/seeds.exs` §3——默认 workspace 2046 的存量幂等补种（部署
    pre-deploy 钩子每次 `Release.seed` 重放，幂等）。

  两者均 `create`（merge `%{input_schema: %{}}`）→ `publish` 两步入库——消费面
  PrepInstantiator / Runs / Curriculum.Instantiator 按 `status: :published` 读取。

  ## 演进纪律

  改本清单（加协议 / 改 node_def）时必须同时评估**存量 workspace**：新清单只在
  新建 workspace 与默认 workspace（seeds 幂等补种）生效，其余存量工作台无定义
  升级机制——形态变更需另立迁移/补种方案，不在本模块职责内。
  """

  @definitions [
    %{
      name: "教研 workflow",
      type: :curriculum,
      node_def: %{"steps" => [%{"id" => "produce_issue_deck", "type" => "manual"}]}
    },
    %{
      name: "学习 workflow",
      type: :learning,
      node_def: %{"steps" => [%{"id" => "learning_loop", "type" => "manual"}]}
    },
    %{
      name: "课程教研 workflow",
      type: :course_preparation,
      node_def: %{"steps" => [%{"id" => "course_preparation", "type" => "manual"}]}
    }
  ]

  @doc "三份协议定义 attrs（name / type / node_def；create 时由消费方合并 input_schema）"
  @spec definitions() :: [map()]
  def definitions, do: @definitions
end
