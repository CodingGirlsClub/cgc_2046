defmodule Cgc2046.Events.Moderators do
  @moduledoc """
  Event 主理人关联的唯一管理面。主理人须为目标 Workspace 成员（#558 /
  #542 决策 A1：成员前提由 `EventModerator.assign` 的资源级校验承载，
  `ModeratorMembershipValidation`）；管理权限由 Event 所属 Workspace 的
  反向不变量（#561）：成员离台（`WorkspaceMembership.destroy`）同事务级联
  撤销其在本台的全部指派（`Events.Changes.RevokeModerationsOnLeave`，逐行
  标记）——「主理人 ⇒ 成员」在指派、存续、离台三个时点都成立。

  指派锚（#537）：`assign/4` 的 `user_id` 参数接受邮箱 / CGC 编号 / 用户
  ID 三种精确锚（`Accounts.UserResolution` 单源解析后落 UUID，存储不变；
  权限门先于解析——越权者只拿 forbidden，探测不到 user_not_found）。
  """

  require Ash.Query
  require Logger

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

  # #537 回显投影：平铺 calculation 单查询 LEFT JOIN（BypassReads 平铺先例），
  # 调用方（GraphQL / MCP）自选字段，无 N+1。
  @display_calculations [
    :user_display_name,
    :user_member_number,
    :assigned_by_display_name,
    :assigned_by_member_number
  ]

  def list(event_id, workspace_id, actor) do
    with {:ok, event} <- Ash.get(Event, event_id, authorize?: false, tenant: workspace_id),
         true <- event && can_read?(actor, event) do
      EventModerator
      |> Ash.Query.filter(event_id == ^event_id)
      |> Ash.Query.sort(assigned_at: :asc, id: :asc)
      |> Ash.Query.load(@display_calculations)
      |> Ash.read(authorize?: false, tenant: workspace_id)
    else
      _ -> {:error, :forbidden}
    end
  end

  # user_id 参数为三锚点（#537）：email / CGC-XXXXXX / UUID，域内 resolve 后
  # 落 UUID——create、Fanout、审计全部消费解析后的 user.id，存储不变。
  def assign(event_id, workspace_id, user_id, actor) do
    with :ok <- manage?(actor, workspace_id),
         {:ok, event} <- fetch_event(event_id, workspace_id, actor),
         {:ok, user} <- Cgc2046.Accounts.UserResolution.resolve(user_id) do
      case EventModerator
           |> Ash.Changeset.for_create(:assign, %{
             workspace_id: workspace_id,
             event_id: event.id,
             user_id: user.id,
             assigned_by: actor.id
           })
           |> Ash.create(actor: actor, tenant: workspace_id) do
        {:ok, record} ->
          Cgc2046.Notifications.Fanout.deliver(
            {user.id, Cgc2046.Notifications.Fanout.identities(user.id)},
            "event_moderator_assigned",
            %{"event_id" => event.id, "title" => event.title},
            %{"event_id" => event.id}
          )

          # 回显就绪（#537）：create 结果的 calculation 是 NotLoaded，GraphQL
          # result 直接序列化会炸——域出口统一 load（与 list 同款投影）
          Ash.load(record, @display_calculations, authorize?: false)

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
        nil ->
          {:error, :not_found}

        record ->
          with :ok <- Ash.destroy(record, actor: actor, tenant: workspace_id) do
            notify_removed(record, workspace_id)
          end
      end
    else
      {:error, :forbidden} -> {:error, :forbidden}
      {:error, _} = error -> error
    end
  end

  # #538 移除通知：仅主动移除（本域函数，GraphQL/MCP 共用）发送——级联撤销
  # （RevokeModerationsOnLeave 裸 SQL DELETE）不经本路径，语义上「成员移除」
  # 另有语境，不逐行轰炸。Fanout.deliver 自身 rescue 内化（恒 :ok）；event
  # 读取失败（FK 保证存在，仅瞬断可达）不回滚已成功的移除——通知丢一条由
  # 管理面回读兜底，移除失败重试才是坏语义；丢弃留 warning（#606 终态丢弃
  # 可观测纪律：丢了必须有可 grep 的痕迹）。
  defp notify_removed(record, workspace_id) do
    case Ash.get(Event, record.event_id, authorize?: false, tenant: workspace_id) do
      {:ok, event} ->
        Cgc2046.Notifications.Fanout.deliver(
          {record.user_id, Cgc2046.Notifications.Fanout.identities(record.user_id)},
          "event_moderator_removed",
          %{"event_id" => event.id, "title" => event.title},
          %{"event_id" => event.id}
        )

        :ok

      {:error, error} ->
        Logger.warning(
          "event_moderator_removed not delivered: event fetch failed " <>
            "(event_id=#{record.event_id} user_id=#{record.user_id} reason=#{inspect(error)})"
        )

        :ok
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

  # 读面放宽（U2 治理详情）：平台管理员读主理人清单不要求本台成员身份——与
  # Event/Course 读 policy 的 PlatformAdmin 放行同口径（治理排查「这场谁在管」
  # 不必先入台）。**只放宽读**：写面 assign/remove 仍走 manage?/2，非成员平台
  # 管理员不获得主理人指派权（R7 无旁路）。
  defp can_read?(actor, event),
    do:
      can_moderate?(actor, event) or
        Cgc2046.Accounts.Policies.PlatformAdmin.platform_admin?(actor)

  defp manage?(actor, workspace_id),
    do: if(Rbac.manage?(actor, workspace_id), do: :ok, else: {:error, :forbidden})

  defp fetch_event(event_id, workspace_id, actor),
    do: Ash.get(Event, event_id, actor: actor, tenant: workspace_id)
end
