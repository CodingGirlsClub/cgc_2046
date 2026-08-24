defmodule Cgc2046.Events.SpeakerInvitationEmail do
  @moduledoc """
  Speaker 邀请邮件（创建/重发即发，尽力而为；KD1 / R1–R5）。

  复刻 SendPasswordResetEmail 模式：请求路径内 `Task.start` 异步直发，无队列
  重试、无送达回执（KD1）。明文 token 不落任何持久层——组装（Event /
  Workspace / 邀请人三次 DB 读）在调用方进程完成（此时事务已提交；Task 内
  不做 DB 访问，避免脱离 sandbox ownership），Task 只做投递 IO；失败记日志 +
  遥测，不回写邀请状态（R4），补救路径是组织者重发（KD2）。
  """

  require Logger
  import Swoosh.Email

  alias Cgc2046.Accounts.{User, Workspace}
  alias Cgc2046.Events.{Event, SpeakerInvitation}

  @telemetry_event [:cgc2046, :speaker_invitation, :send_email]
  @default_web_base_url "http://localhost:3000"
  @default_from "no-reply@example.com"
  @default_from_name "CGC 2046"

  @doc """
  组装（调用方进程，DB 读）并异步发出邀请邮件；任何失败只落日志/遥测。
  仅对填写了 speaker_email 的邀请调用（R1，调用方守卫）。
  """
  @spec send(SpeakerInvitation.t(), String.t()) :: :ok
  def send(%SpeakerInvitation{} = invitation, plain_token) do
    fields = assemble_fields(invitation)
    _ = Task.start(fn -> deliver(fields, plain_token) end)
    :ok
  rescue
    error ->
      Logger.error(
        "speaker invitation email assemble failed invitation=#{invitation.id}: " <>
          Exception.format(:error, error, __STACKTRACE__)
      )

      report_failure(invitation.speaker_email, :assemble_failed)
  catch
    kind, reason -> report_failure(invitation.speaker_email, {kind, reason})
  end

  @doc "投递邀请邮件（纯函数：无 DB 访问；公开供测试直调）。"
  @spec deliver(map(), String.t()) :: :ok
  def deliver(fields, plain_token) do
    config = Application.get_env(:cgc_2046, Cgc2046.Mailer, [])
    from = Keyword.get(config, :from, @default_from)
    from_name = Keyword.get(config, :from_name, @default_from_name)
    web_base_url = Application.get_env(:cgc_2046, :web_base_url, @default_web_base_url)
    invite_url = build_invite_url(web_base_url, fields.event_slug, plain_token)

    message =
      new()
      |> from({from_name, from})
      |> to(fields.to)
      |> subject(subject_line(fields.event_title))
      |> html_body(body(fields, invite_url))

    case Cgc2046.Mailer.deliver(message) do
      {:ok, _response} -> :ok
      {:error, reason} -> report_failure(fields.to, reason)
      other -> report_failure(fields.to, {:unexpected_result, other})
    end
  rescue
    error -> report_failure(Map.get(fields, :to), error)
  catch
    kind, reason -> report_failure(Map.get(fields, :to), {kind, reason})
  end

  # --- 组装（调用方进程） ----------------------------------------------------

  defp assemble_fields(%SpeakerInvitation{} = invitation) do
    event = fetch_event(invitation.event_id)
    workspace = Ash.get!(Workspace, event.workspace_id, authorize?: false)
    inviter = fetch_user(invitation.invited_by)

    %{
      to: invitation.speaker_email,
      speaker_name: invitation.speaker_name,
      inviter_name: inviter_display_name(inviter),
      inviter_email: user_email(inviter),
      event_title: event.title,
      event_slug: event.slug,
      workspace_name: workspace.name,
      topic: invitation.topic,
      scheduled_at: invitation.scheduled_at,
      note: invitation.note
    }
  end

  defp fetch_event(event_id) do
    case Ash.get(Event, event_id, authorize?: false) do
      {:ok, %Event{} = event} -> event
      _ -> raise "event #{event_id} not found for invitation email"
    end
  end

  defp fetch_user(user_id) do
    case Ash.get(User, user_id, authorize?: false) do
      {:ok, %User{} = user} -> user
      _ -> raise "user #{user_id} not found for invitation email"
    end
  end

  # 邀请人名字（R2/R5）：display_name 缺失时退回邮箱本地段，再退「组织者」；
  # 邮箱缺失（如手机号注册）只显名字，不阻塞发送（R5）。
  defp inviter_display_name(%User{display_name: display_name, email: email}) do
    name = display_name && String.trim(display_name)

    cond do
      is_binary(name) and name != "" -> name
      local = email_local_part(email) -> local
      true -> "组织者"
    end
  end

  defp email_local_part(email) when not is_nil(email) do
    case email |> to_string() |> String.split("@", parts: 2) do
      [local, _] when local != "" -> local
      _ -> nil
    end
  end

  defp email_local_part(_), do: nil

  defp user_email(%User{email: email}) when not is_nil(email), do: to_string(email)
  defp user_email(_), do: nil

  defp subject_line(event_title) do
    "邀请你在「" <> safe_subject(event_title) <> "」做分享"
  end

  # 主题是纯文本头：不做 HTML 转义，只剥离换行防头注入
  defp safe_subject(title) do
    title |> to_string() |> String.replace(["\r", "\n"], " ")
  end

  defp build_invite_url(web_base_url, event_slug, token) do
    base = web_base_url |> to_string() |> String.trim_trailing("/") |> esc()

    if is_binary(event_slug) and event_slug != "" do
      "#{base}/events/#{esc(event_slug)}/speaker-invite/#{esc(token)}"
    else
      # Event.create 兜底生成 slug，此分支仅防御（与面板 eventSlug 缺席时
      # 复制裸 token 的降级一致）
      esc(token)
    end
  end

  defp body(fields, invite_url) do
    [
      "<p>#{esc(fields.speaker_name)} 你好，</p>",
      "<p>#{esc(fields.inviter_name)}（#{esc(fields.workspace_name)}）邀请你在活动「#{esc(fields.event_title)}」做一次分享。</p>",
      inviter_email_line(fields.inviter_email),
      detail_line("分享主题", fields.topic),
      scheduled_at_line(fields.scheduled_at),
      detail_line("备注", fields.note),
      "<p>点击以下链接查看邀请详情，可接受或婉拒：</p>",
      "<p><a href=\"#{invite_url}\">查看邀请</a></p>",
      "<p>如果链接无法点击，请将下面的地址复制到浏览器打开：</p>",
      "<p>#{invite_url}</p>",
      "<p>CGC 2046</p>"
    ]
    |> Enum.join("")
  end

  defp inviter_email_line(nil), do: ""

  defp inviter_email_line(email), do: "<p>邀请人邮箱：#{esc(email)}</p>"

  defp detail_line(_label, nil), do: ""
  defp detail_line(label, value), do: "<p>#{label}：#{esc(value)}</p>"

  # Asia/Shanghai 固定 UTC+8 无夏令时；项目无 tzdata 依赖（Calendar 默认
  # UTCOnly，shift_zone 不可用），算术偏移行为在 dev/test/prod 一致。
  defp scheduled_at_line(%DateTime{} = dt) do
    beijing = DateTime.add(dt, 8 * 3600, :second)
    "<p>分享时间：#{Calendar.strftime(beijing, "%Y-%m-%d %H:%M")}（北京时间）</p>"
  end

  defp scheduled_at_line(_), do: ""

  defp esc(value), do: Plug.HTML.html_escape(to_string(value))

  # --- 失败上报（日志 + 遥测，不抛出；与 SendPasswordResetEmail 同款） --------

  defp report_failure(email, reason) do
    metadata = %{reason: reason_category(reason), email: mask_email(email)}

    Logger.warning(
      "speaker invitation email delivery failed email=#{metadata.email} reason=#{metadata.reason}"
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
      [local, domain] when local != "" and domain != "" ->
        String.first(local) <> "***@" <> domain

      _ ->
        "***"
    end
  end

  defp mask_email(_), do: "***"
end
