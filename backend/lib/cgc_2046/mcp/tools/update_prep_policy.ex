defmodule Cgc2046.Mcp.Tools.UpdatePrepPolicy do
  @moduledoc """
  调整课程教研策略快照（role-agent-journeys-v2 S5，R22，Owner/Admin 专属，
  确认流 two-tool 写，D-D3）。

  仅 prep_state ∈ (draft, authoring) 可改——tutor 提交（进入 quality_check）
  后生效策略冻结，拒绝调整。调整写 `facts["prep_policy_override"]`（创建时
  input_snapshot 里的策略快照本体不可变），生效策略 = 快照 ← override。

  参数（至少一项；nil 视为未提供）：
  - `review_required`：是否需要人工审核（默认快照 true）；
  - `quality_threshold`：质量报告通过阈值 0-100（默认 80）；
  - `reviewer_user_id`：指定审核人（须为本工作台成员；传空字符串清除指定，
    回到「任何成员可审」）。

  确认流依据：策略决定质量门槛与发布路径（可绕过人工审核直达发布），属高风险
  治理面；confirm 段由 Curriculum.Prep.update_policy/3 的 prep_state 前置断言
  兜底。
  """
  use Anubis.Server.Component, type: :tool

  alias Cgc2046.Courses.Course
  alias Cgc2046.Curriculum.Prep
  alias Cgc2046.Mcp.{Confirmation, Wrapper}

  schema do
    field(:workspace_id, {:required, :string}, description: "目标工作台 ID（UUID）")
    field(:course_id, {:required, :string}, description: "课程 ID（UUID）")
    field(:review_required, :boolean, description: "是否需要人工审核（review 环节）")
    field(:quality_threshold, :integer, description: "质量报告通过阈值（0-100 整数）")

    field(:reviewer_user_id, :string, description: "指定审核人用户 ID（须为本工作台成员）；传空字符串清除指定（任何成员可审，允许自审）")
  end

  @impl true
  def execute(params, frame) do
    result =
      Wrapper.run(frame, params, "update_prep_policy", fn actor, workspace_id, params ->
        course_id = params["course_id"] || params[:course_id]

        with :ok <- authorize(actor, workspace_id),
             {:ok, course} <- fetch_course(workspace_id, course_id),
             {:ok, run} <- fetch_run(course),
             {:ok, patch} <- collect_patch(params, workspace_id),
             :ok <- require_updatable(run) do
          summary =
            "调整课程「#{course.title}」（#{course.id}）的教研策略：" <>
              Enum.map_join(patch, "；", fn {key, value} -> "#{key} → #{inspect(value)}" end) <>
              "（当前生效策略：#{policy_summary(Prep.policy(run))}；提交质量检查后冻结）"

          Confirmation.request(
            frame.assigns[:current_user],
            "update_prep_policy",
            params,
            summary
          )
        end
      end)

    Cgc2046.Mcp.Tools.Response.to_response(result, frame)
  end

  @doc """
  确认后真正执行（由 `Confirmation.execute/3` 直接分派调用）。
  """
  @spec execute_confirmed(term(), map()) :: {:ok, map()} | {:error, String.t()}
  def execute_confirmed(actor, params) do
    workspace_id = params["workspace_id"]
    course_id = params["course_id"]

    with {:ok, course} <- fetch_course(workspace_id, course_id),
         {:ok, run} <- fetch_run(course),
         {:ok, patch} <- collect_patch(params, workspace_id),
         {:ok, updated} <- Prep.update_policy(run, patch, actor) do
      {:ok,
       %{
         course_id: course.id,
         prep_state: Prep.prep_state(updated),
         policy: Prep.policy(updated)
       }}
    end
  end

  defp authorize(actor, workspace_id) do
    if Prep.manage?(actor, workspace_id) do
      :ok
    else
      {:error, "forbidden: owner or admin required to update prep policy"}
    end
  end

  # 第一段快速失败省 pending；confirm 段由 Prep.update_policy 前置断言兜底
  defp require_updatable(run) do
    if Prep.prep_state(run) in ["draft", "authoring"] do
      :ok
    else
      {:error,
       "prep policy is frozen once quality check starts (prep_state=#{Prep.prep_state(run)})"}
    end
  end

  # 白名单收参 + 校验（execute/execute_confirmed 双段共用）。reviewer_user_id
  # 空字符串 = 显式清除（override 写 nil）；其余字符串须为本工作台成员。
  defp collect_patch(params, workspace_id) do
    with {:ok, patch} <- collect_review_required(params, %{}),
         {:ok, patch} <- collect_threshold(params, patch),
         {:ok, patch} <- collect_reviewer(params, patch, workspace_id) do
      if patch == %{} do
        {:error, "no policy fields provided (review_required|quality_threshold|reviewer_user_id)"}
      else
        {:ok, patch}
      end
    end
  end

  defp collect_review_required(params, patch) do
    case param(params, "review_required") do
      nil -> {:ok, patch}
      value when is_boolean(value) -> {:ok, Map.put(patch, "review_required", value)}
      _ -> {:error, "review_required must be a boolean"}
    end
  end

  defp collect_threshold(params, patch) do
    case param(params, "quality_threshold") do
      nil ->
        {:ok, patch}

      value when is_integer(value) and value >= 0 and value <= 100 ->
        {:ok, Map.put(patch, "quality_threshold", value)}

      _ ->
        {:error, "quality_threshold must be an integer in 0..100"}
    end
  end

  defp collect_reviewer(params, patch, workspace_id) do
    case param(params, "reviewer_user_id") do
      nil ->
        {:ok, patch}

      "" ->
        {:ok, Map.put(patch, "reviewer_user_id", nil)}

      user_id when is_binary(user_id) ->
        if Cgc2046.Accounts.MembershipContext.membership_of(%{id: user_id}, workspace_id) do
          {:ok, Map.put(patch, "reviewer_user_id", user_id)}
        else
          {:error, "reviewer_user_id #{user_id} is not a member of workspace #{workspace_id}"}
        end

      _ ->
        {:error, "reviewer_user_id must be a user id string (or \"\" to clear)"}
    end
  end

  defp param(params, key) do
    if Map.has_key?(params, key),
      do: params[key],
      else: Map.get(params, String.to_existing_atom(key))
  end

  defp policy_summary(policy) do
    "review_required=#{policy["review_required"]}, " <>
      "quality_threshold=#{policy["quality_threshold"]}, " <>
      "reviewer_user_id=#{inspect(policy["reviewer_user_id"])}"
  end

  defp fetch_course(workspace_id, course_id) do
    case Course
         |> Ash.Query.for_read(:get_by_id, %{id: course_id})
         |> Ash.read_one(authorize?: false, tenant: workspace_id) do
      {:ok, nil} -> {:error, "course not found: #{course_id}"}
      {:ok, course} -> {:ok, course}
      {:error, _} -> {:error, "failed to load course"}
    end
  end

  defp fetch_run(course) do
    case Prep.fetch_run(course.id, course.workspace_id) do
      nil -> {:error, "no preparation run found for course #{course.id}"}
      run -> {:ok, run}
    end
  end
end
