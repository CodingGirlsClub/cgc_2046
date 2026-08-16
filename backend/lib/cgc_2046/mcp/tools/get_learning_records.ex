defmodule Cgc2046.Mcp.Tools.GetLearningRecords do
  @moduledoc """
  读取学员本人学习记录(切片 H U3, #180;R4 读)。

  - 恒以 actor 为 user_id——无他人查询面(设计 §5);
  - `course_id` 可选:缺省 = 本人全部课程记录(学员 agent 据此推导在学
    课程列表,八步循环第 1 步)。

  授权(KTD2):course_id 给定时 = 成员 ∪ 学员 ∪ 记忆持有者;缺省时仅成员
  (非成员无锚点;学员带 course_id 逐课程访问)。
  """
  use Anubis.Server.Component, type: :tool

  alias Cgc2046.Learning.LearningRecord
  alias Cgc2046.Mcp.Tools.LearnerAuthorization
  alias Cgc2046.Mcp.Wrapper

  require Ash.Query

  schema do
    field(:workspace_id, {:required, :string}, description: "目标工作台 ID(UUID)")
    field(:course_id, :string, description: "课程 ID(UUID);缺省 = 本人全部课程记录")
  end

  @impl true
  def execute(params, frame) do
    result =
      Wrapper.run(frame, params, "get_learning_records", fn actor, workspace_id, params ->
        course_id = params["course_id"] || params[:course_id]

        with :ok <- LearnerAuthorization.authorize(actor, workspace_id, course_id),
             {:ok, records} <- fetch_records(actor, workspace_id, course_id) do
          {:ok, %{records: records, count: length(records)}}
        end
      end)

    Cgc2046.Mcp.Tools.Response.to_response(result, frame)
  end

  # user_id 恒锚 actor(不收参数);授权已在工具层发生,读取 authorize?: false。
  # course_id 只作过滤(缺省 = 全部);两分支共用 user_id == actor.id 锚。
  defp fetch_records(actor, workspace_id, course_id) do
    LearningRecord
    |> Ash.Query.filter(user_id == ^actor.id)
    |> maybe_filter_course(course_id)
    |> Ash.Query.sort(recorded_at: :asc)
    |> Ash.read(authorize?: false, tenant: workspace_id)
    |> case do
      {:ok, records} ->
        {:ok,
         Enum.map(records, fn record ->
           %{
             course_id: record.course_id,
             issue_id: record.issue_id,
             item_id: record.item_id,
             done: record.done,
             evidence: record.evidence,
             recorded_at: record.recorded_at
           }
         end)}

      {:error, _} ->
        {:error, "failed to load learning records"}
    end
  end

  defp maybe_filter_course(query, course_id) when is_binary(course_id) do
    Ash.Query.filter(query, course_id == ^course_id)
  end

  defp maybe_filter_course(query, _course_id), do: query
end
