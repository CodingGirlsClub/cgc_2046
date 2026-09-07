defmodule Cgc2046.Workflows.Policies.ActorReadsWorkflowRun do
  @moduledoc """
  WorkflowRun 读取过滤器。

  普通工作台成员可以读取非 learning 的流程元数据；learning run 的原始
  facts/input snapshot/steps 只对显式 subject_user_id 绑定的本人开放。平台管理员
  仍由 WorkflowRun 的独立 platform-admin policy 分支读取审计面。

  业务页面应继续使用专用投影，不把此资源当作 Workspace feed。learning run 的
  subject_* 字段是迁移后的授权真源，不再从任意 input_snapshot 键推导权限。
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
