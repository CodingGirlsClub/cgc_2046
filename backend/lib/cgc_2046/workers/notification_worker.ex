defmodule Cgc2046.Workers.NotificationWorker do
  @moduledoc """
  异步发送审批结果或提醒订阅消息。

  通知类型契约的唯一真源 = 本 module 的 `@notification_types` 表（经 `type/1` /
  `types/0` 公开读契约，2026-08-18 架构深化候选 D；plan
  docs/plans/2026-08-18-005-notification-type-registry.md D1-D8 全锁定）。
  生产方（subscriber/worker）仍自构建 data/job_meta 值（D4/D6），契约描述引用
  `type/1`；unique 预设由 NotificationFanout 缺省查表（D3）；提醒类类型的 stale
  重查由本 module 表驱动解释器统一判定（D2）。

  ## @notification_types 条目字段

  - `template_key`：通知类型键（config `:miniprogram_templates` 三平台 registry
    键集与表双射，D7 测试锚定）；
  - `id_key`：stale 重查的资源 id 在 data 中的键（不重查 = nil）；
  - `data_keys` / `job_meta_keys`：生产方构建 data / job_meta 的键集契约；
  - `unique`：NotificationFanout.deliver 缺省使用的 unique 预设
    （`:default` | `:reminder_7d`）；
  - `stale`：提醒类类型发送时重查规格 `{resource, required_status,
    :not_expired | :running}`（nil = 不重查）。
  """

  use Oban.Worker,
    queue: :notifications,
    max_attempts: 3,
    unique: [period: 604_800, fields: [:worker, :args], states: :all]

  alias Cgc2046.ApprovalDeadline
  alias Cgc2046.Events.Enrollment
  alias Cgc2046.Events.Sponsorship
  alias Cgc2046.NotificationService
  alias Cgc2046.Workflows.WorkflowRun

  # 通知类型契约表（AEW @expiry_specs 同款声明式规格先例，D1）。
  # approval_reminder 同键两行（enrollment_id / sponsorship_id）由 data 携带的
  # id_key 分派（原 stale_reminder?/1 三子句同款语义，行为红线逐条等价）。
  @notification_types [
    # 审批结果（既有路径）：不重查。
    %{
      template_key: "approval_result",
      id_key: nil,
      data_keys: ["status", "enrollment_id"],
      job_meta_keys: ["enrollment_id"],
      unique: :default,
      stale: nil
    },
    # 新待审批报名 → workspace Owner/Admin（request 策略）：不重查。
    %{
      template_key: "enrollment_submitted",
      id_key: nil,
      data_keys: ["enrollment_id", "title"],
      job_meta_keys: ["enrollment_id", "idempotency_key"],
      unique: :default,
      stale: nil
    },
    # 报名成功 → 报名学员本人：不重查。
    %{
      template_key: "enrollment_completed",
      id_key: nil,
      data_keys: ["enrollment_id", "title"],
      job_meta_keys: ["enrollment_id", "idempotency_key"],
      unique: :default,
      stale: nil
    },
    # Speaker 接受邀请 → workspace Owner/Admin：不重查。
    %{
      template_key: "speaker_accepted",
      id_key: nil,
      data_keys: ["speaker_invitation_id", "title"],
      job_meta_keys: ["speaker_invitation_id", "idempotency_key"],
      unique: :default,
      stale: nil
    },
    # 分享完成 → Owner/Admin + Speaker 本人（title 仅管理者面携带）：不重查。
    %{
      template_key: "speaker_completed",
      id_key: nil,
      data_keys: ["speaker_invitation_id", "title"],
      job_meta_keys: ["speaker_invitation_id", "idempotency_key"],
      unique: :default,
      stale: nil
    },
    # 48h 审批提醒（Enrollment 面，run-less 报名单属主）：发送时重查报名仍
    # pending 且 deadline 未过（F7 方案 A）。
    %{
      template_key: "approval_reminder",
      id_key: "enrollment_id",
      data_keys: ["enrollment_id", "approval_deadline"],
      job_meta_keys: ["enrollment_id"],
      unique: :reminder_7d,
      stale: {Enrollment, :pending, :not_expired}
    },
    # 48h 审批提醒（Sponsorship 面，E-3 #48 F7）：发送时重查赞助仍 pending 且
    # deadline 未过。
    %{
      template_key: "approval_reminder",
      id_key: "sponsorship_id",
      data_keys: ["sponsorship_id", "approval_deadline"],
      job_meta_keys: ["sponsorship_id"],
      unique: :reminder_7d,
      stale: {Sponsorship, :pending, :not_expired}
    },
    # 学习停滞提醒（E-7 #122）：发送时重查 learning run 仍 running。
    %{
      template_key: "learning_stagnation",
      id_key: "run_id",
      data_keys: ["enrollment_id", "run_id", "title"],
      job_meta_keys: ["run_id"],
      unique: :reminder_7d,
      stale: {WorkflowRun, :running, :running}
    },
    # 缴费闭环三模板（U10/KTD8/R22；payload 值构建见
    # Payments.NotificationTemplates.payment_data/1）：不重查。
    %{
      template_key: "payment_succeeded",
      id_key: nil,
      data_keys: ["order_id", "enrollment_id", "amount", "provider"],
      job_meta_keys: ["idempotency_key"],
      unique: :default,
      stale: nil
    },
    %{
      template_key: "refund_succeeded",
      id_key: nil,
      data_keys: ["order_id", "enrollment_id", "amount", "provider"],
      job_meta_keys: ["idempotency_key"],
      unique: :default,
      stale: nil
    },
    %{
      template_key: "refund_failed",
      id_key: nil,
      data_keys: ["order_id", "enrollment_id", "amount", "provider"],
      job_meta_keys: ["idempotency_key"],
      unique: :default,
      stale: nil
    },
    # organizer-payment U5/KTD6：收款到账 → workspace 管理者（逐笔实时，
    # R12）；payload 构建 = Payments.NotificationTemplates.receipt_data/2。
    %{
      template_key: "payment_received",
      id_key: nil,
      data_keys: ["order_id", "enrollment_id", "amount", "provider", "title", "tier_name"],
      job_meta_keys: ["idempotency_key"],
      unique: :default,
      stale: nil
    },
    # organizer-payment U5/KTD6：订单超时作废 → 报名人 + workspace 管理者
    # （R13；re_enrollable = 报名截止未过才承诺可重新报名）。
    %{
      template_key: "payment_expired",
      id_key: nil,
      data_keys: ["order_id", "enrollment_id", "amount", "provider", "title", "re_enrollable"],
      job_meta_keys: ["idempotency_key"],
      unique: :default,
      stale: nil
    }
  ]

  @impl Oban.Worker
  def perform(%Oban.Job{args: args}) do
    platform = String.to_existing_atom(args["platform"])

    if stale_reminder?(args) do
      :ok
    else
      case deliver(args, platform) do
        :ok ->
          :ok

        {:error, reason}
        when reason in [
               :consent_exhausted,
               :platform_identity_not_found,
               :platform_not_configured
             ] ->
          :ok

        {:error, reason} ->
          {:error, inspect(reason)}
      end
    end
  end

  # args 带 identity_uid 时按该身份精确投递（同用户同平台多身份不再互相覆盖）；
  # 否则回退到 user+platform 单身份解析。
  defp deliver(args, platform) do
    case args["identity_uid"] do
      uid when is_binary(uid) ->
        NotificationService.send_to_identity(
          args["user_id"],
          platform,
          uid,
          args["template_key"],
          args["data"] || %{}
        )

      _ ->
        NotificationService.send_to_user(
          args["user_id"],
          platform,
          args["template_key"],
          args["data"] || %{}
        )
    end
  end

  # --- 通知类型契约公开面（registry 唯一真源） --------------------------------

  @doc "按 template_key 查通知类型条目（无匹配 → nil）。approval_reminder 同键两行返回首行（enrollment_id 面）。"
  @spec type(String.t()) :: map() | nil
  def type(template_key) when is_binary(template_key) do
    Enum.find(@notification_types, &(&1.template_key == template_key))
  end

  def type(_), do: nil

  @doc "registry 全部条目（测试/契约读用；键集双射与 stale 契约的表驱动测试锚定）。"
  @spec types() :: [map()]
  def types, do: @notification_types

  # 同 template_key 多行（approval_reminder 两面）unique 必一致——type/1 取首行
  # 供 Fanout 查表，若同键配不同 unique 会静默取错窗口（advisor D-adv2 守卫，
  # 模块体编译期即断言，配置错误在编译时立刻暴露而非静默漂移）。
  if Enum.any?(
       @notification_types
       |> Enum.group_by(& &1.template_key)
       |> Map.values(),
       fn rows -> rows |> Enum.map(& &1.unique) |> Enum.uniq() |> length() > 1 end
     ) do
    raise "notification_types registry: 同 template_key 行 unique 不一致（type/1 首行语义会静默取错窗口）"
  end

  # --- stale 重查（表驱动单解释器，D2） ---------------------------------------

  # 提醒发送时重查（扫描到执行之间，过期/审批可能已改变状态）：@notification_types
  # 表驱动——定位 template_key 的 stale 规格（approval_reminder 同键两行由 data
  # 携带的 id_key 分派），nil = 不重查直接投递。deadline 类放行谓词统一走
  # ApprovalDeadline.not_expired?/2（nil 永不过期=投递；==now 不放行=跳过；与
  # overdue?/2 不对称对偶，不可代用）；running 类 status==:running 即投递。
  # 非 required_status / 读失败 → stale=true（跳过）；未知类型 → false（不重查，
  # 现兜底保持）。
  defp stale_reminder?(%{"template_key" => template_key, "data" => data})
       when is_map(data) do
    case stale_entry(template_key, data) do
      nil ->
        false

      %{id_key: id_key, stale: {resource, required_status, kind}} ->
        case Map.get(data, id_key) do
          id when is_binary(id) -> stale_check(resource, id, required_status, kind)
          # id 缺失/非 binary → 原子句不匹配落 catch-all 返回 false（投递）
          _ -> false
        end
    end
  end

  defp stale_reminder?(_args), do: false

  # stale 规格定位：template_key 匹配且带 stale 的条目，按 data 实际携带的 id_key
  # 分派（原三子句同款）；无 stale 条目/未知类型/键缺失 → nil。
  defp stale_entry(template_key, data) do
    @notification_types
    |> Enum.filter(&(&1.template_key == template_key and not is_nil(&1.stale)))
    |> Enum.find(&Map.has_key?(data, &1.id_key))
  end

  # 命中 required_status 后的重查判定：deadline 类走放行谓词（未过 → 投递）；
  # running 类 status 命中即投递（无 deadline 概念）。
  defp stale_check(resource, id, required_status, :not_expired) do
    case Ash.get(resource, id, authorize?: false) do
      {:ok, %{status: ^required_status} = record} ->
        not ApprovalDeadline.not_expired?(record, DateTime.utc_now())

      _ ->
        true
    end
  end

  defp stale_check(resource, id, required_status, :running) do
    case Ash.get(resource, id, authorize?: false) do
      {:ok, %{status: ^required_status}} -> false
      _ -> true
    end
  end
end
