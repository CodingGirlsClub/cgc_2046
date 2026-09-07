defmodule Cgc2046.Mcp.Tools.LearnerAuthorization do
  @moduledoc """
  课程学习工具的授权判定(切片 H U3, #180;KTD2;S8 第三层切 run 持有者)。

  三层授权的工具层(工具 `meta: %{membership: :deferred}` 声明、Wrapper 派生门控之后):

  - workspace 成员(tutor/教研编辑/管理面);
  - 本人 confirmed enrollment(事件级参与者,非成员);
  - 本人学习 run 持有者(任意状态,含课程 close/cancel 后——「曾学过」读面,
    S8 起 `Runs.learning_run_holder?/3`(租户收紧,#349 A),替代已删除的 LearningRecord 记忆持有者层)。

  `get_learning_state`(与 web 学员抽屉)共用完整判定;`get_course_content`
  自 M4 起收紧为草稿读面 staff-only(`staff?/2`),不再是完整判定的消费面。
  """

  alias Cgc2046.Accounts.{MembershipContext, Role}
  alias Cgc2046.Learning.Runs

  @doc """
  学员侧授权:成员 ∪ (本人 confirmed enrollment) ∪ (本人学习 run 持有)。

  返回 `:ok | {:error, String.t()}`。course_id 为 nil 时 = 成员(跨台清单类
  调用在学习记录删除后无记忆兜底层——S8 起无 course_id 的完整判定不再放行
  记忆持有者;消费面 `get_learning_state` course_id 必填,nil 分支保留仅防御)。
  """
  @spec authorize(term(), String.t(), String.t() | nil) :: :ok | {:error, String.t()}
  def authorize(actor, workspace_id, course_id)

  def authorize(actor, workspace_id, nil) do
    if member?(actor, workspace_id) do
      :ok
    else
      {:error, "forbidden: enrolled learner or learning run holder required"}
    end
  end

  def authorize(actor, workspace_id, course_id) when is_binary(course_id) do
    cond do
      content_member?(actor, workspace_id) -> :ok
      confirmed_enrollment?(actor, workspace_id, course_id) -> :ok
      Runs.learning_run_holder?(actor, workspace_id, course_id) -> :ok
      true -> {:error, "forbidden: enrolled learner or learning run holder required"}
    end
  end

  @doc "课程教研工作面的 staff 判定：Tutor、Owner、Admin。"
  @spec staff?(term(), String.t()) :: boolean()
  def staff?(actor, workspace_id), do: content_member?(actor, workspace_id)

  @doc "确认过的报名存在性(Runs 单源)。"
  @spec confirmed_enrollment?(term(), String.t(), String.t()) :: boolean()
  def confirmed_enrollment?(actor, workspace_id, course_id),
    do: Runs.confirmed_enrollment?(actor, workspace_id, course_id)

  defp content_member?(actor, workspace_id) do
    case MembershipContext.role_names(actor, workspace_id) do
      roles when is_list(roles) -> Enum.any?(roles, &(Role.manage_role?(&1) or &1 == :tutor))
      _ -> false
    end
  end

  defp member?(actor, workspace_id),
    do: MembershipContext.membership_of(actor, workspace_id) != nil
end
