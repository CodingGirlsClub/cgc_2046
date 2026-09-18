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
             render(platform, template_key, data),
             template_key
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
  #   活动地点=thing4（发送方已落地：Offering.EventReminderWorker，#203
  #   方案 B；本映射为其微信字段渲染层）
  # - payment_received「收款成功通知」：活动名称=thing6 / 商品名称=thing8
  #   （档位快照名，空档跳过）/ 订单金额=amount2 / 订单编号=character_string1
  #   （order_id UUID 去连字符）
  # - payment_expired「订单状态变化通知」：订单号=character_string11 / 商品名
  #   称=thing14（活动名）/ 订单金额=amount8 / 备注=thing10（超时说明，
  #   re_enrollable=true 时提示报名截止前可重新报名）
  # - enrollment_submitted「预约待审核通知」（#406）：活动名称=thing1 /
  #   温馨提示=thing5（固定文案；enrollment_id 不下发——管理者点通知进工作台
  #   处理列表）
  # - enrollment_completed「活动报名成功通知」（#406）：活动名称=thing1 /
  #   门票号=character_string10（enrollment_id UUID 去连字符恰 32 字符）
  # - enrollment_check_in_code「核销成功通知」（#546）：活动名称=thing8 /
  #   核销码=character_string15（报名 create 时生成的 6 位数字）/ 温馨提示=
  #   thing9（固定文案）。**date5 核销时间本批有意跳过**——触发点是报名落
  #   confirmed（尚未核销，无核销时间），写活动开始日期属语义写反；跳字段先例
  #   见 refund_succeeded 的 time5（生产已成功送达）
  # - payment_succeeded「支付成功通知」（#406）：订单号=character_string2 /
  #   支付金额=amount3
  # - refund_succeeded「退款成功通知」（#406）：订单号=character_string2 /
  #   退款金额=amount3 / 退款状态=phrase8（固定「退款成功」；退款时间 time5
  #   逻辑键无数据源，缺省跳过）
  # - refund_failed「退款通知」（#406）：订单编号=character_string2 / 退款金额
  #   =amount1 / 退款原因=thing3（固定文案，渠道错误细节不进用户面）/
  #   退款状态=phrase5（固定「退款失败」）
  # - event_qualification_confirmed（#606，2026-09-16 平台选用即时生效）：
  #   活动名称=thing4 / 已确认人数=number16（confirmed_count，纯数字）/
  #   开班提示=thing7（动态「已达最低成班人数{min}人」）
  # - event_qualification_underfilled（#606）：活动名称=thing1 / 未达阈值说明
  #   =thing5（动态「未达最低成班人数{min}人，活动未成行」；confirmed_count
  #   平台无 number 槽位，不下发）
  # - event_schedule_changed（#606）：活动名称=thing1 / 新开始时间=date2 /
  #   地点=thing5（venue，缺值跳过）。date2 是 **date 类型**、非 time——见
  #   date/1 的格式假设注释；venue 变更本身也是本通知的触发条件
  #   （event.ex schedule_changed?/1），故 thing5 放地点而非重复时间
  # - event_moderator_assigned（#606）：活动名称=thing1 / 说明=thing5（固定
  #   「你已被指派为该活动主理人」）
  # - speaker_accepted（#606）：活动名称=thing14 / 状态=thing6（固定「已接受」）；
  #   speaker_invitation_id 不下发（平台无 character_string 槽位，本就是 job meta）
  # - speaker_completed（#606）：活动名称=thing1（speaker 本人面无 title → 跳过，
  #   固定 thing4 仍在，不会下发空 data）/ 归档提示=thing4（固定
  #   「分享已完成，材料已归档」）；speaker_invitation_id 同上不下发
  # - learning_stagnation（#606）：课程名=thing1 / 提醒=thing4（固定
  #   「长时间未继续学习，记得回来完成学习」）；enrollment_id / run_id 不下发
  #   （平台无 character_string 槽位，本就是 job meta）
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

  defp render(:wechat, "enrollment_submitted", %{} = data) do
    %{
      "thing1" => thing(data["title"]),
      "thing5" => "有新的待审批报名，请前往工作台处理"
    }
    |> drop_nils()
  end

  defp render(:wechat, "enrollment_check_in_code", %{} = data) do
    %{
      "thing8" => thing(data["title"]),
      "character_string15" => check_in_code(data["check_in_code"]),
      "thing9" => "到店出示此码核销"
    }
    |> drop_nils()
  end

  defp render(:wechat, "enrollment_completed", %{} = data) do
    %{
      "thing1" => thing(data["title"]),
      "character_string10" => code(data["enrollment_id"])
    }
    |> drop_nils()
  end

  defp render(:wechat, "payment_succeeded", %{} = data) do
    %{
      "character_string2" => code(data["order_id"]),
      "amount3" => data["amount"]
    }
    |> drop_nils()
  end

  defp render(:wechat, "refund_succeeded", %{} = data) do
    %{
      "character_string2" => code(data["order_id"]),
      "amount3" => data["amount"],
      "phrase8" => "退款成功"
    }
    |> drop_nils()
  end

  defp render(:wechat, "refund_failed", %{} = data) do
    %{
      "character_string2" => code(data["order_id"]),
      "amount1" => data["amount"],
      "thing3" => "退款未到账，平台将重试或与你联系",
      "phrase5" => "退款失败"
    }
    |> drop_nils()
  end

  defp render(:wechat, "event_qualification_confirmed", %{} = data) do
    %{
      "thing4" => thing(data["title"]),
      "number16" => number(data["confirmed_count"]),
      "thing7" => thing(qualified_note(data["min_participants"]))
    }
    |> drop_nils()
  end

  defp render(:wechat, "event_qualification_underfilled", %{} = data) do
    %{
      "thing1" => thing(data["title"]),
      "thing5" => thing(underfilled_note(data["min_participants"]))
    }
    |> drop_nils()
  end

  defp render(:wechat, "event_schedule_changed", %{} = data) do
    %{
      "thing1" => thing(data["title"]),
      "date2" => date(data["starts_at"]),
      "thing5" => thing(blank_to_nil(data["venue"]))
    }
    |> drop_nils()
  end

  defp render(:wechat, "event_moderator_assigned", %{} = data) do
    %{
      "thing1" => thing(data["title"]),
      "thing5" => "你已被指派为该活动主理人"
    }
    |> drop_nils()
  end

  defp render(:wechat, "speaker_accepted", %{} = data) do
    %{
      "thing14" => thing(data["title"]),
      "thing6" => "已接受"
    }
    |> drop_nils()
  end

  defp render(:wechat, "speaker_completed", %{} = data) do
    %{
      "thing1" => thing(data["title"]),
      "thing4" => "分享已完成，材料已归档"
    }
    |> drop_nils()
  end

  defp render(:wechat, "learning_stagnation", %{} = data) do
    %{
      "thing1" => thing(data["title"]),
      "thing4" => "长时间未继续学习，记得回来完成学习"
    }
    |> drop_nils()
  end

  # 志愿者段位通知六模板（U4/KTD6；R14 阶段通知表逐行）。**模板 ID 待申请**，
  # 字段编号按「每模板 = 批次/场次 + 状态细节 + 固定提示」的最小形状拟定，
  # 申请到模板后按公众平台「我的模板 → 详情」核对槽位并就地改（先例 #606）。
  #
  # 逻辑键（data_keys）与收件人：
  # - submitted「提交确认」：批次名/职位/固定「申请已提交，等待初审」
  # - interview「面试安排」：批次名/群面时间（time2，批次执行周期开始；群面约时
  #   为线下运营动作，缺排期时该字段跳过——入群方式文案在邮件里）/固定「运营将
  #   联系你入群」
  # - training「训练营预约」：批次名/训练营排期（time2）/固定「凭邀请码在课程页
  #   自助报名」
  # - assigned「分配结果」：场次名（Tutor 可无场次）/课程任务（assignment_note）/
  #   固定「项目分配已完成」保底（两值皆缺时不至空 data）
  # - rejected「拒绝通知」：批次名/拒绝原因（thing 顶 20 字，全文在邮件）/
  #   固定「很遗憾，本次申请未通过」
  # - canceled「取消通知」：批次名/取消备注（选填）/固定「申请已取消」
  # 招募六段：槽位编号为各模板实际字段（2026-09-18 微信后台实抄，与
  # miniprogram_templates 的 template_id 一一对应）；数据语义不变，仅键名对齐。

  defp render(:wechat, "volunteer_application_submitted", %{} = data) do
    %{
      "thing7" => thing(data["cohort_name"]),
      "thing5" => thing(data["position_label"]),
      "thing6" => "申请已提交，等待初审"
    }
    |> drop_nils()
  end

  defp render(:wechat, "volunteer_application_interview", %{} = data) do
    %{
      "thing5" => thing(data["cohort_name"]),
      # date3 为 date 类型：走 date/1（年月日 + 时刻，官方支持形态）
      "date3" => date(data["group_time"]),
      "thing7" => "运营将联系你入群"
    }
    |> drop_nils()
  end

  defp render(:wechat, "volunteer_application_training", %{} = data) do
    %{
      "thing39" => thing(data["cohort_name"]),
      "time47" => time(data["training_starts_at"]),
      "thing19" => "凭邀请码在课程页自助报名"
    }
    |> drop_nils()
  end

  defp render(:wechat, "volunteer_application_assigned", %{} = data) do
    %{
      "thing19" => thing(data["event_title"]),
      "thing7" => thing(data["assignment_note"]),
      "thing5" => "项目分配已完成"
    }
    |> drop_nils()
  end

  defp render(:wechat, "volunteer_application_rejected", %{} = data) do
    %{
      "thing21" => thing(data["cohort_name"]),
      "thing12" => thing(data["rejection_reason"]),
      "thing11" => "很遗憾，本次申请未通过"
    }
    |> drop_nils()
  end

  defp render(:wechat, "volunteer_application_canceled", %{} = data) do
    %{
      "thing1" => thing(data["cohort_name"]),
      "thing4" => thing(data["cancel_note"]),
      "thing9" => "申请已取消"
    }
    |> drop_nils()
  end

  defp render(_platform, _template_key, data), do: data

  defp drop_nils(fields), do: Map.reject(fields, fn {_k, v} -> is_nil(v) end)

  # 缺值与空串同义（venue / tier_name 键可能整体缺失 → nil 而非 ""）
  defp blank_to_nil(nil), do: nil
  defp blank_to_nil(""), do: nil
  defp blank_to_nil(text) when is_binary(text), do: text

  # thing ≤20 字：「订单超时作废，报名截止前可重新报名」恰 17 字
  defp expiry_note("true"), do: "订单超时作废，报名截止前可重新报名"
  defp expiry_note(_), do: "订单超时作废"

  # 开班结果动态文案（#606）：thing ≤20 字。min 1/2/3 位 → 10/11/12 字
  # （confirmed）与 16/17/18 字（underfilled），守卫测试钉边界；min ≥6 位时
  # 由外层 thing/1 截断到 20（保 API 不 47003，代价是句子截尾——min_participants
  # 是组织者配置项，实际不会到 6 位）
  defp qualified_note(min) when is_integer(min), do: "已达最低成班人数#{min}人"
  defp qualified_note(_), do: nil

  defp underfilled_note(min) when is_integer(min), do: "未达最低成班人数#{min}人，活动未成行"
  defp underfilled_note(_), do: nil

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

  # 核销码（#546）：Enrollment 侧约束 match ~r/^\d{6}$/（6 位数字串），不走 code/1
  # 的去连字符路径；非 binary / 空串 → nil 跳过该字段（字符型槽位格式非法会整条
  # 47003 拒收，宁可少字段——与 date/1 的兜底语义一致）。
  defp check_in_code(code) when is_binary(code) and code != "", do: String.slice(code, 0, 32)
  defp check_in_code(_), do: nil

  # time.DATA：统一 "YYYY-MM-DD HH:MM"（北京时间，+8 折算见 beijing/1；#606 修复前
  # 直接 strftime UTC 值，event_reminder time3 / approval_reminder time11 比用户面
  # 早 8 小时）；字符串入参（Oban args JSON 化后）先解析
  defp time(%DateTime{} = dt), do: Calendar.strftime(beijing(dt), "%Y-%m-%d %H:%M")
  defp time(nil), do: nil

  defp time(iso) when is_binary(iso) do
    case DateTime.from_iso8601(iso) do
      {:ok, dt, _offset} -> time(dt)
      {:error, _} -> String.slice(iso, 0, 32)
    end
  end

  # date.DATA（#606）：微信「年月日格式（支持+24小时制时间）」，官方例
  # 「2019年10月1日 15:01」——date2 刻意带时刻：改期通知必须让用户看到新时间
  # （#594/#617 教训）。**格式假设未经真机验证**（申请方按红线未做测试发送），
  # 暴露点 = 前端订阅触点落地后的首次真发送。若平台 47003 拒收带时刻，唯一
  # 回退点两行：① 本函数格式串去掉 " %H:%M"（date-only，官方另一种合法形态）；
  # ② event_schedule_changed 子句的 thing5 改放「改期至 9月20日 15:00」
  # （15-16 字 ≤20，需新增 schedule_note/1 走同一 beijing/1），其余子句、名单、
  # 测试不动。解析失败 → nil 跳过该字段（date 槽位格式非法会整条 47003 拒收，
  # 宁可少字段——与 time/1 的兜底串语义有意不同）。
  defp date(%DateTime{} = dt), do: Calendar.strftime(beijing(dt), "%Y年%-m月%-d日 %H:%M")
  defp date(nil), do: nil

  defp date(iso) when is_binary(iso) do
    case DateTime.from_iso8601(iso) do
      {:ok, dt, _offset} -> date(dt)
      {:error, _} -> nil
    end
  end

  # 北京时间固定 UTC+8（#606）：项目无 tzdata 依赖（Calendar 默认 UTCOnly，
  # shift_zone 不可用），先例 events/speaker_invitation_email.ex:175-179。
  # 供时间类槽位渲染共用：starts_at / approval_deadline 均为 UTC 瞬时
  # （`:utc_datetime` 属性 + DateTime.to_iso8601 构造），前端按设备本地时区显示
  # ⇒ 后端渲染统一 +8 折算。
  defp beijing(%DateTime{} = dt), do: DateTime.add(dt, 8 * 3600, :second)

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
