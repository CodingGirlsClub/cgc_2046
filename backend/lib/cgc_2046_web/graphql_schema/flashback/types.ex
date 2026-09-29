defmodule Cgc2046Web.GraphqlSchema.Flashback.Types do
  @moduledoc """
  闪念间（In a Flash）类型上半：首程 token 面 / 胶囊 / 分享 / 档案 /
  愿望 / 回声与留言。
  """

  use Absinthe.Schema.Notation

  # ── 闪念间（In a Flash）首程 token 面类型（U2；手写 field 专用） ──────────
  # 投影纪律（KTD3）：白名单列字段；phone/email 明文绝不出现（只有掩码）。
  # 圆梦线 CTA 两态指路（U4）：只投指路字段，无个人数据。
  object :flashback_dream_target do
    field(:event_slug, non_null(:string))
    field(:event_title, non_null(:string))
    field(:starts_at, :datetime)
    field(:initiative_slug, non_null(:string))
  end

  # ── 时间胶囊（U5）校友层类型：分层墙（R12）与行动板（R13） ──────────────
  # 投影纪律（KTD3）：白名单列字段；手机/邮箱不进任何投影；他人答案一律雾化。

  object :flashback_capsule_today do
    field(:now_status, :string)
    field(:want, :string)
    field(:need, :string)
    field(:say, :string)
    @desc "句级雾面：field(now/want/need/say) → spans；本人管理面专用"
    field(:fog_spans, :json)
    field(:sent_to_wall_at, :string)
  end

  object :flashback_capsule_me do
    field(:id, non_null(:id))
    field(:full_name, non_null(:string))
    field(:surname, :string)
    field(:city, :string)
    field(:occupation_then, :string)
    field(:participation, non_null(:string))
    field(:applied_at, :string)
    field(:today, :flashback_capsule_today)
    @desc "金句授权档（R31：off/anonymous/credited；无授权行为 off）——回访端恢复选中态"
    field(:quote_level, non_null(:string))
    @desc "选定金句（R14 摘要卡；off/未选为 null）"
    field(:quote, :string)
    @desc "句子白名单区间列表（首句 = 消费面展示句;圈选器回显全量）"
    field(:quote_spans, list_of(:flashback_quote_span))
    @desc "匿名署名预览「王** · 年 · 城」（#1022）：与金句墙署名同源，寄出前预览逐字一致"
    field(:anonymous_attribution, non_null(:string))
    @desc "本人金句的点赞数（R36；仅匿名/实名授权档返回，未授权为 null）"
    field(:quote_stats, :flashback_quote_stats)
    @desc "本人当年答案（U9 起含原文与既有雾面区间——编辑雾化消费面；text 仍为雾化版）"
    field(:answers, non_null(list_of(non_null(:flashback_me_answer))))
    @desc "卡片分享（#771）：开关态 + 标识 + 本人预览；预览独立于公开门（关着也有）"
    field(:card_sharing, non_null(:flashback_card_sharing))
  end

  # ── 卡片分享（#771）：本人管理面 + 匿名公开面 ──────────────────────────
  # 投影纪律（KTD3 同款）：分享卡只出隐名（王**）+ 城市 + 报名时间 +
  # 当年三题与今天四格；手机/邮箱/性别/职业/公开 slug/授权档一律不进 SELECT。
  # 雾面段 text 恒空串——原文字符不出响应体（FogSpans.segments 保证）。
  object :flashback_card_sharing do
    @desc "分享链接是否可被访客解析（关 = 链接 404，标识仍保留）"
    field(:enabled, non_null(:boolean))
    @desc "分享标识：首开铸出后**永不变**（关闭不清、重开复用）；从未开启为 null"
    field(:share_id, :string)
    @desc "本人预览（与公开面同一投影，不受 enabled 门限制）；档案已删除为 null"
    field(:preview, :flashback_shared_card)
  end

  object :flashback_shared_card do
    @desc "隐名（姓氏 + 星号，如 王**）；分享卡无亮名路径"
    field(:display_name, non_null(:string))
    field(:city, :string)
    @desc "报名时间戳（ISO8601，精确到秒）；落款用——她写下这张卡的那一刻"
    field(:applied_at, :string)
    @desc "活动举办日（ISO8601 日期，如 2014-01-11）；头部场景定位用——记忆真正发生的那天"
    field(:occurred_on, :string)
    @desc "当年答案（实时保存数据，无「已寄出」前置）：键 self_intro / funny_thing / os；空节剔除"
    field(:answers, non_null(list_of(non_null(:flashback_shared_card_section))))
    @desc "今天四格（实时保存数据）：键 today.now / today.want / today.need / today.say；空节剔除"
    field(:today, non_null(list_of(non_null(:flashback_shared_card_section))))
  end

  object :flashback_shared_card_section do
    field(:question_key, non_null(:string))
    @desc "段结构（原文顺序）：明文段 text 有字、雾面段 text 恒空串（原文零泄露），len 供视觉档位"
    field(:segments, non_null(list_of(non_null(:flashback_shared_card_segment))))
  end

  object :flashback_shared_card_segment do
    field(:text, non_null(:string))
    field(:fog, non_null(:boolean))
    field(:len, non_null(:integer))
  end

  object :flashback_me_answer do
    field(:id, non_null(:id))
    field(:question_key, non_null(:string))
    @desc "原文（KTD4：本人在任何视图永远完整）"
    field(:raw_text, non_null(:string))
    @desc "既有雾面区间（本人调整的起点）"
    field(:fog_spans, non_null(list_of(non_null(:flashback_fog_span))))
    @desc "雾化版（与墙上呈现同规则，R15 全文卡）"
    field(:text, non_null(:string))
  end

  object :flashback_roster_segment do
    @desc "雾面段（对外版）：fog=true 时 text 恒为空——原文字符不出 DOM，len 供视觉档位"
    field(:text, non_null(:string))
    field(:fog, non_null(:boolean))
    field(:len, non_null(:integer))
  end

  object :flashback_roster_answer do
    @desc "当年答案（对外版）：段结构——明文段与雾面段交替，雾面段零字符泄露"
    field(:question_key, non_null(:string))
    field(:segments, non_null(list_of(non_null(:flashback_roster_segment))))
  end

  object :flashback_roster_entry_today do
    field(:now_status, :string)
    field(:want, :string)
    field(:say, :string)
  end

  object :flashback_roster_entry do
    field(:id, non_null(:id))
    @desc "姓氏隐名（R12）：王**；名册结构化卡的核心标识"
    field(:surname_masked, non_null(:string))
    @desc "寄出者全名（用户定稿：她回来了即亮名）；未寄出者 null（隐名）"
    field(:full_name, :string)
    @desc "寄出者的报名时间戳（翻转卡正面白边）；未寄出者 null"
    field(:applied_at, :string)
    field(:city, :string)
    field(:occupation_then, :string)
    @desc "attended | not_selected（圆梦线名册徽标用）。#933 起仅已寄出者下发；未寄出者 null（只剩姓氏遮罩）"
    field(:participation, :string)
    field(:sent_to_wall_at, :string)
    @desc "nil = 未寄出（前端渲染虚线内容位「她的答案，还在等她」）"
    field(:today, :flashback_roster_entry_today)
    @desc "空数组 = 未寄出；寄出者才有内容层（雾化版当年答案）"
    field(:answers, non_null(list_of(non_null(:flashback_roster_answer))))
  end

  object :flashback_archive_pile do
    field(:city, non_null(:string))
    field(:count, non_null(:integer))
    field(:returned, non_null(:integer))
  end

  @desc "相册读面（#933）：已登录即可读的场次时间轴与名册"
  object :flashback_archives_result do
    field(:archives, non_null(list_of(non_null(:flashback_capsule_archive))))
    field(:cities, non_null(list_of(non_null(:string))))
  end

  object :flashback_capsule_archive do
    field(:key, non_null(:string))
    field(:name, :string)
    field(:city, :string)
    field(:occurred_on, :string)
    field(:applied_count, :integer)
    field(:attended_count, :integer)

    @desc "长廊场次格叙事短标签（原型 D ia-frame-label）：「六城同日」写故事不写地名"
    field(:label, :string)
    @desc "本人的场次（胶囊「今天」格与本人名册卡的定位锚）"
    field(:is_mine, non_null(:boolean))
    field(:roster, non_null(list_of(non_null(:flashback_roster_entry))))
    @desc "城市堆（#933 服务端聚合）：按人的城市计数（含未寄出者的聚合数）+ 已回来数；人数降序 + 城市序"
    field(:piles, non_null(list_of(non_null(:flashback_archive_pile))))
  end

  object :flashback_capsule do
    field(:me, non_null(:flashback_capsule_me))
    field(:archives, non_null(list_of(non_null(:flashback_capsule_archive))))
    @desc "未来场次帧：按 initiative 分组、组内按场次时间升序（KTD1）；报名直链 /events/{slug}"
    field(:future_events, non_null(list_of(non_null(:flashback_future_frame))))
    @desc "公开愿望（附议数降序）；城市钉筛选时无城市许愿恒显示"
    field(:public_wishes, non_null(list_of(non_null(:flashback_wish))))
    @desc "本人私有许愿（私人许愿帧，仅自己可见）"
    field(:my_private_wishes, non_null(list_of(non_null(:flashback_wish))))
    @desc "本人今年剩余许愿额度（每年 3 条，R20）；capsule 可解析时恒有值，nullable 仅为 schema 演进安全"
    field(:my_wish_quota_remaining, :integer)
    @desc "城市钉数据源（R34）：有名册成员的城市，去重排序；不随 city 过滤收缩"
    field(:cities, non_null(list_of(non_null(:string))))
  end

  object :flashback_future_frame do
    @desc "帧头跳转目标：/initiatives/{initiative_slug}（R1）"
    field(:initiative_slug, non_null(:string))
    field(:initiative_name, non_null(:string))
    @desc "未显影帧时间：initiative 窗口开始时间（未来=还没冲洗的底片,报名/附议即显影）"
    field(:initiative_starts_at, :datetime)
    field(:events, non_null(list_of(non_null(:flashback_future_event))))
  end

  object :flashback_future_event do
    field(:id, non_null(:id))
    @desc "报名直链：/events/{slug}（R2/R3，不在走廊内闭环）"
    field(:slug, non_null(:string))
    field(:title, non_null(:string))
    field(:city, :string)
    field(:starts_at, :datetime)
    @desc "名额进度（U7 与 web enrollmentBadge 口径对齐）"
    field(:capacity, :integer)
    field(:confirmed_count, non_null(:integer))
    field(:registration_deadline, :datetime)
  end

  object :flashback_wish do
    field(:id, non_null(:id))
    field(:content, non_null(:string))
    field(:city, :string)
    @desc "许愿人遮罩姓（王**）"
    field(:wisher_masked, :string)
    field(:endorsement_count, non_null(:integer))
    @desc "本人已附议（已附议态渲染依据，R7）"
    field(:endorsed_by_me, non_null(:boolean))
    @desc "本人许愿（删除入口只对本人显示，R14）"
    field(:mine, non_null(:boolean))
    field(:comments, non_null(list_of(non_null(:flashback_wish_comment))))
    field(:latest_echo, :flashback_public_wish_echo)
    field(:echo_count, non_null(:integer))
    field(:echoes, non_null(list_of(non_null(:flashback_public_wish_echo))))
    field(:inserted_at, non_null(:datetime))
  end

  object :flashback_admin_wish_echo do
    field(:id, non_null(:id))
    field(:content, non_null(:string))
    field(:status, non_null(:string))
    field(:inserted_at, non_null(:datetime))
    field(:published_at, :datetime)
    field(:corrected_at, :datetime)
    field(:revoked_at, :datetime)
    @desc "发布时的 PlatformAdmin UUID，仅 admin 读面"
    field(:published_by_user_id, :id)
  end

  object :flashback_admin_wish_echoes_result do
    field(:echoes, non_null(list_of(non_null(:flashback_admin_wish_echo))))
    field(:current_notifiable_endorsement_count, non_null(:integer))
  end

  object :flashback_admin_listed_wish_entry do
    field(:wish_id, non_null(:id))
    field(:content, non_null(:string))
    field(:signature, :string)
    field(:city, :string)
    field(:listed_at, non_null(:datetime))
    @desc "已发布/已更正回响数（公开可见）"
    field(:published_echo_count, non_null(:integer))
    @desc "草稿回响数（仅 admin）"
    field(:draft_echo_count, non_null(:integer))
  end

  @desc "#817 admin 巡检行：已授权挂树的公开愿望（三态 listed/pending_review/hidden）"
  object :flashback_admin_public_wish_entry do
    field(:wish_id, non_null(:id))
    field(:content, non_null(:string))
    field(:signature, :string)
    field(:city, :string)
    field(:inserted_at, non_null(:datetime))
    field(:listed_at, :datetime)
    field(:hidden_at, :datetime)
    @desc "listed=挂树可见 / pending_review=待审 / hidden=挂树后被下架"
    field(:status, non_null(:string))
    @desc "期待数"
    field(:expectation_count, non_null(:integer))
    @desc "附议数"
    field(:endorsement_count, non_null(:integer))
    @desc "作者处于信用降级（wishes_review_required_at 置位）"
    field(:author_credit_reduced, non_null(:boolean))
  end

  @desc "出力类型计数（admin 附议聚合）"
  object :flashback_admin_contribution_count do
    field(:type, non_null(:string))
    field(:count, non_null(:integer))
  end

  @desc "附议明细（#817 admin）：留言与联系方式仅 admin 面，公开响应禁出（KTD5）"
  object :flashback_admin_wish_endorsement_detail do
    field(:id, non_null(:id))
    @desc "出力类型（venue/organize/speak/sponsor/other）"
    field(:contribution_types, non_null(list_of(non_null(:string))))
    @desc "给平台的留言（≤500 字）"
    field(:message, :string)
    field(:inserted_at, non_null(:datetime))
    @desc "附议者登录账号手机号（仅 platform admin；token 存量附议为 null）"
    field(:endorser_phone, :string)
    @desc "附议者登录账号邮箱（仅 platform admin；token 存量附议为 null）"
    field(:endorser_email, :string)
  end

  @desc "附议聚合行（#817 admin）：按愿望分组"
  object :flashback_admin_wish_endorsement_entry do
    field(:wish_id, non_null(:id))
    field(:content, non_null(:string))
    field(:signature, :string)
    field(:city, :string)
    field(:listed_at, :datetime)
    field(:endorsement_count, non_null(:integer))

    field(
      :contribution_distribution,
      non_null(list_of(non_null(:flashback_admin_contribution_count)))
    )

    field(:endorsements, non_null(list_of(non_null(:flashback_admin_wish_endorsement_detail))))
  end

  object :flashback_wish_comment do
    field(:id, non_null(:id))
    field(:content, non_null(:string))
    @desc "留言人遮罩姓"
    field(:commenter_masked, :string)
    field(:inserted_at, non_null(:datetime))
  end

  object :flashback_my_wishes do
    field(:quota_remaining, non_null(:integer))
    field(:wishes, non_null(list_of(non_null(:flashback_owned_wish))))
  end

  object :flashback_owned_wish do
    field(:id, non_null(:id))
    field(:content, non_null(:string))
    field(:city, :string)
    field(:signature, non_null(:string))
    field(:visibility, non_null(:string))
    field(:status, non_null(:string))
    field(:inserted_at, non_null(:datetime))
  end

  object :flashback_wish_result do
    @desc "新建愿望 id（本人查看/撤回入口用）"
    field(:id, :id)
    @desc "附议后实时计数与本人态"
    field(:endorsement_count, non_null(:integer))
    field(:endorsed_by_me, non_null(:boolean))
    @desc "wish2 U8 三态反馈：listed（挂上许愿树）/ pending_review（信用待审——审核通过后挂树）/ private（说给主办方听）"
    field(:status, non_null(:string))
  end
end
