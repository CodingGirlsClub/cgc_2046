defmodule Cgc2046.Accounts.Policies.ActorIsAttemptLearner do
  @moduledoc """
  「学习评价尝试的学员本人」授权的命名 SimpleCheck(role-agent-journeys-v2 S8,R42;ADR-0011 L1)。

  写面纪律:Attempt 只能由该学习 run 的学员本人创建(其 agent 经
  `submit_learning_attempt` 提交;tutor/owner/admin 只能读,不能代写)。
  判定:

  - 取 changeset 的 `learning_run_id` 属性,读出 WorkflowRun;
  - run 的 `input_snapshot["user_id"]` == actor.id(学员身份锚,与
    `ActorIsEnrolledLearner` 同源);
  - run 的 workspace_id == changeset.tenant(租户一致性,fail-closed)。

  任一读取失败/字段缺失 → false(fail-closed;`SponsorshipApprover` 的
  DB 直读先例)。工具层已做 confirmed-enrollment 授权,本 check 是资源层
  兜底(双重门禁,同 save_step_output 家族纪律)。
  """

  use Ash.Policy.SimpleCheck

  alias Cgc2046.Workflows.WorkflowRun

  @impl true
  def describe(_opts), do: "actor is the learner of the attempt's learning run"

  @impl true
  def match?(nil, _context, _opts), do: false

  def match?(actor, %{changeset: %Ash.Changeset{} = changeset}, _opts) do
    run_id = Ash.Changeset.get_attribute(changeset, :learning_run_id)
    tenant = changeset.tenant

    with true <- is_binary(run_id) and is_binary(tenant),
         {:ok, %WorkflowRun{} = run} <-
           Ash.get(WorkflowRun, run_id, tenant: tenant, authorize?: false) do
      run.workspace_id == tenant and
        is_map(run.input_snapshot) and
        Map.get(run.input_snapshot, "user_id") == actor.id
    else
      _ -> false
    end
  end

  def match?(_actor, _context, _opts), do: false
end
