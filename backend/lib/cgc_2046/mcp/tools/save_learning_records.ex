defmodule Cgc2046.Mcp.Tools.SaveLearningRecords do
  @moduledoc """
  写入学员学习记录(切片 H U3, #180;R4 写,直接写不走两段确认)。

  记忆挂人不挂报名:唯一键 (course_id, user_id, issue_id, item_id) upsert
  最新为准(跨 enrollment 延续,AE1);enrollment_id/run_id 由工具按当前
  confirmed enrollment / learning run 自动补审计值,不由客户端传入。

  授权(KTD2):成员 ∪ 本人 confirmed enrollment ∪ 记忆持有者;另校验课程
  `status ∈ {draft, open}`——close/cancel 拒写保读(R5/AE2,账本不删)。
  学习 run 终态不拦:记忆终身,完成只是进度投影(R6/AE3)。

  records 每条形状:`%{issue_id, item_id, done, evidence}`。
  """
  use Anubis.Server.Component, type: :tool, meta: %{membership: :deferred}

  alias Cgc2046.Admission.Enrollment
  alias Cgc2046.Learning.LearningRecord
  alias Cgc2046.Mcp.Tools.LearnerAuthorization
  alias Cgc2046.Mcp.Wrapper

  require Ash.Query

  schema do
    field(:workspace_id, {:required, :string}, description: "目标工作台 ID(UUID)")
    field(:course_id, {:required, :string}, description: "课程 ID(UUID)")
    field(:issue_id, {:required, :string}, description: "目标 issue 卡 id")

    field(:records, {:required, {:array, :map}},
      description: "记录列表:%{item_id, done, evidence}(issue_id 以顶层为准)"
    )
  end

  @impl true
  def execute(params, frame) do
    result =
      Wrapper.run(frame, params, "save_learning_records", fn actor, workspace_id, params ->
        course_id = params["course_id"] || params[:course_id]
        issue_id = params["issue_id"] || params[:issue_id]
        records = params["records"] || params[:records] || []

        with :ok <- LearnerAuthorization.authorize(actor, workspace_id, course_id),
             {:ok, course} <- fetch_course(workspace_id, course_id),
             :ok <- ensure_writable_status(course),
             {:ok, entries} <- normalize_records(issue_id, records),
             {:ok, saved} <- persist(workspace_id, actor, course, issue_id, entries) do
          {:ok, %{course_id: course_id, issue_id: issue_id, saved: length(saved)}}
        end
      end)

    Cgc2046.Mcp.Tools.Response.to_response(result, frame)
  end

  # 课程读取 authorize?: false(授权在工具层;学员非成员,读 policy 不放行)。
  # tenant: workspace_id 收紧课程归属(F1):不带 tenant 会全表读——A 租户
  # 成员可用 B 租户 course_id 越权写 B 课的学习记录
  defp fetch_course(workspace_id, course_id) do
    case Cgc2046.Events.Course
         |> Ash.Query.for_read(:get_by_id, %{id: course_id})
         |> Ash.read_one(authorize?: false, tenant: workspace_id) do
      {:ok, nil} -> {:error, "course not found: #{course_id}"}
      {:ok, course} -> {:ok, course}
      {:error, _} -> {:error, "failed to load course"}
    end
  end

  # R5 拒写保读:close/cancel 后记忆账本封笔(行不动,读全保留)
  defp ensure_writable_status(%{status: status}) when status in [:draft, :open], do: :ok

  defp ensure_writable_status(%{status: status}),
    do: {:error, "course is #{status}: learning records are read-only"}

  defp normalize_records(issue_id, records) when is_binary(issue_id) and is_list(records) do
    if records == [] do
      {:error, "records must be a non-empty list"}
    else
      records
      |> Enum.reduce_while({:ok, []}, fn raw, {:ok, acc} ->
        case normalize_entry(raw, issue_id) do
          {:ok, entry} -> {:cont, {:ok, [entry | acc]}}
          {:error, reason} -> {:halt, {:error, reason}}
        end
      end)
      |> case do
        {:ok, entries} -> {:ok, Enum.reverse(entries)}
        {:error, reason} -> {:error, reason}
      end
    end
  end

  defp normalize_records(_issue_id, _records),
    do: {:error, "issue_id and non-empty records list are required"}

  defp normalize_entry(raw, issue_id) when is_map(raw) do
    item_id = raw["item_id"] || raw[:item_id]
    done = Map.get(raw, "done", Map.get(raw, :done))
    evidence = raw["evidence"] || raw[:evidence]

    cond do
      not (is_binary(item_id) and item_id != "") ->
        {:error, "each record requires a non-empty item_id"}

      not is_boolean(done) ->
        {:error, "each record requires a boolean done"}

      not (is_nil(evidence) or (is_binary(evidence) and evidence != "")) ->
        {:error, "evidence must be a non-empty string or null"}

      true ->
        {:ok,
         %{
           course_id: nil,
           user_id: nil,
           issue_id: issue_id,
           item_id: item_id,
           done: done,
           evidence: evidence,
           recorded_at: DateTime.utc_now()
         }}
    end
  end

  defp normalize_entry(_raw, _issue_id), do: {:error, "each record must be a map"}

  # 审计列自动补:当前 confirmed enrollment / 其锚定的 learning run——客户端
  # 不传入(伪造面归零;run 完成后仍可写,AE3)。
  defp persist(workspace_id, actor, course, _issue_id, entries) do
    {enrollment_id, run_id} = audit_refs(actor, workspace_id, course.id)
    now = DateTime.utc_now()

    rows =
      Enum.map(entries, fn entry ->
        %{
          course_id: course.id,
          user_id: actor.id,
          issue_id: entry.issue_id,
          item_id: entry.item_id,
          done: entry.done,
          evidence: entry.evidence,
          recorded_at: now,
          enrollment_id: enrollment_id,
          run_id: run_id
        }
      end)

    LearningRecord
    |> Ash.Changeset.for_create(:upsert_records, %{records: rows},
      tenant: workspace_id,
      actor: actor,
      authorize?: false
    )
    |> Ash.create(tenant: workspace_id, actor: actor, authorize?: false)
    |> case do
      {:ok, saved} -> {:ok, List.wrap(saved)}
      {:error, %Ash.Error.Forbidden{}} -> {:error, "forbidden: not authorized to save records"}
      {:error, %Ash.Error.Invalid{} = err} -> {:error, Exception.message(err)}
      {:error, _} -> {:error, "failed to save learning records"}
    end
  end

  defp audit_refs(actor, workspace_id, course_id) do
    enrollment =
      Enrollment
      |> Ash.Query.filter(
        workspace_id == ^workspace_id and course_id == ^course_id and
          user_id == ^actor.id and status == :confirmed
      )
      |> Ash.Query.sort(inserted_at: :desc)
      |> Ash.Query.limit(1)
      |> Ash.read!(authorize?: false)
      |> List.first()

    case enrollment do
      nil -> {nil, nil}
      %{workflow_run_id: run_id} -> {enrollment.id, run_id}
    end
  end
end
