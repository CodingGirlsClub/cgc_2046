defmodule Cgc2046.Notifications.InboxSnapshot do
  @moduledoc "既有 registry 的用户文本投影。新类型不得自动透传渠道载荷。"
  @enrollments "/pages/my-enrollments/index"
  @workspace "/pages/workspace/index"

  def build(type, data, meta) do
    case content(type, data) do
      nil ->
        nil

      {title, body, target} ->
        %{
          payload: %{"title" => String.slice(title, 0, 80), "body" => String.slice(body, 0, 280)},
          deep_link: link(target, data, meta)
        }
    end
  end

  defp content("approval_result", d) do
    status =
      case d["status"] do
        "confirmed" -> "报名已通过。"
        "rejected" -> "报名未通过。"
        _ -> "报名审批已处理。"
      end

    {"报名审批结果", named(d["title"], status), :enrollments}
  end

  defp content("enrollment_submitted", d),
    do: {"待审批报名", named(d["title"], "有新的报名申请，请前往工作台处理。"), :workspace}

  defp content("enrollment_completed", d),
    do: {"报名成功", named(d["title"], "你的报名已确认。"), :enrollments}

  defp content("enrollment_check_in_code", d),
    do: {"核销码已就绪", named(d["title"], "请到我的报名查看核销码。"), :enrollments}

  defp content("approval_reminder", d),
    do: {"审批提醒", named(date(d["approval_deadline"]), "有申请待审批，请前往工作台处理。"), :workspace}

  defp content("event_reminder", d), do: {"开始提醒", schedule(d, "即将开始，请查看报名安排。"), :enrollments}
  defp content("event_schedule_changed", d), do: {"活动安排更新", schedule(d, "活动时间或地点已更新。"), :event}

  defp content("event_qualification_confirmed", d),
    do: {"活动成班确认", named(d["title"], "活动已达到成班要求。"), :event}

  defp content("event_qualification_underfilled", d),
    do: {"活动成班结果", named(d["title"], "活动未达到成班要求，请查看活动信息。"), :event}

  defp content("event_qualification_manager", d) do
    note = if d["outcome"] == "confirmed", do: "活动已达到成班要求。", else: "活动未达到成班要求。"
    {"活动成班结果", named(d["title"], note), :event}
  end

  defp content("event_moderator_assigned", d),
    do: {"主理人指派", named(d["title"], "你已被指派为活动主理人。"), :event}

  defp content("event_moderator_removed", d),
    do: {"主理人身份解除", named(d["title"], "你的活动主理人身份已解除。"), :event}

  defp content("speaker_accepted", d), do: {"分享邀请已接受", named(d["title"], "分享者已接受邀请。"), :workspace}
  defp content("speaker_completed", _), do: {"分享已完成", "分享已完成，材料已归档。", nil}

  defp content("learning_stagnation", d),
    do: {"学习进度提醒", named(d["title"], "记得回来继续学习。"), :enrollments}

  defp content("payment_succeeded", d),
    do: {"支付成功", named(amount(d["amount"]), "支付已成功，请查看报名信息。"), :enrollments}

  defp content("payment_received", d),
    do:
      {"收款到账", join([text(d["title"]), text(d["tier_name"]), amount(d["amount"]), "收款已到账。"]),
       :workspace}

  defp content("payment_expired", d) do
    note = if d["re_enrollable"] in [true, "true"], do: "支付订单已过期，报名截止前可重新报名。", else: "支付订单已过期。"
    {"支付订单过期", named(d["title"], note), :enrollments}
  end

  defp content("refund_succeeded", d),
    do: {"退款成功", named(amount(d["amount"]), "退款已成功。"), :enrollments}

  defp content("refund_failed", d),
    do: {"退款未完成", named(amount(d["amount"]), "退款未完成，请查看报名信息。"), :enrollments}

  defp content("volunteer_application_submitted", d),
    do:
      {"志愿者申请已提交", join([text(d["cohort_name"]), text(d["position_label"]), "申请已提交，等待初审。"]), nil}

  defp content("volunteer_application_interview", d),
    do: {"面试安排", join([text(d["cohort_name"]), date(d["group_time"]), "运营将联系你入群。"]), nil}

  defp content("volunteer_application_training", d),
    do: {"训练营安排", join([text(d["cohort_name"]), date(d["training_starts_at"]), "请查看训练营安排。"]), nil}

  defp content("volunteer_application_assigned", d),
    do: {"项目分配完成", join([text(d["event_title"]), text(d["assignment_note"]), "项目分配已完成。"]), nil}

  defp content("volunteer_application_rejected", d),
    do: {"志愿者申请未通过", join([text(d["cohort_name"]), "本次申请未通过。", text(d["rejection_reason"])]), nil}

  defp content("volunteer_application_canceled", d),
    do: {"志愿者申请已取消", join([text(d["cohort_name"]), "申请已取消。", text(d["cancel_note"])]), nil}

  defp content("flashback_wish_echo", d),
    do: {"主办方收到你的提议", named(text(d["content_preview"], 20), "来看看主办方的回应。"), :wish}

  defp content(_, _), do: nil

  defp link(:enrollments, _, _), do: @enrollments
  defp link(:workspace, _, _), do: @workspace

  defp link(:event, d, m),
    do: uuid_link("/pages/event-detail/index", "id", d["event_id"] || m["event_id"])

  defp link(:wish, d, _), do: uuid_link("/pages/flashback-wishes/index", "wishId", d["wish_id"])
  defp link(nil, _, _), do: nil

  defp uuid_link(path, key, value) do
    case Ecto.UUID.cast(value) do
      {:ok, id} -> path <> "?" <> key <> "=" <> URI.encode_www_form(id)
      _ -> nil
    end
  end

  defp text(value, limit \\ 160)

  defp text(value, limit) when is_binary(value),
    do: value |> String.trim() |> String.slice(0, limit)

  defp text(_, _), do: ""
  defp named(name, note), do: join([text(name), note])
  defp join(parts), do: parts |> Enum.reject(&(&1 == "")) |> Enum.join("：")
  defp amount(value) when is_binary(value) or is_number(value), do: "金额 ¥" <> to_string(value)
  defp amount(_), do: ""

  defp date(%DateTime{} = value),
    do: value |> DateTime.add(8, :hour) |> Calendar.strftime("%Y-%m-%d %H:%M")

  defp date(value) when is_binary(value) do
    case DateTime.from_iso8601(value) do
      {:ok, at, _} -> date(at)
      _ -> ""
    end
  end

  defp date(_), do: ""

  defp schedule(d, note) do
    venue = if is_map(d["venue"]), do: Cgc2046.Events.Venue.text(d["venue"]), else: d["venue"]
    join([text(d["title"]), note, date(d["starts_at"]), text(venue)])
  end
end
