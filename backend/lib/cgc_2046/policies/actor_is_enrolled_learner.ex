defmodule Cgc2046.Policies.ActorIsEnrolledLearner do
  @moduledoc """
  「报名学员本人」授权的命名 SimpleCheck（E-7 #122，学习 workflow 设计 §4.1）。

  学习协议的张力：`update_facts_for_mcp` 的 bypass 要求 actor 是工作台成员，
  而学员是**非成员**（D-A4：报名 ≠ 成员）。本检查是 learning run 的学员豁免分支：

  - 记录是 `WorkflowRun` 且其定义 `type == :learning`；
  - `run.input_snapshot["enrollment_id"]` 反查 Enrollment：存在、
    `status == :confirmed`、`user_id == actor.id`。

  三条件同时成立才放行；任一读取失败/字段缺失 → false（fail-closed，
  授权来自 Enrollment 记录本身——「授权账本」的实体含义）。

  ## 判定数据来源

  取 authorizer context 的 changeset.data（update 动作的被更新记录，属性完整）。
  注意不可用运行时 `check/4` 的记录——Ash 对 update 的运行时复核查询只回填
  主键，其余属性为 nil（数据依赖判定拿不到输入）。SimpleCheck 的 strict 阶段
  经 `strict_check/3` 默认委托拿到带 changeset 的 authorizer context，本模块
  的读取路径与此对齐（DB 直读先例：`SponsorshipApprover`）。

  仅用于 `WorkflowRun` 的 `update_facts_for_mcp` bypass；其他 action/资源
  上下文一律 false。判定规则本体在 `StepAuthorization.enrolled_learner?/3`
  （工具层兜底与资源层 bypass 共用同一条规则，单一实现）。
  """

  use Ash.Policy.SimpleCheck

  alias Cgc2046.Workflows.StepAuthorization
  alias Cgc2046.Workflows.WorkflowRun

  @impl true
  def describe(_opts), do: "actor is the confirmed enrolled learner of this learning run"

  @impl true
  def match?(nil, _context, _opts), do: false

  # authorizer context 的 changeset/subject 承载被更新记录（data 属性完整）。
  # 租户锚定记录自身的 workspace_id（授权账本的实体含义：授权来自记录本身）。
  def match?(actor, %{changeset: %Ash.Changeset{data: %WorkflowRun{} = run}}, _opts) do
    StepAuthorization.enrolled_learner?(actor, run.workspace_id, run)
  end

  def match?(actor, %{subject: %Ash.Changeset{data: %WorkflowRun{} = run}}, _opts) do
    StepAuthorization.enrolled_learner?(actor, run.workspace_id, run)
  end

  def match?(_actor, _context, _opts), do: false
end
