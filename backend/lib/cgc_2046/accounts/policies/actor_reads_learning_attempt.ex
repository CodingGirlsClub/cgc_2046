defmodule Cgc2046.Accounts.Policies.ActorReadsLearningAttempt do
  @moduledoc """
  LearningAttempt 读取授权的命名 FilterCheck(role-agent-journeys-v2 S8,R48;ADR-0011 L1)。

  两分支并集:

  - **学员本人**:attempt 锚定的 learning run 的 `input_snapshot["user_id"]`
    == actor.id(授权账本语义——学习 run 的输入快照即学员身份锚,
    `ActorIsEnrolledLearner` 同款纪律);
  - **本工作台 tutor/owner/admin**:教学证据面(导师复核/教研改进)。

  **平台管理员刻意不放行**:证据内容不进平台治理读面——平台治理只读操作
  元数据(admin_list_audit_logs,R16/AE13),学员证据/作答正文永不进入该面
  (元数据级审计归 S10 audit 切片,不在本资源 policy)。

  委托 `ActorReadsOffering` 同款 exists 结构;`Role.manage_roles/0` 单源
  取 owner/admin,加 tutor 构成证据读面角色集。
  """

  use Ash.Policy.FilterCheck

  alias Cgc2046.Accounts.Role

  @impl true
  def describe(_opts),
    do: "actor is the attempt's learner (run anchor) or a tutor/owner/admin of the workspace"

  @impl true
  def filter(nil, _context, _opts), do: expr(is_nil(id))

  def filter(actor, _context, _opts) do
    actor_id = actor.id
    # 证据读面角色集:tutor + 管理角色(owner/admin,单源 Role.manage_roles/0)
    evidence_roles = [:tutor | Role.manage_roles()]

    expr(
      exists(learning_run, input_snapshot["user_id"] == ^actor_id) or
        exists(
          workspace.memberships,
          user_id == ^actor_id and exists(roles, name in ^evidence_roles)
        )
    )
  end
end
