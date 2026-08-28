defmodule Cgc2046.Notifications.Fanout do
  @moduledoc """
  通知分发面：收件人解析（recipient resolution）+ 通知入队（Oban deliver）的唯一归属。

  （2026-08-14 通知分发收敛，架构评审候选①；plan
  docs/plans/2026-08-14-004-notification-fanout-deepening.md Q1-Q12 全锁定）

  收敛前，`managed_identities_by_user` 三份同构拷贝（Notifications.Subscriber /
  SpeakerSubscriber / ApprovalReminderWorker）、`identities_for_user` 两份、
  `insert_notification` 两份、`@reminder_unique` 一份散落四方；本 module 收编为
  **唯一实现**。Notifications.Subscriber 的公共入队面删除（异步计划 Q4 backlog），
  退化为纯订阅方；发送侧 Notifications.Service / NotificationWorker 不动。

  ## 两段式 interface（Q2/Q8）

  - `managers/2`：workspace 内目标角色成员的平台身份，按 `user_id` 分组返回
    `%{user_id => [identity]}`。**按工作台预取一次、逐条记录复用**是
    ApprovalReminderWorker 消 N+1 的形状，故 resolution 独立成段可缓存；
  - `identities/1`：单用户全部平台身份 → `[identity]`；
  - `deliver/5`：把 resolution 结果（map 或 `{user_id, [identity]}`）逐
    （user_id × identity）入队 NotificationWorker，args 形状（`identity_uid` /
    `platform` / `template_key` / `data` 与 `job_meta` 合并）由本 module 唯一持有。

  ## 收件人选择器是数据不是谓词（Q3）

  - `:manage`：内部走 `Role.manage_roles/0` 唯一真源（owner/admin，与
    `Role.manage_role?/1` 同源）——`@manage_roles` 变更时订阅方与 worker 自动跟随；
  - `{:roles, [...]}`：显式窄集（如赞助 Workspace 级仅 Owner，拍板 #4）。

  ## unique 命名预设（Q9）

  - `:default`：不覆盖，走 NotificationWorker 自身 7 天全 args unique；
  - `:reminder_7d`：提醒任务的去重窗口（自 Notifications.Subscriber `@reminder_unique`
    收编，唯一真源）——discarded/cancelled 释放名额（失败后下拍可重建），
    completed/在途仍阻塞重复（#7）。

  未显式传 unique（缺省）时按 `template_key` 查 `NotificationWorker.type/1` 的
  unique 预设（2026-08-18 架构深化候选 D，D3）：approval_reminder /
  learning_stagnation 由通知类型 registry 声明 `:reminder_7d`，其余类型
  `:default`；type nil（未知键）→ `:default`。显式传参（`:default` |
  `:reminder_7d`）仍兼容。

  ## 错误内化（Q6）

  入队失败 rescue 不崩、必 Logger.warning + telemetry（`status: :error`）后返回
  `:ok`——静默跳过语义与收敛前各调用方一致（纯收敛，不改行为）。

  ## telemetry（Q10）

  事件 `[:cgc2046, :notification_fanout, :deliver]`：measurements `%{count: n}`
  （本次入队条数），metadata `%{status: :ok | :error, template_key, error}`。
  """

  require Ash.Query
  require Logger

  alias Cgc2046.Accounts.{Role, UserIdentity, WorkspaceMembership}
  alias Cgc2046.Notifications.NotificationWorker

  @telemetry_event [:cgc2046, :notification_fanout, :deliver]

  # 提醒任务的去重窗口（唯一真源）：discarded/cancelled 释放名额（失败后下拍可
  # 重建），completed/在途仍阻塞重复（#7）。
  @reminder_unique [
    period: 604_800,
    fields: [:worker, :args],
    states: [:scheduled, :available, :executing, :retryable, :completed]
  ]

  @doc """
  解析 workspace 内目标角色成员（selector 见 moduledoc）的平台身份，
  按 `user_id` 分组。每工作台一次读取（调用方预取后逐条记录复用，消 N+1）。

  无目标角色成员 → 返回空 map（调用方不必区分「无人」与「有人无身份」）。
  """
  @spec managers(term(), :manage | {:roles, [atom()]}) :: %{String.t() => [UserIdentity.t()]}
  def managers(workspace_id, selector \\ :manage) do
    managed_ids = managed_member_ids(workspace_id, selector)

    case managed_ids do
      [] ->
        %{}

      managed_ids ->
        UserIdentity
        |> Ash.Query.filter(user_id in ^managed_ids)
        |> Ash.read!(authorize?: false)
        |> Enum.group_by(& &1.user_id)
    end
  end

  @doc "单用户的全部平台身份（逐身份入队，同用户多身份不折叠——#3）。"
  @spec identities(String.t()) :: [UserIdentity.t()]
  def identities(user_id) do
    UserIdentity
    |> Ash.Query.filter(user_id == ^user_id)
    |> Ash.read!(authorize?: false)
  end

  @doc """
  逐（user_id × identity）入队 NotificationWorker 通知任务。

  - `recipients`：`managers/2` 返回的 `%{user_id => [identity]}`，或单用户
    `{user_id, [identity]}`（两种形状归一，Q8）；
  - `template_key` / `data`：通知模板与模板数据（写入 job args）；
  - `job_meta`：与 `user_id` / `identity_uid` / `platform` / `template_key` /
    `data` 合并为最终 args（幂等键等由调用方放入 `job_meta`）；
  - `unique`：命名预设（见 moduledoc）；缺省 nil 时按 `template_key` 查
    `NotificationWorker.type/1` 的 unique 预设（默认 `:default`）。

  返回 `:ok`（成功或 rescue 内化后）；成功/失败均发 telemetry。
  """
  @spec deliver(
          %{String.t() => [UserIdentity.t()]} | {String.t(), [UserIdentity.t()]},
          String.t(),
          map(),
          map(),
          :default | :reminder_7d | nil
        ) :: :ok
  def deliver(recipients, template_key, data, job_meta, unique \\ nil) do
    unique = unique || unique_for(template_key)

    count =
      recipients
      |> normalize_recipients()
      |> Enum.reduce(0, fn {user_id, identities}, acc ->
        Enum.reduce(identities, acc, fn identity, acc2 ->
          insert_notification(identity, user_id, template_key, data, job_meta, unique)
          acc2 + 1
        end)
      end)

    emit(:ok, template_key, nil, count)
    :ok
  rescue
    error ->
      Logger.warning("notification deliver failed (#{template_key}): #{Exception.message(error)}")

      emit(:error, template_key, Exception.message(error), 0)
      :ok
  end

  defp normalize_recipients(recipients) when is_map(recipients), do: recipients

  defp normalize_recipients({user_id, identities})
       when is_binary(user_id) and is_list(identities),
       do: %{user_id => identities}

  # unique 缺省查表（D3）：按 template_key 读 NotificationWorker.type/1 的 unique
  # 预设；type nil 或无 unique 字段 → :default。显式传参不走此分支（签名兼容）。
  defp unique_for(template_key) do
    case NotificationWorker.type(template_key) do
      %{unique: preset} when preset in [:default, :reminder_7d] -> preset
      _ -> :default
    end
  end

  # role_filter 收窄收件人：`:manage` 走 Role.manage_roles/0 唯一真源，
  # `{:roles, roles}` 显式窄集（赞助 Workspace 级 = 仅 Owner，拍板 #4）。
  defp managed_member_ids(workspace_id, selector) do
    role_filter = manage_roles(selector)

    WorkspaceMembership
    |> Ash.Query.load(:roles)
    |> Ash.read!(tenant: workspace_id, authorize?: false)
    |> Enum.filter(fn membership ->
      membership.roles
      |> Enum.map(& &1.name)
      |> Enum.any?(&(&1 in role_filter))
    end)
    |> Enum.map(& &1.user_id)
    |> Enum.uniq()
  end

  defp manage_roles(:manage), do: Role.manage_roles()
  defp manage_roles({:roles, roles}), do: roles

  # args 携带 identity_uid：同用户同平台多身份不被 args-unique 折叠，
  # 发送侧按该身份精确投递（#3）。
  defp insert_notification(identity, user_id, template_key, data, job_meta, unique) do
    args =
      job_meta
      |> Map.merge(%{
        "user_id" => user_id,
        "identity_uid" => identity.uid,
        "platform" => to_string(identity.provider),
        "template_key" => template_key,
        "data" => data
      })

    case unique do
      :default -> NotificationWorker.new(args)
      :reminder_7d -> NotificationWorker.new(args, unique: @reminder_unique)
    end
    |> Oban.insert!()
  end

  defp emit(status, template_key, error, count) do
    :telemetry.execute(@telemetry_event, %{count: count}, %{
      status: status,
      template_key: template_key,
      error: error
    })
  end
end
