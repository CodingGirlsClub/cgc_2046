defmodule Cgc2046.Workflows.Policies.ActorReadsWorkflowRun do
  @moduledoc """
  WorkflowRun 读取过滤器。

  普通工作台成员可以读取非 learning 的流程元数据；learning run 的原始
  facts/input snapshot/steps 只对 input_snapshot 中绑定的本人开放。平台管理员
  仍由 WorkflowRun 的独立 platform-admin policy 分支读取审计面。

  这是过渡性的数据库过滤边界：业务页面应继续使用专用投影，不把此资源当作
  Workspace feed。`input_snapshot["user_id"]` 是当前存量 learning run 的锚，待
  显式 subject migration 完成后由该字段切换到显式关系。
  """

  use Ash.Policy.FilterCheck

  @impl true
  def describe(_opts), do: "actor reads non-learning runs as a member or own learning runs"

  @impl true
  def filter(nil, _context, _opts), do: expr(is_nil(id))

  def filter(actor, _context, _opts) do
    actor_id = actor.id

    expr(
      exists(definition.workspace.memberships, user_id == ^actor_id) and
        (definition.type != :learning or subject_user_id == ^actor_id)
    )
  end
end
