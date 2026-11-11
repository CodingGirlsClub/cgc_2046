defmodule Cgc2046.Learning.CourseNotes do
  @moduledoc """
  课程 Notes 服务端上下文：创建/查询/编辑/删除。

  授权姿态：
  - 读/改/删：仅笔记所有者（资源 owner policy 兜底，本模块再显式校验）；
  - 创建：课程可学习（`Learning.Authorization`）后才写入；
  - Notes 不向 staff/admin 暴露。

  去重与幂等：
  - 用户 NOTE 的 `dedupe_hash` 由服务端按规范化文本 + source material 计算；
  - RETRO 用 `retro_key` 唯一；删除保留墓碑（见 `ensure_retro/3`）。
  """

  require Ash.Query

  alias Cgc2046.Courses.{Course, CourseProjection}
  alias Cgc2046.Curriculum
  alias Cgc2046.Curriculum.Content
  alias Cgc2046.Learning.{Authorization, CourseNote, Runs}

  @max_text 4000

  @type actor :: term()
  @type note_error ::
          :course_not_accessible | :invalid_text | :invalid_issue | :not_found | :duplicate_note

  @doc "当前 actor 在课程下的笔记；可按 issue 过滤。"
  @spec list(actor(), String.t(), String.t() | nil) :: {:ok, [CourseNote.t()]}
  def list(actor, course_id, issue_id \\ nil) when is_binary(course_id) do
    case fetch_course(course_id) do
      nil ->
        {:ok, []}

      course ->
        query =
          CourseNote
          |> Ash.Query.filter(
            user_id == ^actor.id and course_id == ^course.id and is_nil(deleted_at)
          )
          |> Ash.Query.sort(inserted_at: :desc)

        query =
          if is_binary(issue_id) and issue_id != "" do
            Ash.Query.filter(query, issue_id == ^issue_id)
          else
            query
          end

        Ash.read(query, actor: actor)
    end
  end

  @doc """
  创建用户笔记；同文本 + 同 source 的活跃 NOTE 直接返回已有条目。
  """
  @spec create(actor(), map()) :: {:ok, CourseNote.t()} | {:error, note_error()}
  def create(actor, attrs) when is_map(attrs) do
    text = attrs[:text] || attrs["text"]
    issue_id = attrs[:issue_id] || attrs["issue_id"]
    source_material_id = attrs[:source_material_id] || attrs["source_material_id"]
    course_id = attrs[:course_id] || attrs["course_id"]

    with :ok <- validate_text(text),
         {:ok, issue_id} <- validate_issue(issue_id),
         {:ok, course} <- fetch_accessible_course(actor, course_id) do
      source_material_id = blank_to_nil(source_material_id)
      dedupe_hash = dedupe_hash(text, source_material_id)
      revision_id = latest_revision_id(course)

      case find_active_note(actor, course.id, issue_id, dedupe_hash) do
        nil ->
          attrs = %{
            workspace_id: course.workspace_id,
            user_id: actor.id,
            course_id: course.id,
            course_revision_id: revision_id,
            issue_id: issue_id,
            source_material_id: source_material_id,
            kind: :note,
            text: String.trim(text),
            dedupe_hash: dedupe_hash
          }

          CourseNote
          |> Ash.Changeset.for_create(:create_note, attrs, actor: actor)
          |> Ash.create()
          |> case do
            {:ok, note} -> {:ok, note}
            {:error, error} -> recover_unique_note(actor, course.id, issue_id, dedupe_hash, error)
          end

        note ->
          {:ok, note}
      end
    end
  end

  @doc "编辑笔记文本；仅本人；NOTE 重算去重键，冲突返回 duplicate_note。"
  @spec update(actor(), String.t(), String.t()) ::
          {:ok, CourseNote.t()} | {:error, note_error()}
  def update(actor, note_id, text) do
    with :ok <- validate_text(text),
         {:ok, note} <- fetch_owned_note(actor, note_id) do
      dedupe_hash =
        if note.kind == :note do
          dedupe_hash(text, note.source_material_id)
        else
          nil
        end

      if note.kind == :note and
           duplicate_other_note?(actor, note, dedupe_hash) do
        {:error, :duplicate_note}
      else
        note
        |> Ash.Changeset.for_update(:update_note, %{
          text: String.trim(text),
          dedupe_hash: dedupe_hash
        })
        |> Ash.update(actor: actor)
        |> case do
          {:ok, updated} -> {:ok, updated}
          {:error, error} -> map_write_error(error)
        end
      end
    end
  end

  @doc """
  确保当前 Issue 的 Retro 存在：服务端重新校验必修完成，按 revision 幂等；
  已删除的 Retro 不重建。
  """
  @spec ensure_retro(actor(), String.t(), String.t()) ::
          {:ok, CourseNote.t() | nil} | {:error, note_error()}
  def ensure_retro(actor, course_id, issue_id) do
    with {:ok, issue_id} <- validate_issue(issue_id),
         {:ok, course} <- fetch_accessible_course(actor, course_id),
         {:ok, %{content: content}} <- CourseProjection.content(actor, course.id),
         revision_id = latest_revision_id(course),
         issue when is_map(issue) <- find_issue(content, issue_id),
         state <- Runs.learning_state(actor, course),
         true <- all_required_mastered?(state.objectives, issue_id) do
      retro_key = retro_key(course, revision_id, issue_id)

      case find_retro(retro_key) do
        %CourseNote{deleted_at: nil} = note ->
          {:ok, note}

        %CourseNote{deleted_at: %DateTime{}} ->
          {:ok, nil}

        nil ->
          create_retro(actor, course, revision_id, issue, retro_key, state.objectives)
      end
    else
      _ -> {:ok, nil}
    end
  end

  @doc "删除笔记；NOTE 硬删除，RETRO 写墓碑。"
  @spec delete(actor(), String.t()) :: {:ok, true} | {:error, note_error()}
  def delete(actor, note_id) do
    with {:ok, note} <- fetch_owned_note(actor, note_id) do
      if note.kind == :retro do
        note
        |> Ash.Changeset.for_update(:mark_deleted, %{deleted_at: DateTime.utc_now()})
        |> Ash.update(actor: actor)
      else
        Ash.destroy(note, action: :destroy_note, actor: actor)
      end
      |> case do
        :ok -> {:ok, true}
        {:ok, _} -> {:ok, true}
        {:error, error} -> map_write_error(error)
      end
    end
  end

  defp fetch_accessible_course(actor, course_id) when is_binary(course_id) do
    case fetch_course(course_id) do
      nil ->
        {:error, :course_not_accessible}

      course ->
        case Authorization.authorize(actor, course.workspace_id, course.id) do
          :ok -> {:ok, course}
          _ -> {:error, :course_not_accessible}
        end
    end
  end

  defp fetch_accessible_course(_actor, _course_id), do: {:error, :course_not_accessible}

  defp fetch_course(course_id) do
    Course
    |> Ash.Query.for_read(:get_by_id, %{id: course_id})
    |> Ash.read_one(authorize?: false)
    |> case do
      {:ok, %Course{} = course} -> course
      _ -> nil
    end
  end

  defp fetch_owned_note(actor, note_id) when is_binary(note_id) do
    CourseNote
    |> Ash.Query.filter(id == ^note_id)
    |> Ash.read_one(authorize?: false)
    |> case do
      {:ok, %CourseNote{user_id: user_id} = note} when user_id == actor.id -> {:ok, note}
      _ -> {:error, :not_found}
    end
  end

  defp fetch_owned_note(_actor, _note_id), do: {:error, :not_found}

  defp find_active_note(actor, course_id, issue_id, dedupe_hash) do
    CourseNote
    |> Ash.Query.filter(
      user_id == ^actor.id and course_id == ^course_id and issue_id == ^issue_id and
        dedupe_hash == ^dedupe_hash and kind == :note and is_nil(deleted_at)
    )
    |> Ash.read_one(authorize?: false)
    |> case do
      {:ok, %CourseNote{} = note} -> note
      _ -> nil
    end
  end

  defp duplicate_other_note?(actor, note, dedupe_hash) do
    CourseNote
    |> Ash.Query.filter(
      user_id == ^actor.id and course_id == ^note.course_id and issue_id == ^note.issue_id and
        dedupe_hash == ^dedupe_hash and kind == :note and id != ^note.id
    )
    |> Ash.read_one(authorize?: false)
    |> case do
      {:ok, %CourseNote{}} -> true
      _ -> false
    end
  end

  defp recover_unique_note(actor, course_id, issue_id, dedupe_hash, _error) do
    case find_active_note(actor, course_id, issue_id, dedupe_hash) do
      nil -> {:error, :duplicate_note}
      note -> {:ok, note}
    end
  end

  defp latest_revision_id(course) do
    case Curriculum.latest_revision(course.workspace_id, course.id) do
      {:ok, %{id: id}} -> id
      _ -> nil
    end
  end

  defp validate_text(text) when is_binary(text) do
    trimmed = String.trim(text)

    cond do
      trimmed == "" -> {:error, :invalid_text}
      String.length(trimmed) > @max_text -> {:error, :invalid_text}
      true -> :ok
    end
  end

  defp validate_text(_text), do: {:error, :invalid_text}

  defp validate_issue(issue_id) when is_binary(issue_id) do
    case String.trim(issue_id) do
      "" -> {:error, :invalid_issue}
      trimmed -> {:ok, trimmed}
    end
  end

  defp validate_issue(_issue_id), do: {:error, :invalid_issue}

  defp blank_to_nil(nil), do: nil

  defp blank_to_nil(value) when is_binary(value) do
    case String.trim(value) do
      "" -> nil
      trimmed -> trimmed
    end
  end

  defp blank_to_nil(_value), do: nil

  defp dedupe_hash(text, source_material_id) do
    normalized =
      text
      |> String.trim()
      |> String.replace(~r/\s+/u, " ")

    :crypto.hash(:sha256, normalized <> "\0" <> (source_material_id || ""))
    |> Base.encode16(case: :lower)
  end

  defp map_write_error(%Ash.Error.Invalid{} = error) do
    if Enum.any?(error.errors, &match?(%Ash.Error.Changes.InvalidAttribute{}, &1)) do
      {:error, :invalid_text}
    else
      {:error, :duplicate_note}
    end
  end

  defp map_write_error(_error), do: {:error, :duplicate_note}

  defp find_issue(content, issue_id) do
    content
    |> Content.issues()
    |> Enum.find(fn issue -> issue["id"] == issue_id end)
  end

  defp all_required_mastered?(objectives, issue_id) do
    issue_objectives =
      Enum.filter(objectives, fn objective ->
        objective.issue_id == issue_id and objective.required
      end)

    issue_objectives != [] and
      Enum.all?(issue_objectives, fn objective -> objective.mastery == "mastered" end)
  end

  defp retro_key(course, revision_id, issue_id) do
    revision = revision_id || "unversioned"
    "retro:#{course.workspace_id}:#{course.id}:#{revision}:#{issue_id}"
  end

  defp find_retro(retro_key) do
    CourseNote
    |> Ash.Query.filter(retro_key == ^retro_key and kind == :retro)
    |> Ash.read_one(authorize?: false)
    |> case do
      {:ok, %CourseNote{} = note} -> note
      _ -> nil
    end
  end

  defp create_retro(actor, course, revision_id, issue, retro_key, objectives) do
    text = retro_text(issue, objectives)

    attrs = %{
      workspace_id: course.workspace_id,
      user_id: actor.id,
      course_id: course.id,
      course_revision_id: revision_id,
      issue_id: issue["id"],
      kind: :retro,
      text: text,
      retro_key: retro_key
    }

    CourseNote
    |> Ash.Changeset.for_create(:create_note, attrs, actor: actor)
    |> Ash.create()
    |> case do
      {:ok, note} ->
        {:ok, note}

      {:error, _error} ->
        case find_retro(retro_key) do
          %CourseNote{deleted_at: %DateTime{}} -> {:ok, nil}
          %CourseNote{} = note -> {:ok, note}
          nil -> {:error, :duplicate_note}
        end
    end
  end

  defp retro_text(issue, objectives) do
    titles =
      objectives
      |> Enum.filter(fn objective ->
        objective.issue_id == issue["id"] and objective.required and
          objective.mastery == "mastered"
      end)
      |> Enum.map(& &1.title)
      |> Enum.reject(&is_nil/1)

    title = issue["title"] || issue["id"] || "Issue"
    completed_at = DateTime.utc_now() |> DateTime.to_iso8601()

    "【复盘】#{title}\n已完成必修目标：#{Enum.join(titles, "、")}\n完成时间：#{completed_at}"
  end
end
