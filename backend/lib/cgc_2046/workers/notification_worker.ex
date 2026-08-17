defmodule Cgc2046.Workers.NotificationWorker do
  @moduledoc "异步发送审批结果或提醒订阅消息。"

  use Oban.Worker,
    queue: :notifications,
    max_attempts: 3,
    unique: [period: 604_800, fields: [:worker, :args], states: :all]

  alias Cgc2046.ApprovalDeadline
  alias Cgc2046.Events.Enrollment
  alias Cgc2046.Events.Sponsorship
  alias Cgc2046.NotificationService
  alias Cgc2046.Workflows.WorkflowRun

  @impl Oban.Worker
  def perform(%Oban.Job{args: args}) do
    platform = String.to_existing_atom(args["platform"])

    if stale_reminder?(args) do
      :ok
    else
      case deliver(args, platform) do
        :ok -> :ok
        {:error, reason} when reason in [:consent_exhausted, :platform_identity_not_found] -> :ok
        {:error, reason} -> {:error, inspect(reason)}
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

  # 提醒发送时重查（扫描到执行之间，过期/审批可能已改变状态）：
  # 仅当报名仍 pending 且 deadline 未过时投递；其余情况静默跳过。deadline 放行谓词
  # 统一走 ApprovalDeadline.not_expired?/2（nil 永不过期=投递；==now 不放行=跳过；
  # 与 overdue?/2 不对称对偶，不可代用）。
  defp stale_reminder?(%{
         "template_key" => "approval_reminder",
         "data" => %{"enrollment_id" => id}
       })
       when is_binary(id) do
    case Ash.get(Enrollment, id, authorize?: false) do
      {:ok, %{status: :pending} = record} ->
        not ApprovalDeadline.not_expired?(record, DateTime.utc_now())

      _ ->
        true
    end
  end

  # 赞助提醒发送时重查：仅当赞助仍 pending 且 deadline 未过时投递。
  defp stale_reminder?(%{
         "template_key" => "approval_reminder",
         "data" => %{"sponsorship_id" => id}
       })
       when is_binary(id) do
    case Ash.get(Sponsorship, id, authorize?: false) do
      {:ok, %{status: :pending} = record} ->
        not ApprovalDeadline.not_expired?(record, DateTime.utc_now())

      _ ->
        true
    end
  end

  # 学习停滞提醒发送时重查（E-7 #122）：仅当 learning run 仍 running 才投递
  # （扫描到执行之间 run 可能已完成/取消）。
  defp stale_reminder?(%{
         "template_key" => "learning_stagnation",
         "data" => %{"run_id" => id}
       })
       when is_binary(id) do
    case Ash.get(WorkflowRun, id, authorize?: false) do
      {:ok, %{status: :running}} -> false
      _ -> true
    end
  end

  defp stale_reminder?(_args), do: false
end
