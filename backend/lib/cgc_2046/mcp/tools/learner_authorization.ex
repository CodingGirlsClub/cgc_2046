defmodule Cgc2046.Mcp.Tools.LearnerAuthorization do
  @moduledoc """
  课程学习工具的授权判定(切片 H U3, #180;KTD2;S8 第三层切 run 持有者)。

  三层授权的工具层(工具 `meta: %{membership: :deferred}` 声明、Wrapper 派生门控之后):

  - workspace 成员(tutor/教研编辑/管理面);
  - 本人 confirmed enrollment(事件级参与者,非成员);
  - 本人学习 run 持有者(任意状态,含课程 close/cancel 后——「曾学过」读面,
    S8 起 `Runs.learning_run_holder?/2`,替代已删除的 LearningRecord 记忆持有者层)。

  `get_course_content` / `get_learning_state` 共用完整判定。
  """

  alias Cgc2046.Accounts.MembershipContext
  alias Cgc2046.Learning.Runs

  @doc """
  学员侧授权:成员 ∪ (本人 confirmed enrollment) ∪ (本人学习 run 持有)。

  返回 `:ok | {:error, String.t()}`。course_id 为 nil 时 = 成员(跨台清单类
  调用在学习记录删除后无记忆兜底层——S8 起无 course_id 的完整判定不再放行
  记忆持有者;消费面 `get_course_content`/`get_learning_state` 均 course_id
  必填,nil 分支保留仅防御)。
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
      member?(actor, workspace_id) -> :ok
      confirmed_enrollment?(actor, workspace_id, course_id) -> :ok
      Runs.learning_run_holder?(actor, course_id) -> :ok
      true -> {:error, "forbidden: enrolled learner or learning run holder required"}
    end
  end

  @doc "确认过的报名存在性(Runs 单源)。"
  @spec confirmed_enrollment?(term(), String.t(), String.t()) :: boolean()
  def confirmed_enrollment?(actor, workspace_id, course_id),
    do: Runs.confirmed_enrollment?(actor, workspace_id, course_id)

  defp member?(actor, workspace_id) do
    case MembershipContext.membership_of(actor, workspace_id) do
      nil -> false
      _membership -> true
    end
  end
end
