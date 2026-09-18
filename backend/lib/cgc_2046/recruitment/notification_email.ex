defmodule Cgc2046.Recruitment.NotificationEmail do
  @moduledoc """
  段位通知邮件（R14 阶段通知表的邮件保底通道；KTD6）。

  复刻 SpeakerInvitationEmail 的尽力而为模式：**字段组装在调用方**
  （`Cgc2046.Recruitment.Subscriber`，DB 读在订阅方进程完成）→ `Task.start`
  异步直发，无队列重试、无送达回执；失败只记日志 + 遥测，不回写业务状态——
  段位流转与通知解耦（申请行是状态权威），补救路径是小程序订阅消息/运营补触达。

  六段模板与 R14 阶段通知表逐行对应（stage 原子 = 信号后缀）：

  | stage | 模板要点 |
  |---|---|
  | `:submitted` | 提交确认 |
  | `:interview` | 面试安排（群面时间 + 入群方式）|
  | `:training` | 训练营预约（排期 + 课程入口）|
  | `:assigned` | 分配结果（场次/课程任务）|
  | `:rejected` | 拒绝通知（含原因）|
  | `:canceled` | 取消通知（备注选填）|

  时间类文案统一按北京时间（UTC+8 固定折算，先例 speaker_invitation_email.ex）。
  """

  require Logger
  import Swoosh.Email

  @telemetry_event [:cgc2046, :recruitment, :notification_email]
  @default_from "no-reply@example.com"
  @default_from_name "CGC 2046"

  @doc "异步发出段位通知邮件（尽力而为）；任何失败只落日志/遥测。"
  @spec send(atom(), map()) :: :ok
  def send(stage, fields) do
    _ = Task.start(fn -> deliver(stage, fields) end)
    :ok
  rescue
    error ->
      Logger.error(
        "recruitment notification email assemble failed stage=#{stage}: " <>
          Exception.format(:error, error, __STACKTRACE__)
      )

      report_failure(stage, Map.get(fields, :to), :assemble_failed)
  catch
    kind, reason -> report_failure(stage, Map.get(fields, :to), {kind, reason})
  end

  @doc "投递段位通知邮件（纯函数：无 DB 访问；公开供测试直调）。"
  @spec deliver(atom(), map()) :: :ok
  def deliver(stage, fields) do
    config = Application.get_env(:cgc_2046, Cgc2046.Mailer, [])
    from = Keyword.get(config, :from, @default_from)
    from_name = Keyword.get(config, :from_name, @default_from_name)

    message =
      new()
      |> from({from_name, from})
      |> to(fields.to)
      |> subject(subject_line(stage, fields))
      |> html_body(body(stage, fields))

    case Cgc2046.Mailer.deliver(message) do
      {:ok, _response} -> :ok
      {:error, reason} -> report_failure(stage, fields.to, reason)
      other -> report_failure(stage, fields.to, {:unexpected_result, other})
    end
  rescue
    error -> report_failure(stage, Map.get(fields, :to), error)
  catch
    kind, reason -> report_failure(stage, Map.get(fields, :to), {kind, reason})
  end

  # --- 文案（R14 阶段通知表逐行） ---------------------------------------------

  defp subject_line(stage, fields) do
    "「#{safe_subject(fields[:cohort_name])}」" <> subject_tail(stage)
  end

  defp subject_tail(:submitted), do: "志愿者申请已提交"
  defp subject_tail(:interview), do: "初审通过：面试安排"
  defp subject_tail(:training), do: "群面通过：训练营预约"
  defp subject_tail(:assigned), do: "项目分配结果"
  defp subject_tail(:rejected), do: "志愿者申请结果通知"
  defp subject_tail(:canceled), do: "志愿者申请已取消"

  defp body(stage, fields) do
    ([
       "<p>#{esc(greeting_name(fields))}你好，</p>",
       "<p>#{headline(stage)}</p>",
       detail_line("申请批次", fields[:cohort_name]),
       detail_line("申请职位", fields[:position_label])
     ] ++ stage_details(stage, fields) ++ footer())
    |> Enum.join("")
  end

  defp headline(:submitted), do: "你的志愿者申请已提交，初审结果会通过邮件通知你。"
  defp headline(:interview), do: "初审通过！接下来是线上群面，安排如下："

  defp headline(:training),
    do: "群面通过！训练营预约信息如下，完成训练营后进入项目分配。"

  defp headline(:assigned), do: "训练营已完成，你的项目分配结果如下："
  defp headline(:rejected), do: "很遗憾，本次申请未通过。"
  defp headline(:canceled), do: "你的这份申请已取消。"

  # 面试安排（群面时间 + 入群方式）：群面约时为线下运营动作（系统只记段位与
  # 结果），故缺排期时文案诚实说明「待运营通知」而不编造时间。
  defp stage_details(:interview, fields) do
    [
      detail_line("群面时间", beijing_time(fields[:group_time]) || "待运营通知"),
      detail_line("入群方式", "运营会通过你预留的联系方式联系你并邀请入群")
    ]
  end

  # 训练营预约（排期 + 课程入口）：训练营依托站内 course 系统，入选者凭运营
  # 发放的邀请码自助报名（R12），系统不做自动开课。
  defp stage_details(:training, fields) do
    [
      detail_line("训练营排期", training_period(fields) || "待运营通知"),
      detail_line("课程入口", "登录站内课程页，凭运营发放的邀请码自助报名")
    ]
  end

  # 分配结果（分配到的场次 + 课程任务）：Tutor 可无场次（只记课程任务，R15）
  defp stage_details(:assigned, fields) do
    [
      detail_line("分配场次", fields[:event_title] || "待运营通知"),
      detail_line("课程任务", blank_to_nil(fields[:assignment_note]))
    ]
  end

  defp stage_details(:rejected, fields) do
    [detail_line("原因", fields[:rejection_reason])]
  end

  defp stage_details(:canceled, fields) do
    [detail_line("取消备注", blank_to_nil(fields[:cancel_note]))]
  end

  defp stage_details(_stage, _fields), do: []

  defp footer do
    [
      "<p>本邮件是段位通知的保底通道。小程序订阅消息需你在小程序内授权订阅，" <>
        "未授权时请以邮件为准。</p>",
      "<p>CGC 2046</p>"
    ]
  end

  defp greeting_name(%{applicant_name: name}) when is_binary(name) do
    case String.trim(name) do
      "" -> ""
      trimmed -> "#{esc(trimmed)}，"
    end
  end

  defp greeting_name(_fields), do: ""

  defp detail_line(_label, nil), do: ""
  defp detail_line(label, value), do: "<p>#{label}：#{esc(value)}</p>"

  defp training_period(fields) do
    case {beijing_time(fields[:training_starts_at]), beijing_time(fields[:training_ends_at])} do
      {nil, _} -> nil
      {starts, nil} -> starts
      {starts, ends} -> "#{starts} ~ #{ends}"
    end
  end

  # Asia/Shanghai 固定 UTC+8 无夏令时；项目无 tzdata 依赖（Calendar 默认
  # UTCOnly），算术偏移行为在 dev/test/prod 一致（先例 speaker_invitation_email.ex）。
  defp beijing_time(%DateTime{} = dt) do
    dt
    |> DateTime.add(8 * 3600, :second)
    |> Calendar.strftime("%Y-%m-%d %H:%M")
  end

  defp beijing_time(_dt), do: nil

  # 主题是纯文本头：不做 HTML 转义，只剥离换行防头注入
  defp safe_subject(value) do
    value |> to_string() |> String.replace(["\r", "\n"], " ")
  end

  defp blank_to_nil(nil), do: nil

  defp blank_to_nil(value) do
    case String.trim(to_string(value)) do
      "" -> nil
      trimmed -> trimmed
    end
  end

  defp esc(value), do: Plug.HTML.html_escape(to_string(value))

  # --- 失败上报（日志 + 遥测，不抛出；与 SpeakerInvitationEmail 同款） --------

  defp report_failure(stage, email, reason) do
    metadata = %{stage: stage, reason: reason_category(reason), email: mask_email(email)}

    Logger.warning(
      "recruitment notification email failed stage=#{stage} email=#{metadata.email} " <>
        "reason=#{metadata.reason}"
    )

    :telemetry.execute(@telemetry_event, %{count: 1}, metadata)
    :ok
  end

  defp reason_category(reason) when is_atom(reason), do: reason

  defp reason_category({:send_cloud, status, _body}) when is_integer(status),
    do: :send_cloud_error

  defp reason_category({kind, _reason}) when kind in [:error, :exit, :throw], do: :delivery_failed
  defp reason_category(_reason), do: :delivery_failed

  defp mask_email(email) when is_binary(email) do
    case String.split(email, "@", parts: 2) do
      [local, domain] when local != "" and domain != "" -> String.first(local) <> "***@" <> domain
      _ -> "***"
    end
  end

  defp mask_email(_), do: "***"
end
