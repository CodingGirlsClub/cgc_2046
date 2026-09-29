defmodule Cgc2046Web.GraphqlSchema.Flashback.WishTypes do
  @moduledoc """
  闪念间（In a Flash）类型下半：看板 / 兑换 / 触达运营台 / 删除 /
  公开层与许愿树契约。
  """

  use Absinthe.Schema.Notation

  # ── 看板与兑换（U11/R24/R25）────────────────────────────────────────

  object :flashback_rates do
    @desc "分母：成功送达人数（sent 的 distinct person，硬退信与退订剔除）"
    field(:delivered, non_null(:integer))
    field(:link_opened, non_null(:integer))
    field(:revealed, non_null(:integer))
    field(:sent_to_wall, non_null(:integer))
    field(:intent_submitted, non_null(:integer))
  end

  object :flashback_admin_stats do
    @desc "记忆线（participation=attended）四率"
    field(:memory, non_null(:flashback_rates))
    @desc "圆梦线（participation=not_selected）四率"
    field(:dream, non_null(:flashback_rates))
    field(:overall, non_null(:flashback_rates))
  end

  object :flashback_redemption do
    field(:id, non_null(:id))
    field(:status, non_null(:string))
    @desc "用户提交的收款渠道信息（admin-only，KTD3）"
    field(:channel_note, non_null(:string))
    field(:handled_note, :string)
    field(:inserted_at, :string)
    @desc "掩码署名（姓** · 城市）——运营定位用"
    field(:masked_name, :string)
    field(:city, :string)
  end

  object :flashback_redemption_update_result do
    field(:id, non_null(:id))
    field(:status, non_null(:string))
  end

  # ── 触达运营台（R4/R8/R9）────────────────────────────────────────────
  object :flashback_admin_archive do
    field(:key, non_null(:string))
    field(:name, non_null(:string))
    # 教练场等档案无具体日期/城市（occurred_on/city 可空，运营后台直建）
    field(:city, :string)
    field(:occurred_on, :string)
  end

  object :flashback_outreach_preview do
    field(:archive_key, non_null(:string))
    field(:archive_name, non_null(:string))
    @desc "所选通道档的预估入队数"
    field(:channel, non_null(:string))
    field(:queued, non_null(:integer))
    @desc "三档分布：仅邮件可达 / 仅短信可达 / 双通道"
    field(:email_only, non_null(:integer))
    field(:sms_only, non_null(:integer))
    field(:both, non_null(:integer))
    field(:unsubscribed, non_null(:integer))
    field(:unreachable, non_null(:integer))
    @desc "campaign 去重预判（batch 参数非空时：可达人中联系方式命中该批次已有成功触达的人数；未传 batch 恒 0）"
    field(:deduped_within_campaign, non_null(:integer))
    @desc "短信腿就绪位（SendCloud 触达模板已配置）"
    field(:sms_ready, non_null(:boolean))
  end

  object :flashback_outreach_batch_channel do
    field(:queued, non_null(:integer))
    field(:sent, non_null(:integer))
    field(:failed, non_null(:integer))
  end

  object :flashback_outreach_batch do
    field(:batch, non_null(:string))
    field(:template, non_null(:string))
    field(:email, non_null(:flashback_outreach_batch_channel))
    field(:sms, non_null(:flashback_outreach_batch_channel))
    @desc "批次最早建行时刻（触发时间近似）"
    field(:first_at, :string)
  end

  object :flashback_outreach_last do
    field(:channel, non_null(:string))
    field(:status, non_null(:string))
    field(:batch, non_null(:string))
    field(:at, :string)
  end

  object :flashback_outreach_roster_entry do
    field(:person_id, non_null(:id))
    field(:full_name, non_null(:string))
    @desc "完整联系方式（KD6/R13：platform_admin 门控，排查核对用）"
    field(:email, :string)
    field(:phone, :string)
    field(:claimed, non_null(:boolean))
    field(:participation, non_null(:string))
    field(:unsubscribed, non_null(:boolean))
    field(:deleted, non_null(:boolean))
    field(:email_reachable, non_null(:boolean))
    field(:sms_reachable, non_null(:boolean))
    field(:last_outreach, :flashback_outreach_last)
  end

  object :flashback_redeem_result do
    field(:status, non_null(:string))
    field(:updated, non_null(:boolean))
  end

  # ── 删除（U10/R30/ADR-0015）────────────────────────────────────────
  object :flashback_delete_result do
    field(:deleted, non_null(:boolean))
    field(:deleted_at, non_null(:string))
  end

  object :flashback_delete_preview_result do
    field(:person_id, non_null(:id))
    field(:full_name, non_null(:string))
    @desc "寄出态（撤下提示依据）；未寄出为 null"
    field(:sent_to_wall_at, :string)
    @desc "将一并删除的附议数"
    field(:endorsement_count, non_null(:integer))
    field(:already_deleted, non_null(:boolean))
  end

  # ── 公开层类型（U6/R32）：路人可见的故事与授权的名字，不是名单 ──────────
  object :flashback_public_stats_archive do
    field(:key, non_null(:string))
    field(:name, :string)
    field(:city, :string)
    field(:occurred_on, :string)
    field(:applied_count, :integer)
    field(:attended_count, :integer)
    field(:label, :string)
  end

  object :flashback_public_stats do
    field(:archives, non_null(list_of(non_null(:flashback_public_stats_archive))))
    @desc "已回来人数（distinct link_opened touch）"
    field(:returned_count, non_null(:integer))
    field(:sent_count, non_null(:integer))
  end

  object :flashback_public_quote do
    @desc "授权金句文本（区间切片；雾面句本就不进候选）"
    field(:text, non_null(:string))
    @desc "署名：王** · 年 · 城"
    field(:attribution, non_null(:string))
    field(:level, non_null(:string))
    @desc "credited 档才有：链实名档案页"
    field(:public_slug, :string)
    @desc "单句定位键（R37）：flashbackLikeQuote 的 quoteId 入参 / 分享链接 ?item="
    field(:quote_id, non_null(:id))
    @desc "城市快照（选城浏览用）"
    field(:city, :string)
    @desc "年份快照（选城浏览用）"
    field(:year, :integer)
    @desc "实时点赞数（R36，无冗余计数列）"
    field(:like_count, non_null(:integer))
    @desc "本访客是否已赞（按 voterKey 去重；未传 voterKey 恒 false）"
    field(:liked_by_viewer, non_null(:boolean))
  end

  object :flashback_public_profile do
    field(:full_name, non_null(:string))
    field(:city, :string)
    field(:event_name, :string)
    field(:year, :integer)
    @desc "实名补充：现在在做什么、想法（R31 credited 档）"
    field(:credited_note, :string)
    field(:quote, non_null(:string))
  end

  object :flashback_recover_result do
    @desc "恒 true 形态：命中与未命中同形返回（不泄露存在性）"
    field(:dispatched, non_null(:boolean))
  end

  object :flashback_recover_card do
    field(:person_id, non_null(:id))
    field(:surname_masked, non_null(:string))
    field(:event_name, :string)
    field(:city, :string)
  end

  object :flashback_recover_verify_result do
    field(:bound, non_null(:boolean))
    @desc "绑定档案的脱敏卡列表——多档案=「你的 N 张卡」由本人选择先看哪张"
    field(:cards, non_null(list_of(non_null(:flashback_recover_card))))
  end

  object :flashback_fog_span do
    @desc "雾面区间：grapheme 偏移（start 起、len 长），reason 可选"
    field(:start, non_null(:integer))
    field(:len, non_null(:integer))
    field(:reason, :string)
  end

  object :flashback_answer do
    @desc "当年答案（本人视图：raw_text 永远完整，KTD4）"
    field(:id, non_null(:id))
    field(:question_key, non_null(:string))
    field(:raw_text, non_null(:string))
    field(:fog_spans, list_of(:flashback_fog_span))
  end

  object :flashback_archive_ref do
    field(:key, non_null(:string))
    field(:name, :string)
    field(:city, :string)
    field(:occurred_on, :string)
  end

  object :flashback_profile do
    field(:full_name, non_null(:string))
    field(:surname, :string)
    field(:city, :string)
    field(:occupation_then, :string)
    field(:gender, :string)
    field(:role, non_null(:string))
    field(:participation, non_null(:string))
    field(:applied_at, :string)
    @desc "匿名署名预览「王** · 年 · 城」（#1022）：与金句墙署名同源，寄出前预览逐字一致"
    field(:anonymous_attribution, non_null(:string))
    field(:archive, :flashback_archive_ref)
    field(:answers, list_of(:flashback_answer))
  end

  object :flashback_today do
    field(:now_status, :string)
    field(:want, :string)
    field(:need, :string)
    field(:say, :string)
    @desc "句级雾面区间（字段名 → spans；U9/R16，空 map = 无雾）"
    field(:fog_spans, :json)
    field(:want_give_tags, list_of(:string))
    field(:mobilization, :json_string)
    field(:newsletter_opt_in, :boolean)
    field(:reconnect_tags, list_of(:string))
    field(:sent_to_wall_at, :string)
  end

  object :flashback_progress do
    field(:bound, non_null(:boolean))
    field(:today, :flashback_today)
    field(:quote_level, non_null(:string))
    field(:masked_phone, :string)
    field(:masked_email, :string)
  end

  object :flashback_enter_result do
    @desc "进入结果：line = memory（记忆线）| dream（圆梦线）；失效走顶层错误 code（flashback_token_not_found/claimed/revoked）"
    field(:line, non_null(:string))
    field(:profile, :flashback_profile)
    field(:progress, :flashback_progress)

    @desc "桌面散照候选（R5 数据驱动）：本人那张 + 其他场次各一人；空库时仅本人一张"
    field(:scatter, :flashback_scatter)
  end

  object :flashback_scatter do
    field(:entries, non_null(list_of(non_null(:flashback_scatter_photo))))
  end

  object :flashback_scatter_photo do
    @desc "照片定位键（本人 = 本人档案 id；他人 = 他人档案 id）"
    field(:photo_key, non_null(:id))

    @desc "场次全名标签「年份 · 城市」——问答选项与读屏线索用（散照卡只显日期戳）"
    field(:label, non_null(:string))

    @desc "拍立得日期戳「2016 10 15」——放大时渐显，只给日期不给城市（谜不泄底）"
    field(:date_stamp, non_null(:string))

    @desc "是否本人那张"
    field(:is_mine, non_null(:boolean))

    @desc "照片主人姓氏（前端渲染姓氏级脱敏 王**，R12）"
    field(:surname, :string)
  end

  object :flashback_touch_result do
    field(:recorded, non_null(:boolean))
  end

  object :flashback_today_result do
    field(:today, :flashback_today)
  end

  object :flashback_send_to_wall_result do
    field(:sent_to_wall_at, :string)
    field(:masked_phone, :string)
    field(:masked_email, :string)
  end

  object :flashback_adjust_today_fog_result do
    field(:field, non_null(:string))
    field(:fog_spans, :json)
  end

  object :flashback_adjust_fog_result do
    field(:answer_id, non_null(:id))
    field(:fog_spans, list_of(:flashback_fog_span))
  end

  object :flashback_quote_stats do
    @desc "点赞数（R36：作者侧回访面，实时 COUNT）"
    field(:like_count, non_null(:integer))
  end

  object :flashback_claim_result do
    @desc "是否已绑定（false = 库里没有匹配的未认领档案）"
    field(:bound, non_null(:boolean))
    @desc "本次绑定/已绑定的档案数"
    field(:bound_count, non_null(:integer))
    @desc "掩码回显（完整号码不出接口）"
    field(:masked_phone, :string)
  end

  object :flashback_quote_hidden_result do
    field(:person_id, non_null(:id))
    @desc "操作后的下线态（true=已下线）"
    field(:hidden, non_null(:boolean))
  end

  object :flashback_quote_like_result do
    @desc "点赞后的实时计数——前端就地更新，免二次拉取"
    field(:like_count, non_null(:integer))
  end

  # ── wish2 U6 公开许愿树契约（KTD10 白名单字段）──────────────────────

  object :flashback_public_wish do
    field(:id, non_null(:id))
    field(:content, non_null(:string))
    @desc "期望地短名（Cities.normalize 归一；null = 未填）"
    field(:city, :string)
    @desc "署名快照（匿名遮罩姓 王** 或实名 display_name；创建时定型）"
    field(:signature, non_null(:string))
    field(:expectation_count, non_null(:integer))
    field(:endorsement_count, non_null(:integer))
    @desc "出力分布（venue/organize/speak/sponsor/other → count）——从 endorsements 聚合"
    field(:contribution_distribution, non_null(:json))
    field(:expected_by_viewer, non_null(:boolean))
    field(:endorsed_by_viewer, non_null(:boolean))
    field(:latest_echo, :flashback_public_wish_echo)
    field(:echo_count, non_null(:integer))
    field(:echoes, non_null(list_of(non_null(:flashback_public_wish_echo))))
    field(:listed_at, non_null(:datetime))
    field(:inserted_at, non_null(:datetime))
  end

  object :flashback_public_wish_echo do
    field(:id, non_null(:id))
    field(:content, non_null(:string))
    field(:status, non_null(:string))
    field(:published_at, non_null(:datetime))
    field(:corrected_at, :datetime)
  end

  object :flashback_city do
    @desc "短名（成都）"
    field(:name, non_null(:string))
    @desc "全称（成都市）"
    field(:full_name, non_null(:string))
    field(:pinyin, non_null(:string))
    @desc "中心坐标 [lng, lat]（GeoJSON 形状，G9）"
    field(:lng_lat, non_null(list_of(non_null(:float))))
  end

  object :flashback_wish_expect_result do
    @desc "期待后的实时计数 + 本人态"
    field(:expectation_count, non_null(:integer))
    field(:expected_by_me, non_null(:boolean))
  end

  object :flashback_wish_endorse_result do
    field(:endorsement_count, non_null(:integer))
    field(:endorsed_by_me, non_null(:boolean))
  end

  object :flashback_report_result do
    field(:report_id, non_null(:id))
    field(:status, non_null(:string))
  end

  object :flashback_wish_hidden_result do
    field(:wish_id, non_null(:id))
    @desc "操作后的下架态（true=已下架）"
    field(:hidden, non_null(:boolean))
  end

  object :flashback_wish_listing_approve_result do
    field(:wish_id, non_null(:id))
    @desc "放行后的挂树时间（幂等时为原值）"
    field(:listed_at, :datetime)
    @desc "放行后对客户端的三态反馈（listed/pending_review/private，同创建口径）"
    field(:status, :string)
  end

  object :flashback_admin_wish_inbox_entry do
    field(:wish_id, non_null(:id))
    field(:content, non_null(:string))
    field(:city, :string)
    field(:signature, non_null(:string))
    field(:inserted_at, non_null(:datetime))
    @desc "作者遮罩姓（王**）"
    field(:wisher_masked, :string)
    @desc "作者登录账号联系方式（仅 platform admin；公开 GraphQL 永不返回）"
    field(:wisher_phone, :string)
    field(:wisher_email, :string)
  end

  object :flashback_admin_report_entry do
    field(:report_id, non_null(:id))
    field(:target_type, non_null(:string))
    field(:target_id, non_null(:id))
    field(:reason_type, non_null(:string))
    field(:reason_free, :string)
    field(:status, non_null(:string))
    field(:inserted_at, non_null(:datetime))
  end

  # 多句金句:每句自带宿主与区间(grapheme 偏移,结构同 fog span)
  input_object :flashback_quote_span_input do
    field(:question_key, non_null(:string))
    field(:start, non_null(:integer))
    field(:len, non_null(:integer))
  end

  object :flashback_quote_span do
    field(:question_key, non_null(:string))
    field(:start, non_null(:integer))
    field(:len, non_null(:integer))
  end

  object :flashback_quote_license_result do
    field(:level, non_null(:string))
    field(:chosen_quote_spans, list_of(:flashback_quote_span))
    field(:credited_note, :string)
  end

  object :flashback_retract_result do
    field(:retracted, non_null(:boolean))
    field(:sent_to_wall_at, :string)
  end

  object :flashback_register_bind_result do
    field(:bound, non_null(:boolean))
    field(:masked_phone, :string)
  end

  object :flashback_update_contact_result do
    field(:masked_phone, :string)
    field(:updated, non_null(:boolean))
  end

  object :flashback_outreach_dispatch_result do
    @desc "入队件数（错峰 scheduled_at 限速后由 worker 续发）"
    field(:queued, non_null(:integer))
    @desc "跳过件数（已退订 / 无可用通道 / 本批次已入队——幂等重跑计入此处）"
    field(:skipped, non_null(:integer))
    @desc "campaign 去重件数（同批次内联系方式命中他人已有成功触达——同人跨 archive 只收一封）"
    field(:deduped_within_campaign, non_null(:integer))
  end

  input_object :flashback_today_input do
    @desc "「今天的你」问卷（R8）：四个自由文本 + Want/Give 标签 + 动员勾选（R20）+ Newsletter（R18）+ Reconnect（R19）"
    field(:now_status, :string)
    field(:want, :string)
    field(:need, :string)
    field(:say, :string)
    field(:want_give_tags, list_of(:string))
    field(:mobilization_join_1024, :boolean)
    field(:mobilization_help_promote, :boolean)
    field(:mobilization_donate_intent, :boolean)
    field(:mobilization_volunteer_lead, :boolean)
    field(:newsletter_opt_in, :boolean)
    field(:reconnect_tags, list_of(:string))
  end

  input_object :flashback_fog_span_input do
    field(:start, non_null(:integer))
    field(:len, non_null(:integer))
    field(:reason, :string)
  end
end
