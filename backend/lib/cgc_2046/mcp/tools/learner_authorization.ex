defmodule Cgc2046.Mcp.Tools.LearnerAuthorization do
  @moduledoc """
  课程学习工具的授权判定(切片 H U3, #180;KTD2)。

  三层授权的工具层(工具 `meta: %{membership: :deferred}` 声明、Wrapper 派生门控之后):

  - workspace 成员(tutor/教研编辑/管理面);
  - 本人 confirmed enrollment(事件级参与者,非成员);
  - 本人已有学习记录(记忆持有者——历史学员,报名可能已非 confirmed)。

  `get_course_content` 用完整判定(成员 OR 学员 OR 记忆持有者,实际同本模块);
  读类两工具共用;`save_learning_records` 另有课程终态拦截(拒写保读,R5)
  在工具自身做,不在本模块。
  """

  alias Cgc2046.Accounts.MembershipContext
  alias Cgc2046.Admission.Enrollment
  alias Cgc2046.Learning.LearningRecord

  require Ash.Query

  @doc """
  学员侧授权:成员 ∪ (本人 confirmed enrollment) ∪ (本人已有记忆)。

  返回 `:ok | {:error, String.t()}`。course_id 为 nil 时 = 成员 ∪ 有任意记忆者
  (F2 八步循环第 1 步:学员 agent 无 course_id 拉全部记录推导课程列表)。
  """
  @spec authorize(term(), String.t(), String.t() | nil) :: :ok | {:error, String.t()}
  def authorize(actor, workspace_id, course_id)

  def authorize(actor, workspace_id, nil) do
    cond do
      member?(actor, workspace_id) -> :ok
      any_memory?(actor) -> :ok
      true -> {:error, "forbidden: workspace member or learning records required"}
    end
  end

  def authorize(actor, workspace_id, course_id) when is_binary(course_id) do
    cond do
      member?(actor, workspace_id) -> :ok
      confirmed_enrollment?(actor, workspace_id, course_id) -> :ok
      memory_holder?(actor, course_id) -> :ok
      true -> {:error, "forbidden: enrolled learner or record holder required"}
    end
  end

  @doc "确认过的报名存在性(StepAuthorization.enrolled_learner? 的 course 级变体)。"
  @spec confirmed_enrollment?(term(), String.t(), String.t()) :: boolean()
  def confirmed_enrollment?(%{id: actor_id}, workspace_id, course_id)
      when is_binary(workspace_id) and is_binary(course_id) do
    Enrollment
    |> Ash.Query.filter(
      workspace_id == ^workspace_id and course_id == ^course_id and
        user_id == ^actor_id and status == :confirmed
    )
    |> Ash.Query.limit(1)
    |> Ash.read!(authorize?: false)
    |> case do
      [] -> false
      [_] -> true
    end
  end

  def confirmed_enrollment?(_actor, _workspace_id, _course_id), do: false

  @doc "本人已有学习记录(记忆持有者;含 close 后课程——拒写保读的读半边)。"
  @spec memory_holder?(term(), String.t()) :: boolean()
  def memory_holder?(%{id: actor_id}, course_id) when is_binary(course_id) do
    LearningRecord
    |> Ash.Query.filter(course_id == ^course_id and user_id == ^actor_id)
    |> Ash.Query.limit(1)
    |> Ash.read!(authorize?: false)
    |> case do
      [] -> false
      [_] -> true
    end
  end

  def memory_holder?(_actor, _course_id), do: false

  @spec any_memory?(term()) :: boolean()
  def any_memory?(%{id: actor_id}) do
    LearningRecord
    |> Ash.Query.filter(user_id == ^actor_id)
    |> Ash.Query.limit(1)
    |> Ash.read!(authorize?: false)
    |> case do
      [] -> false
      [_] -> true
    end
  end

  def any_memory?(_actor), do: false

  defp member?(actor, workspace_id) do
    case MembershipContext.membership_of(actor, workspace_id) do
      nil -> false
      _membership -> true
    end
  end
end
