defmodule Cgc2046.Flashback.WishEchoes do
  @moduledoc """
  许愿回响管理面：负责公开挂树资格、纯文本校验与显式生命周期迁移。

  所有写操作都在同一 Repo transaction 中锁定回响/愿望行，避免管理员并发操作
  绕过状态机或在愿望下架的同时发布。
  """

  require Ash.Query

  alias Cgc2046.Flashback.WishEcho
  alias Cgc2046.Notifications.Fanout
  alias Cgc2046.Repo

  @max_content_length 500

  @doc "PlatformAdmin 管理查询：包含所有状态和当前可通知附议数。"
  def list_for_admin(wish_id) do
    with {:ok, wish_uuid} <- cast_uuid(wish_id),
         :ok <- wish_exists(wish_uuid) do
      echoes =
        WishEcho
        |> Ash.Query.filter(wish_id == ^wish_uuid)
        |> Ash.Query.sort(inserted_at: :asc, id: :asc)
        |> Ash.read!(authorize?: false, page: false)

      {:ok,
       %{
         echoes: echoes,
         current_notifiable_endorsement_count: notifiable_endorsement_count(wish_uuid)
       }}
    else
      _ -> {:error, wish_not_found()}
    end
  end

  @doc """
  批量生成公开 Echo 投影。只返回当前仍公开挂树且可见的愿望，不把草稿、
  撤回记录或发布者/附议者身份带入任何非 admin 读面。
  """
  @spec public_by_wish_ids([String.t()]) :: %{optional(String.t()) => map()}
  def public_by_wish_ids([]), do: %{}

  def public_by_wish_ids(wish_ids) when is_list(wish_ids) do
    ids =
      wish_ids
      |> Enum.uniq()
      |> Enum.map(&Repo.uuid!/1)

    %{rows: rows} =
      Repo.query!(
        """
        SELECT e.wish_id::text, e.id::text, e.content, e.status,
               e.published_at, e.corrected_at
        FROM flashback_wish_echoes e
        JOIN flashback_wishes w ON w.id = e.wish_id
        WHERE e.wish_id = ANY($1::uuid[])
          AND e.status IN ('published', 'corrected')
          AND w.visibility = 'public'
          AND w.listed_at IS NOT NULL
          AND w.hidden_at IS NULL
          AND w.deleted_at IS NULL
        ORDER BY e.wish_id, e.published_at, e.id
        """,
        [ids]
      )

    rows
    |> Enum.group_by(fn [wish_id | _] -> wish_id end)
    |> Map.new(fn {wish_id, wish_rows} ->
      echoes =
        Enum.map(wish_rows, fn [
                                 _wish_id,
                                 id,
                                 content,
                                 status,
                                 published_at,
                                 corrected_at
                               ] ->
          %{
            id: id,
            content: content,
            status: status,
            published_at: to_utc_datetime(published_at),
            corrected_at: to_utc_datetime(corrected_at)
          }
        end)

      {wish_id,
       %{
         latest_echo: List.last(echoes),
         echo_count: length(echoes),
         echoes: echoes
       }}
    end)
  end

  @doc "为当前公开挂树且可见的愿望创建草稿。"
  def create_draft(wish_id, content) do
    with {:ok, wish_uuid} <- cast_uuid(wish_id),
         {:ok, content} <- validate_content(content) do
      transaction(fn ->
        with :ok <- lock_eligible_wish(wish_uuid) do
          WishEcho
          |> Ash.Changeset.for_create(:create_draft, %{wish_id: wish_uuid, content: content})
          |> Ash.create(authorize?: false)
        end
      end)
    else
      {:error, :invalid_content} -> {:error, invalid_content()}
      _ -> {:error, wish_not_found()}
    end
  end

  @doc "草稿正文可反复修改；已发布或已撤回回响不可走草稿写面。"
  def update_draft(echo_id, content) do
    with {:ok, content} <- validate_content(content) do
      transaction(fn ->
        with {:ok, echo} <- lock_echo(echo_id),
             :ok <- require_status(echo, "draft") do
          echo
          |> Ash.Changeset.for_update(:update_draft, %{content: content})
          |> Ash.update(authorize?: false)
        end
      end)
    else
      {:error, :invalid_content} -> {:error, invalid_content()}
    end
  end

  @doc "首次发布草稿。发布时再次锁定并验证愿望当前仍公开、挂树且可见。"
  def publish(echo_id, admin_user_id) do
    transaction(fn ->
      with {:ok, echo} <- lock_echo(echo_id),
           :ok <- require_status(echo, "draft"),
           :ok <- lock_eligible_wish(echo.wish_id) do
        now = DateTime.utc_now() |> DateTime.truncate(:microsecond)

        with {:ok, published_echo} <-
               echo
               |> Ash.Changeset.for_update(:publish, %{
                 published_at: now,
                 published_by_user_id: admin_user_id
               })
               |> Ash.update(authorize?: false),
             {:ok, _enqueued_count} <- enqueue_echo_notifications(published_echo) do
          {:ok, published_echo}
        end
      end
    end)
  end

  @doc "已发布回响可原地更正；更正不改首次发布时间，也不创建新版本。"
  def correct(echo_id, content) do
    with {:ok, content} <- validate_content(content) do
      transaction(fn ->
        with {:ok, echo} <- lock_echo(echo_id),
             :ok <- require_status(echo, ["published", "corrected"]) do
          now = DateTime.utc_now() |> DateTime.truncate(:microsecond)

          echo
          |> Ash.Changeset.for_update(:correct, %{
            content: content,
            corrected_at: now
          })
          |> Ash.update(authorize?: false)
        end
      end)
    else
      {:error, :invalid_content} -> {:error, invalid_content()}
    end
  end

  @doc "发布或已更正回响可撤回；撤回是终态。"
  def revoke(echo_id) do
    transaction(fn ->
      with {:ok, echo} <- lock_echo(echo_id),
           :ok <- require_status(echo, ["published", "corrected"]) do
        now = DateTime.utc_now() |> DateTime.truncate(:microsecond)

        echo
        |> Ash.Changeset.for_update(:revoke, %{revoked_at: now})
        |> Ash.update(authorize?: false)
      end
    end)
  end

  defp lock_echo(echo_id) do
    with {:ok, echo_uuid} <- cast_uuid(echo_id) do
      case Repo.query!(
             "SELECT id FROM flashback_wish_echoes WHERE id = $1 FOR UPDATE",
             [Repo.uuid!(echo_uuid)]
           ).rows do
        [[_id]] ->
          case Ash.get(WishEcho, echo_uuid, authorize?: false) do
            {:ok, %WishEcho{} = echo} -> {:ok, echo}
            _ -> {:error, echo_not_found()}
          end

        [] ->
          {:error, echo_not_found()}
      end
    else
      _ -> {:error, echo_not_found()}
    end
  end

  defp lock_eligible_wish(wish_id) do
    with {:ok, wish_uuid} <- cast_uuid(wish_id) do
      case Repo.query!(
             """
             SELECT id
             FROM flashback_wishes
             WHERE id = $1
               AND visibility = 'public'
               AND listed_at IS NOT NULL
               AND hidden_at IS NULL
               AND deleted_at IS NULL
             FOR UPDATE
             """,
             [Repo.uuid!(wish_uuid)]
           ).rows do
        [[_id]] -> :ok
        [] -> {:error, wish_not_found()}
      end
    else
      _ -> {:error, wish_not_found()}
    end
  end

  defp wish_exists(wish_id) do
    case Repo.query!("SELECT id FROM flashback_wishes WHERE id = $1", [Repo.uuid!(wish_id)]).rows do
      [[_id]] -> :ok
      [] -> {:error, wish_not_found()}
    end
  end

  defp notifiable_endorsement_count(wish_id) do
    %{rows: [[count]]} =
      Repo.query!(
        """
        SELECT COUNT(*)
        FROM flashback_wish_endorsements
        WHERE wish_id = $1
          AND notify = TRUE
          AND user_id IS NOT NULL
          AND echo_notification_used_at IS NULL
        """,
        [Repo.uuid!(wish_id)]
      )

    count
  end

  defp enqueue_echo_notifications(echo) do
    endorsement_rows =
      Repo.query!(
        """
        SELECT id, user_id
        FROM flashback_wish_endorsements
        WHERE wish_id = $1
          AND notify = TRUE
          AND user_id IS NOT NULL
          AND echo_notification_used_at IS NULL
        ORDER BY id
        FOR UPDATE
        """,
        [Repo.uuid!(echo.wish_id)]
      ).rows

    recipients_by_user =
      endorsement_rows
      |> Enum.map(fn [_endorsement_id, user_id] -> Ecto.UUID.load!(user_id) end)
      |> Fanout.identities_for_users()

    Enum.reduce_while(endorsement_rows, {:ok, 0}, fn [endorsement_id, user_id],
                                                     {:ok, enqueued_count} ->
      user_id = Ecto.UUID.load!(user_id)
      identities = Map.get(recipients_by_user, user_id, [])

      if identities == [] do
        {:cont, {:ok, enqueued_count}}
      else
        endorsement_id = Ecto.UUID.load!(endorsement_id)

        data = %{
          "wish_id" => echo.wish_id,
          "endorsement_id" => endorsement_id,
          "content_preview" => String.slice(echo.content, 0, 20)
        }

        job_meta = %{
          "wish_id" => echo.wish_id,
          "endorsement_id" => endorsement_id
        }

        case Fanout.deliver_with_receipt(
               {user_id, identities},
               "flashback_wish_echo",
               data,
               job_meta
             ) do
          {:ok, count} when count > 0 ->
            case mark_echo_notification_used(endorsement_id) do
              :ok -> {:cont, {:ok, enqueued_count + count}}
              {:error, _reason} -> {:halt, {:error, :enqueue_failed}}
            end

          {:ok, 0} ->
            {:cont, {:ok, enqueued_count}}

          {:error, _reason} ->
            {:halt, {:error, :enqueue_failed}}
        end
      end
    end)
  end

  defp mark_echo_notification_used(endorsement_id) do
    case Repo.query!(
           """
           UPDATE flashback_wish_endorsements
           SET echo_notification_used_at = NOW()
           WHERE id = $1
             AND echo_notification_used_at IS NULL
           """,
           [Repo.uuid!(endorsement_id)]
         ).num_rows do
      1 -> :ok
      0 -> {:error, :already_used}
    end
  end

  defp require_status(%WishEcho{status: status}, expected) when status == expected, do: :ok

  defp require_status(%WishEcho{status: status}, allowed) when is_list(allowed) do
    if status in allowed, do: :ok, else: {:error, invalid_transition()}
  end

  defp require_status(%WishEcho{}, _expected), do: {:error, invalid_transition()}

  defp validate_content(content) when is_binary(content) do
    trimmed = String.trim(content)

    if trimmed != "" and String.length(trimmed) <= @max_content_length do
      {:ok, trimmed}
    else
      {:error, :invalid_content}
    end
  end

  defp validate_content(_), do: {:error, :invalid_content}

  defp cast_uuid(value) do
    case Ecto.UUID.cast(value) do
      {:ok, uuid} -> {:ok, uuid}
      :error -> {:error, :invalid_uuid}
    end
  end

  defp to_utc_datetime(%DateTime{} = datetime), do: datetime
  defp to_utc_datetime(%NaiveDateTime{} = datetime), do: DateTime.from_naive!(datetime, "Etc/UTC")
  defp to_utc_datetime(nil), do: nil

  defp transaction(fun) do
    case Repo.transaction(fn ->
           case fun.() do
             {:ok, value} -> value
             {:error, reason} -> Repo.rollback(reason)
           end
         end) do
      {:ok, value} -> {:ok, value}
      {:error, reason} -> {:error, reason}
    end
  end

  defp wish_not_found,
    do: %{code: "flashback_wish_not_found", message: "愿望不存在。"}

  defp echo_not_found,
    do: %{code: "flashback_wish_echo_not_found", message: "回响不存在。"}

  defp invalid_content,
    do: %{code: "flashback_wish_echo_invalid_content", message: "回响正文须为 1–500 字纯文本。"}

  defp invalid_transition,
    do: %{code: "flashback_wish_echo_invalid_transition", message: "当前回响状态不允许该操作。"}
end
