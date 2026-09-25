defmodule Cgc2046.Notifications.Fanout do
  @moduledoc """
  通知分发面：收件人解析（recipient resolution）+ 通知入队（Oban deliver）的唯一归属。

  （2026-08-14 通知分发收敛，架构评审候选①）

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
  （本次入队条数），metadata `%{status: :ok | :skipped | :error, template_key, error}`。
  `:skipped` 表示收件人零身份、未入队（#406，告警可见）。
  """

  require Ash.Query
  require Logger

  alias Cgc2046.Accounts.{Role, UserIdentity, WorkspaceMembership}
  alias Cgc2046.Notifications.{Delivery, NotificationWorker}

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

  @doc "批量解析多用户的平台身份；无身份用户不会出现在结果中。"
  @spec identities_for_users([String.t()]) :: %{optional(String.t()) => [UserIdentity.t()]}
  def identities_for_users([]), do: %{}

  def identities_for_users(user_ids) when is_list(user_ids) do
    user_ids = Enum.uniq(user_ids)

    UserIdentity
    |> Ash.Query.filter(user_id in ^user_ids)
    |> Ash.read!(authorize?: false)
    |> Enum.group_by(& &1.user_id)
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

  返回 `:ok`（成功、零身份跳过或 rescue 内化后）；telemetry status：
  `:ok` / `:skipped`（零身份，#406）/ `:error`。
  """
  @spec deliver(
          %{String.t() => [UserIdentity.t()]} | {String.t(), [UserIdentity.t()]},
          String.t(),
          map(),
          map(),
          :default | :reminder_7d | nil
        ) :: :ok
  def deliver(recipients, template_key, data, job_meta, unique \\ nil) do
    _ = deliver_with_receipt(recipients, template_key, data, job_meta, unique)
    :ok
  end

  @doc """
  与 `deliver/5` 具有相同 recipients/job 形状，但明确返回入队回执。
  `{:ok, count}` 中的 count 是 Oban 接受的任务数；无身份为 `{:ok, 0}`；
  任一任务拒绝或解析/入队异常返回 `{:error, :enqueue_failed}`。

  调用方若把业务标记与任务入队放在同一 Repo transaction，可据此决定是否
  提交标记；传统调用方继续使用返回 `:ok` 的 `deliver/5`。
  """
  @spec deliver_with_receipt(
          %{String.t() => [UserIdentity.t()]} | {String.t(), [UserIdentity.t()]},
          String.t(),
          map(),
          map(),
          :default | :reminder_7d | nil
        ) :: {:ok, non_neg_integer()} | {:error, :enqueue_failed}
  def deliver_with_receipt(recipients, template_key, data, job_meta, unique \\ nil) do
    unique = unique || unique_for(template_key)
    recipients = normalize_recipients(recipients)

    total =
      Enum.reduce(recipients, 0, fn {_user_id, identities}, acc ->
        acc + length(identities)
      end)

    # #406 B-1 修复：零身份不再静默丢弃（生产实证 enrollment.approved 因
    # identities=[] 永久丢失且无人知）。未迁键保持「warning + telemetry :skipped
    # + 不入队」；已迁耐久路径的键不再早退——零身份逐 user 落哨兵行（#847
    # Q5，观测由行承担，比 telemetry 更强）。
    if total == 0 and not durable?(template_key) do
      Logger.warning(
        "notification deliver skipped: no identities " <>
          "(template_key=#{template_key}, user_ids=#{inspect(Map.keys(recipients))}, " <>
          "job_meta=#{inspect(job_meta)})"
      )

      emit(:skipped, template_key, nil, 0)
      {:ok, 0}
    else
      case enqueue_notifications(recipients, template_key, data, job_meta, unique) do
        {:ok, count} ->
          emit(:ok, template_key, nil, count)
          {:ok, count}

        {:error, _reason} ->
          Logger.warning("notification deliver failed (#{template_key}): queue rejected a job")
          emit(:error, template_key, "enqueue_failed", 0)
          {:error, :enqueue_failed}
      end
    end
  rescue
    error ->
      Logger.warning("notification deliver failed (#{template_key}): #{Exception.message(error)}")

      emit(:error, template_key, Exception.message(error), 0)
      {:error, :enqueue_failed}
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

  defp enqueue_notifications(recipients, template_key, data, job_meta, unique) do
    if durable?(template_key) do
      durable_enqueue(recipients, template_key, data, job_meta)
    else
      oban_enqueue(recipients, template_key, data, job_meta, unique)
    end
  end

  # ── 耐久投递迁移（#847 PR-B，分批推进的过渡态） ----------------------------
  # 已迁键：解析身份后委托 Delivery.enqueue；未迁键仍走 NotificationWorker
  # 直插（收尾批次删除直插路径）。事件键派生公式与 issue #847 映射表逐条对应；
  # P2：最终幂等键 = template_key 前缀 + 事件键（Delivery 侧再叠加 user×身份）。

  @durable_keys MapSet.new([
                  # 批 1（报名/审批类）
                  "approval_result",
                  "enrollment_submitted",
                  "enrollment_completed",
                  "enrollment_check_in_code"
                ])

  defp durable?(template_key), do: MapSet.member?(@durable_keys, template_key)

  defp durable_enqueue(recipients, template_key, data, job_meta) do
    event_key = event_key(template_key, data, job_meta)
    meta = Map.put(job_meta, "idempotency_key", template_key <> ":" <> event_key)

    Enum.reduce_while(recipients, {:ok, 0}, fn {user_id, identities}, {:ok, count} ->
      :ok = Delivery.enqueue({user_id, identities}, template_key, data, meta)
      {:cont, {:ok, count + length(identities)}}
    end)
  end

  # 事件键派生（映射表逐条对应）。:from_meta 类 = 生产方信号幂等键直用
  # （emitter 规范 "<type>:<record_id>" 或支付侧 "<template>:<order_id>"）。
  defp event_key("approval_result", data, _job_meta),
    do: "approval.result:#{data["enrollment_id"]}:#{data["status"]}"

  defp event_key("enrollment_submitted", _data, job_meta),
    do: Map.fetch!(job_meta, "idempotency_key")

  defp event_key("enrollment_completed", _data, job_meta),
    do: Map.fetch!(job_meta, "idempotency_key")

  defp event_key("enrollment_check_in_code", _data, job_meta),
    do: Map.fetch!(job_meta, "idempotency_key")

  # 未迁键的既有直插路径（收尾批次整体删除）：逐身份插 NotificationWorker
  # job，去重靠 Oban unique 时间窗。
  defp oban_enqueue(recipients, template_key, data, job_meta, unique) do
    Enum.reduce_while(recipients, {:ok, 0}, fn {user_id, identities}, {:ok, count} ->
      Enum.reduce_while(identities, {:ok, count}, fn identity, {:ok, identity_count} ->
        case insert_notification(identity, user_id, template_key, data, job_meta, unique) do
          {:ok, _job} -> {:cont, {:ok, identity_count + 1}}
          {:error, reason} -> {:halt, {:error, reason}}
        end
      end)
      |> case do
        {:ok, updated_count} -> {:cont, {:ok, updated_count}}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
  end

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
    |> Oban.insert()
  end

  # status 取值：:ok / :skipped（零身份，#406）/ :error；metadata 原样透传。
  defp emit(status, template_key, error, count) do
    :telemetry.execute(@telemetry_event, %{count: count}, %{
      status: status,
      template_key: template_key,
      error: error
    })
  end
end
