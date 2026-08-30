defmodule Cgc2046.Notifications.Service do
  @moduledoc "按平台身份投递订阅消息，并以数据库原子操作消费一次性授权。"

  require Ash.Query

  alias Cgc2046.Accounts.UserIdentity
  alias Cgc2046.Integrations.Wechat.Client
  alias Cgc2046.Notifications.Consent

  def send_to_user(user_id, platform, template_key, data) when is_map(data) do
    with {:ok, uid} <- identity_uid(user_id, platform) do
      send_to_identity(user_id, platform, uid, template_key, data)
    end
  end

  @doc "投递到指定平台身份（uid 已知，如同用户多身份场景）；授权按 user+platform 原子消费。"
  def send_to_identity(user_id, platform, uid, template_key, data) when is_map(data) do
    with {:ok, template_id} <- template_id(platform, template_key),
         {:ok, _remaining} <- Consent.take(user_id, platform, template_key) do
      case Client.send_notification(
             platform,
             uid,
             template_id,
             render(platform, template_key, data)
           ) do
        :ok ->
          :ok

        {:error, _} = error ->
          _ = Consent.refund(user_id, platform, template_key)
          error
      end
    end
  end

  # --- 平台模板字段渲染（2026-08-26 微信平台模板申请落定） ---------------------
  #
  # 入参 data 是平台无关的逻辑键（生产方契约见 NotificationWorker @notification_types
  # 的 data_keys）；此处按 platform × template_key 渲染为微信订阅消息的
  # `%{字段编号 => 值}` 形状（SDK send_mini 再统一包 %{"value" => v}）。字段编号
  # 逐一与公众平台「我的模板 → 详情」核对：
  #
  # - approval_result「参与活动提醒」：参与结果=thing2 / 活动名称=thing1 /
  #   参与编号=number3（capacity_seq 名额序号；thing≤20 汉字、number 纯数字）
  # - approval_reminder「待处理申请提醒」：申请单号=character_string1（UUID 去
  #   连字符恰 32 字符）/ 截止日期=time11
  # - event_reminder「活动开始提醒」：活动名称=thing2 / 开始时间=time3 /
  #   活动地点=thing4（发送方未落地，#203；字段映射先注册）
  # - payment_received「收款成功通知」：活动名称=thing6 / 商品名称=thing8
  #   （档位快照名，空档跳过）/ 订单金额=amount2 / 订单编号=character_string1
  #   （order_id UUID 去连字符）
  # - payment_expired「订单状态变化通知」：订单号=character_string11 / 商品名
  #   称=thing14（活动名）/ 订单金额=amount8 / 备注=thing10（超时说明，
  #   re_enrollable=true 时提示报名截止前可重新报名）
  #
  # 缺值字段跳过（微信允许少传）；无映射的平台/模板键原样透传（tt/xhs 模板
  # 未申请，template_not_configured 在更早已拦截，透传仅为不炸兜底路径）。
  defp render(:wechat, "approval_result", %{} = data) do
    %{
      "thing2" => approval_result_text(data["status"]),
      "thing1" => thing(data["title"]),
      "number3" => number(data["capacity_seq"])
    }
    |> drop_nils()
  end

  defp render(:wechat, "approval_reminder", %{} = data) do
    %{
      "character_string1" => code(data["enrollment_id"] || data["sponsorship_id"]),
      "time11" => time(data["approval_deadline"])
    }
    |> drop_nils()
  end

  defp render(:wechat, "event_reminder", %{} = data) do
    %{
      "thing2" => thing(data["title"]),
      "time3" => time(data["starts_at"]),
      "thing4" => thing(data["venue"])
    }
    |> drop_nils()
  end

  defp render(:wechat, "payment_received", %{} = data) do
    %{
      "thing6" => thing(data["title"]),
      "thing8" => thing(blank_to_nil(data["tier_name"])),
      "amount2" => data["amount"],
      "character_string1" => code(data["order_id"])
    }
    |> drop_nils()
  end

  defp render(:wechat, "payment_expired", %{} = data) do
    %{
      "character_string11" => code(data["order_id"]),
      "thing14" => thing(data["title"]),
      "amount8" => data["amount"],
      "thing10" => expiry_note(data["re_enrollable"])
    }
    |> drop_nils()
  end

  defp render(_platform, _template_key, data), do: data

  defp drop_nils(fields), do: Map.reject(fields, fn {_k, v} -> is_nil(v) end)

  defp blank_to_nil(""), do: nil
  defp blank_to_nil(text) when is_binary(text), do: text

  # thing ≤20 字：「订单超时作废，报名截止前可重新报名」恰 17 字
  defp expiry_note("true"), do: "订单超时作废，报名截止前可重新报名"
  defp expiry_note(_), do: "订单超时作废"

  defp approval_result_text("approved"), do: "已通过"
  defp approval_result_text("rejected"), do: "未通过"
  defp approval_result_text(_), do: "已处理"

  # thing.DATA ≤20 字（含汉字）
  defp thing(nil), do: nil
  defp thing(text) when is_binary(text), do: String.slice(text, 0, 20)

  # number.DATA 仅纯数字
  defp number(nil), do: nil
  defp number(seq) when is_integer(seq), do: Integer.to_string(seq)

  # character_string.DATA ≤32 字符；UUID 去连字符后恰 32
  defp code(nil), do: nil
  defp code(id) when is_binary(id), do: id |> String.replace("-", "") |> String.slice(0, 32)

  # time.DATA：统一 "YYYY-MM-DD HH:MM"；字符串入参（Oban args JSON 化后）先解析
  defp time(%DateTime{} = dt), do: Calendar.strftime(dt, "%Y-%m-%d %H:%M")
  defp time(nil), do: nil

  defp time(iso) when is_binary(iso) do
    case DateTime.from_iso8601(iso) do
      {:ok, dt, _offset} -> time(dt)
      {:error, _} -> String.slice(iso, 0, 32)
    end
  end

  defp template_id(platform, template_key) do
    case get_in(Application.get_env(:cgc_2046, :miniprogram_templates, %{}), [
           platform,
           template_key
         ]) do
      template_id when is_binary(template_id) and template_id != "" -> {:ok, template_id}
      _ -> {:error, :template_not_configured}
    end
  end

  defp identity_uid(user_id, platform) do
    UserIdentity
    |> Ash.Query.filter(user_id == ^user_id and provider == ^platform)
    |> Ash.read_one(authorize?: false)
    |> case do
      {:ok, %UserIdentity{uid: uid}} -> {:ok, uid}
      {:ok, nil} -> {:error, :platform_identity_not_found}
      {:error, reason} -> {:error, reason}
    end
  end
end
