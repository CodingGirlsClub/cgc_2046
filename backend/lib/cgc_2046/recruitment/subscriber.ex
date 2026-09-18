defmodule Cgc2046.Recruitment.Subscriber do
  @moduledoc """
  志愿者段位通知订阅方（U4；R14/R21；KTD6）。

  订阅 `volunteer_application.*` 六信号（U3 `VolunteerApplication` 段位流转的
  数据面），每个信号 = R14 阶段通知表一行 = 一个订阅场景：

  | 信号 | 通知场景 template_key | 内容 |
  |---|---|---|
  | `volunteer_application.submitted` | `volunteer_application_submitted` | 提交确认 |
  | `volunteer_application.interview` | `volunteer_application_interview` | 面试安排 |
  | `volunteer_application.training` | `volunteer_application_training` | 训练营预约 |
  | `volunteer_application.assigned` | `volunteer_application_assigned` | 分配结果 |
  | `volunteer_application.rejected` | `volunteer_application_rejected` | 拒绝通知 |
  | `volunteer_application.canceled` | `volunteer_application_canceled` | 取消通知 |

  双通道（KTD6）：

  - **小程序订阅消息**：收件人 = 申请人本人的平台身份（逐身份入队，多平台不
    折叠）→ `Notifications.Fanout.deliver` → `NotificationWorker` →
    `Service.render(:wechat, …)`；用户未授权时发送侧 `consent_exhausted` 终态
    discard（**不报错**，`NotificationWorker` 已内化），前端按 R21 的订阅触点
    引导授权；
  - **邮件保底**：`Recruitment.NotificationEmail` 异步直发，收件地址 = 档案
    联系邮箱（R9，**不是账号 email**——手机号建号账号亦可达）。档案缺失或
    联系邮箱为空时只记日志不发邮件，小程序通道不受影响。

  幂等与生命周期：`use Cgc2046.Workflows.SignalSubscriber`（`:claim_first` +
  显式 `consumer_key`）；`consumer_key` 必须显式声明——leaf 派生会撞
  `Notifications.Subscriber` 的 `"subscriber"` 键。

  通知内容以**申请行回查**为准（段位流转信号只在事务内入队，申请行是状态
  权威，KTD1）：payload 只用来定位申请与工作台；拒绝原因、分配场次/课程任务、
  批次排期均从 DB 现读。任何异常只记日志归一 `:ok`——通知失败绝不回写业务。
  """

  use Cgc2046.Workflows.SignalSubscriber,
    patterns: [
      "volunteer_application.submitted",
      "volunteer_application.interview",
      "volunteer_application.training",
      "volunteer_application.assigned",
      "volunteer_application.rejected",
      "volunteer_application.canceled"
    ],
    idempotency: :claim_first,
    consumer_key: "recruitment_subscriber"

  require Ash.Query
  require Logger

  alias Cgc2046.Events.Event
  alias Cgc2046.Notifications.Fanout

  alias Cgc2046.Recruitment.{
    NotificationEmail,
    RecruitmentCohort,
    ResumeProfile,
    VolunteerApplication
  }

  # 信号 → {邮件 stage 原子, 小程序 template_key}（同一行 R14 映射表）
  @stages %{
    "volunteer_application.submitted" => {:submitted, "volunteer_application_submitted"},
    "volunteer_application.interview" => {:interview, "volunteer_application_interview"},
    "volunteer_application.training" => {:training, "volunteer_application_training"},
    "volunteer_application.assigned" => {:assigned, "volunteer_application_assigned"},
    "volunteer_application.rejected" => {:rejected, "volunteer_application_rejected"},
    "volunteer_application.canceled" => {:canceled, "volunteer_application_canceled"}
  }

  # 职位中文文案（KTD4 职位是代码枚举；通知面唯一消费者，不建表）
  @position_labels %{event_moderator: "场次主理人", tutor: "教程研究员", coach: "活动教练"}

  @impl Cgc2046.Workflows.SignalSubscriber
  def handle(type, data) when is_map(data) do
    case @stages do
      %{^type => {stage, template_key}} -> notify(stage, template_key, data)
      _other -> :ok
    end
  end

  def handle(_type, _data), do: :ok

  defp notify(stage, template_key, data) do
    case fetch_application(data) do
      {:ok, application} ->
        context = context(application)
        enqueue_miniprogram(template_key, application, context, data)
        send_email(stage, application, context)
        :ok

      :error ->
        Logger.warning(
          "recruitment notification skipped (#{template_key}): application not found " <>
            "id=#{inspect(data["volunteer_application_id"])}"
        )

        :ok
    end
  rescue
    error ->
      Logger.warning(
        "recruitment notification failed (#{template_key}): #{Exception.message(error)}"
      )

      :ok
  end

  # --- 数据面（申请行回查 + 批次/场次/档案） ----------------------------------

  defp fetch_application(%{"volunteer_application_id" => id, "workspace_id" => workspace_id})
       when is_binary(id) and is_binary(workspace_id) do
    case Ash.get(VolunteerApplication, id, tenant: workspace_id, authorize?: false) do
      {:ok, %VolunteerApplication{} = application} -> {:ok, application}
      _other -> :error
    end
  end

  defp fetch_application(_data), do: :error

  defp context(application) do
    %{
      cohort: fetch_cohort(application),
      event: fetch_event(application),
      profile: fetch_profile(application)
    }
  end

  defp fetch_cohort(%{cohort_id: nil}), do: nil

  defp fetch_cohort(application) do
    case Ash.get(RecruitmentCohort, application.cohort_id,
           tenant: application.workspace_id,
           authorize?: false
         ) do
      {:ok, %RecruitmentCohort{} = cohort} -> cohort
      _other -> nil
    end
  end

  defp fetch_event(%{assigned_event_id: nil}), do: nil

  defp fetch_event(application) do
    case Ash.get(Event, application.assigned_event_id, authorize?: false) do
      {:ok, %Event{} = event} -> event
      _other -> nil
    end
  end

  defp fetch_profile(application) do
    ResumeProfile
    |> Ash.Query.filter(user_id == ^application.user_id)
    |> Ash.read_one(tenant: application.workspace_id, authorize?: false)
    |> case do
      {:ok, %ResumeProfile{} = profile} -> profile
      _other -> nil
    end
  end

  # --- 小程序订阅消息（既有全链，授权不足由发送侧内化） ------------------------

  defp enqueue_miniprogram(template_key, application, context, data) do
    Fanout.deliver(
      {application.user_id, Fanout.identities(application.user_id)},
      template_key,
      wechat_data(template_key, application, context),
      %{
        "volunteer_application_id" => application.id,
        "idempotency_key" => data["idempotency_key"]
      }
    )
  end

  # data 键集契约 = NotificationWorker @notification_types 的 data_keys（双写点）
  defp wechat_data("volunteer_application_submitted", application, context) do
    %{
      "cohort_name" => cohort_name(context),
      "position_label" => position_label(application)
    }
  end

  defp wechat_data("volunteer_application_interview", _application, context) do
    %{"cohort_name" => cohort_name(context), "group_time" => iso8601(cohort_starts_at(context))}
  end

  defp wechat_data("volunteer_application_training", _application, context) do
    %{
      "cohort_name" => cohort_name(context),
      "training_starts_at" => iso8601(cohort_starts_at(context))
    }
  end

  defp wechat_data("volunteer_application_assigned", application, context) do
    %{
      "event_title" => context.event && context.event.title,
      "assignment_note" => blank_to_nil(application.assignment_note)
    }
  end

  defp wechat_data("volunteer_application_rejected", application, context) do
    %{"cohort_name" => cohort_name(context), "rejection_reason" => application.rejection_reason}
  end

  defp wechat_data("volunteer_application_canceled", application, context) do
    %{"cohort_name" => cohort_name(context), "cancel_note" => application.rejection_reason}
  end

  # --- 邮件保底（R9 档案联系邮箱；尽力而为） -----------------------------------

  defp send_email(stage, application, context) do
    case contact_email(context.profile) do
      nil ->
        Logger.warning(
          "recruitment notification email skipped (#{stage}): no contact email " <>
            "application=#{application.id}"
        )

        :ok

      to ->
        NotificationEmail.send(stage, email_fields(application, context, to))
    end
  end

  defp email_fields(application, context, to) do
    %{
      to: to,
      applicant_name: context.profile && context.profile.full_name,
      position_label: position_label(application),
      cohort_name: cohort_name(context),
      group_time: cohort_starts_at(context),
      training_starts_at: cohort_starts_at(context),
      training_ends_at: context.cohort && context.cohort.ends_at,
      event_title: context.event && context.event.title,
      assignment_note: blank_to_nil(application.assignment_note),
      rejection_reason: blank_to_nil(application.rejection_reason),
      cancel_note: blank_to_nil(application.rejection_reason)
    }
  end

  # 联系邮箱是邮件唯一地址来源；缺失/空白与无档案同判（R9：档案必填联系邮箱，
  # 缺失是数据异常，记日志暴露而不静默）
  defp contact_email(%ResumeProfile{contact_email: email}) when is_binary(email),
    do: blank_to_nil(email)

  defp contact_email(_profile), do: nil

  defp position_label(%{position: position}), do: Map.get(@position_labels, position)

  defp cohort_name(%{cohort: %{name: name}}) when is_binary(name), do: name
  defp cohort_name(_context), do: nil

  defp cohort_starts_at(%{cohort: %{starts_at: starts_at}}), do: starts_at
  defp cohort_starts_at(_context), do: nil

  defp iso8601(%DateTime{} = dt), do: DateTime.to_iso8601(dt)
  defp iso8601(_dt), do: nil

  defp blank_to_nil(nil), do: nil

  defp blank_to_nil(value) do
    case value |> to_string() |> String.trim() do
      "" -> nil
      trimmed -> trimmed
    end
  end
end
