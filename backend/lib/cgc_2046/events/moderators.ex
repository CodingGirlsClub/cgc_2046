defmodule Cgc2046.Events.Moderators do
  @moduledoc """
  Event 主理人关联的唯一管理面。主理人须为目标 Workspace 成员（#558 /
  #542 决策 A1：成员前提由 `EventModerator.assign` 的资源级校验承载，
  `ModeratorMembershipValidation`）；管理权限由 Event 所属 Workspace 的
  Owner/Admin 持有，关联本身只提供 Event 级「成员里谁管这场」的指派。

  反向不变量（#561）：成员离台（`WorkspaceMembership.destroy`）同事务级联
  撤销其在本台的全部指派（`Events.Changes.RevokeModerationsOnLeave`，逐行
  `AdminActionLog :event_moderator_remove` 带 `cascade: "membership_destroy"`
  标记）——「主理人 ⇒ 成员」在指派、存续、离台三个时点都成立。
  """

  require Ash.Query
  alias Cgc2046.Accounts.Rbac
  alias Cgc2046.Events.{Event, EventModerator}

  def ensure_assigned(event, user_id) do
    attrs = %{
      workspace_id: event.workspace_id,
      event_id: event.id,
      user_id: user_id,
      assigned_by: user_id
    }

    case EventModerator
         |> Ash.Changeset.for_create(:assign, attrs)
         |> Ash.create(actor: %{id: user_id}, authorize?: false, tenant: event.workspace_id) do
      {:ok, _} ->
        :ok

      {:error, %Ash.Error.Invalid{} = error} ->
        if already_assigned?(error),
          do: :ok,
          else: {:error, error}

      {:error, error} ->
        {:error, error}
    end
  end

  # 重复指派（幂等）判据 = `EventModerator.handle_write_error/2` 映射出的稳定 code。
  # 迁移 20260916210000 对齐索引名后，unique 冲突不再落 `Ecto.ConstraintError`（旧实现
  # 靠匹配错误原文里的注册约束名 "unique_event_user" 判定，改名后该原文消失 ⇒ 判据必然
  # 失效），故改按 code（范式同 payment_expiry_worker.ex 的 expected_race?/1）。DB 类
  # 失败走同族 BusinessError 但 code = "database_error"——那是硬失败，绝不吞成幂等成功。
  defp already_assigned?(%Ash.Error.Invalid{errors: errors}) do
    Enum.any?(errors, fn
      %Cgc2046.Errors.BusinessError{code: "event_moderator_already_assigned"} -> true
      _ -> false
    end)
  end

  def list(event_id, workspace_id, actor) do
    with {:ok, event} <- Ash.get(Event, event_id, authorize?: false, tenant: workspace_id),
         true <- event && can_moderate?(actor, event) do
      EventModerator
      |> Ash.Query.filter(event_id == ^event_id)
      |> Ash.Query.sort(assigned_at: :asc, id: :asc)
      |> Ash.read(authorize?: false, tenant: workspace_id)
    else
      _ -> {:error, :forbidden}
    end
  end

  def assign(event_id, workspace_id, user_id, actor) do
    with :ok <- manage?(actor, workspace_id),
         {:ok, event} <- fetch_event(event_id, workspace_id, actor),
         {:ok, _user} <- fetch_user(user_id, actor) do
      case EventModerator
           |> Ash.Changeset.for_create(:assign, %{
             workspace_id: workspace_id,
             event_id: event.id,
             user_id: user_id,
             assigned_by: actor.id
           })
           |> Ash.create(actor: actor, tenant: workspace_id) do
        {:ok, record} ->
          Cgc2046.Notifications.Fanout.deliver(
            {user_id, Cgc2046.Notifications.Fanout.identities(user_id)},
            "event_moderator_assigned",
            %{"event_id" => event.id, "title" => event.title},
            %{"event_id" => event.id}
          )

          {:ok, record}

        other ->
          other
      end
    else
      {:error, :forbidden} -> {:error, :forbidden}
      {:error, _} = error -> error
    end
  end

  def remove(moderator_id, workspace_id, actor) do
    with :ok <- manage?(actor, workspace_id),
         {:ok, moderator} <-
           Ash.get(EventModerator, moderator_id,
             actor: actor,
             tenant: workspace_id,
             not_found_error?: false
           ) do
      case moderator do
        nil -> {:error, :not_found}
        record -> Ash.destroy(record, actor: actor, tenant: workspace_id)
      end
    else
      {:error, :forbidden} -> {:error, :forbidden}
      {:error, _} = error -> error
    end
  end

  def moderator?(user_id, event_id, workspace_id) do
    EventModerator
    |> Ash.Query.filter(event_id == ^event_id and user_id == ^user_id)
    |> Ash.read_one(authorize?: false, tenant: workspace_id)
    |> case do
      {:ok, nil} -> false
      {:ok, _} -> true
      _ -> false
    end
  end

  # 不变量（#558）：moderator? 为真 ⇒ 该用户是 event.workspace_id 的成员
  # （assign 写边界的成员校验承载）；本函数形状不变——判定仍正确，且现在
  # 隐含成员身份。
  def can_moderate?(actor, event) do
    Rbac.manage?(actor, event.workspace_id) or moderator?(actor.id, event.id, event.workspace_id)
  end

  defp manage?(actor, workspace_id),
    do: if(Rbac.manage?(actor, workspace_id), do: :ok, else: {:error, :forbidden})

  defp fetch_event(event_id, workspace_id, actor),
    do: Ash.get(Event, event_id, actor: actor, tenant: workspace_id)

  defp fetch_user(user_id, actor),
    do: Cgc2046.Accounts.User |> Ash.get(user_id, actor: actor, authorize?: false)
end
