export type ContentKind = 'event' | 'course'
/** 公开派生报名标签（后端 EnrollmentBadge 单源，R6/KTD1） */
export type EnrollmentBadge = 'enrolling' | 'starting_soon' | 'closed' | 'full'
export type EnrollmentStatus =
  | 'pending'
  | 'payment_pending'
  | 'confirmed'
  | 'rejected'
  | 'expired'
  | 'cancelled'
export type OrderStatus =
  | 'pending'
  | 'paid'
  | 'refunding'
  | 'refunded'
  | 'refund_failed'
  | 'cancelled'
  | 'expired'
  /** 押金终态：未到场且未核销，押金不退（no-show 结算落此态，平台首个不退终态） */
  | 'forfeited'
/** 订单口径（后端 Order.order_kind）：押金单 / 一般报名单（含定价档位） */
export type OrderKind = 'enrollment' | 'deposit'
/** 缴费槽三态（后端 Offering.payment_mode/1 单源，押金优先；三态互斥） */
export type PaymentMode = 'free' | 'pricing' | 'deposit'
/** 公开页押金明细（#627）：金额缺失/非正 → amountCents 为 null，enabled 仍 true（#586） */
export interface PublicDeposit {
  enabled: boolean
  amountCents: number | null
  refundableOnCheckIn: boolean | null
}
/**
 * 订阅消息场景键（= 后端 `template_key`）。
 *
 * 键集与 `config/index.ts` 的 `WECHAT_SCENARIOS`、`domain/subscription.ts` 的
 * `ALL_SCENARIOS` 三者双射，由 `tests/subscription-build.test.mjs` 钉住。
 * 新增场景须同时改这三处 + `miniprogram/.env*.example` 的键（守卫测试会红）。
 *
 * 覆盖缺口见 `domain/subscription.ts` 的 moduledoc：分享者腿（`speaker_completed`
 * 的分享者受众）在小程序内**无入口**。
 */
export type SubscriptionScenario =
  | 'approval_result'
  | 'approval_reminder'
  | 'event_reminder'
  | 'enrollment_completed'
  | 'enrollment_check_in_code'
  | 'event_qualification_confirmed'
  | 'event_qualification_underfilled'
  | 'event_qualification_manager'
  | 'event_schedule_changed'
  | 'event_moderator_assigned'
  | 'event_moderator_removed'
  | 'speaker_accepted'
  | 'speaker_completed'
  | 'learning_stagnation'
  | 'payment_succeeded'
  | 'payment_expired'
  | 'refund_succeeded'
  | 'refund_failed'
  | 'enrollment_submitted'
  | 'payment_received'
  // 志愿者段位通知六键（R14/R21，U4 后端已落地 templates；键名与后端
  // template_key 逐字一致）
  | 'volunteer_application_submitted'
  | 'volunteer_application_interview'
  | 'volunteer_application_training'
  | 'volunteer_application_assigned'
  | 'volunteer_application_rejected'
  | 'volunteer_application_canceled'
  | 'flashback_wish_echo'

export interface CatalogItem {
  id: string
  kind: ContentKind
  title: string
  status: string
  qualificationBadge: QualificationBadge | null
  shortBy: number | null
  enrollmentPolicy: 'open' | 'request' | 'invite_only'
  registrationDeadline: string | null
  /** 是否收费（默认免费；收费报名须选档并完成支付，R4 免费路径零变化） */
  pricingEnabled: boolean
  /** 可售价格档位（后端已过滤过期档，R2；空数组 = 无可售档） */
  priceTiers: PriceTier[]
  /**
   * 是否收取押金（R1 三态互斥：与 pricingEnabled 不可同真）。仅详情查询携带
   * （匿名列表白名单与 web PUBLIC_LIST_* 同源，不含押金字段）——列表记录恒 false。
   */
  depositEnabled: boolean
  /** 押金金额（分，R2 单源）；非押金场恒 null */
  depositAmountCents: number | null
  /**
   * 报名最低年龄（#510；仅 event 有槽，course 恒 null = 无门槛）。非空时报名
   * 须勾选年龄确认（后端 action 权威门控，本端只是引导）。
   */
  minAge: number | null
  /** 开始时间（ISO8601）；null = 未定（R3，展示层兜底「时间待定」） */
  startsAt: string | null
  /** 结束时间（ISO8601）；null = 未定（R3） */
  endsAt: string | null
  /**
   * 活动介绍（公开展示文案）。仅详情查询携带（列表查询不选）——列表记录恒 null；
   * 详情页按 toParagraphs 分段渲染，null/空串不渲染介绍块。
   */
  description: string | null
  /** 结构化场地 JsonString（parse 后 {country,province,city,district}）；仅 event 有位置槽，course 恒 null（R3） */
  venue: string | null
  /**
   * 挂载的 Initiative id（仅 event 有槽；公开字段白名单内）。详情页据此渲染
   * 「所属倡导活动」回链；列表查询不带该字段 → 恒 null。
   */
  initiativeId: string | null
  /**
   * 公开主理人投影（#538；[JsonString!]，每行 parse 后 {display_name,
   * member_number}，assignedAt 升序）。仅 event 详情查询携带；列表/课程恒
   * null。回退链 displayName → memberNumber 见 format.ts 的 moderatorNames。
   */
  publicModerators: string[] | null
  /** 公开派生报名标签（KTD1；公开面只暴露派生标签，不暴露原始名额计数） */
  enrollmentBadge: EnrollmentBadge
  /**
   * 当前登录用户在本条目上的活跃报名（#355 P1-3；pending/payment_pending/
   * confirmed，后端仅返回活跃集——在场即「已报名」）。匿名/未报名 → null。
   */
  myEnrollment: MyEnrollmentState | null
}

export type QualificationBadge = 'cancelled' | 'closed' | 'confirmed' | 'short_by' | 'open'

export interface PublicInitiativeCard {
  id: string
  name: string
  slug: string
  hashtag: string | null
  status: 'open' | 'closed'
  /** 活动简介（列表卡片展示，与 web initiative-index 卡片同字段） */
  description: string | null
  /** 倡导窗口起止（ISO8601，可为 null）；列表卡片与详情 hero 共用 */
  windowStartsAt: string | null
  windowEndsAt: string | null
}

export interface PublicInitiativeEvent {
  id: string
  slug: string
  title: string
  status: 'open' | 'closed' | 'cancelled'
  startsAt: string | null
  endsAt: string | null
  /** 报名截止（ISO8601，可为 null；与 web initiative 场次卡同字段） */
  registrationDeadline: string | null
  /** 结构化场地 JsonString（同 Event.venue 口径，R3 兜底「地点待定」） */
  venue: string | null
  archived: boolean
  qualificationBadge: QualificationBadge
  shortBy: number | null
  /** 参与条件（#627）：缴费槽**单槽三态**，不与成班进度混算 */
  paymentMode: PaymentMode
  deposit: PublicDeposit
  /** 年龄门槛存在性（nil/null = 无门槛）；不投校验策略 */
  minAge: number | null
  /** 收费态金额锚（可售档位最小值，分）；无金额锚 → null（不臆造金额） */
  priceRangeMinCents: number | null
}

export interface PublicInitiative extends PublicInitiativeCard {
  description: string | null
  windowStartsAt: string | null
  windowEndsAt: string | null
  cityCount: number
  eventCount: number
  confirmedCount: number
  qualifiedEventCount: number
  cities: { city: string; events: PublicInitiativeEvent[] }[]
}

/** 详情页「已报名」态的本人活跃报名投影（myEnrollment 查询子集） */
export interface MyEnrollmentState {
  id: string
  status: EnrollmentStatus
  approvalDeadline: string | null
}

/** 价格档位（display 层消费形状；解析见 domain/payment.parsePriceTiers） */
export interface PriceTier {
  id: string
  name: string
  /** 脏值 → null：档位保留，渲染层降级「金额待定」+ 禁选（#687） */
  amountCents: number | null
}

export interface UserSummary {
  id: string
  displayName: string
  email: string | null
  memberNumber: string | null
}

export interface WorkspaceSummary {
  id: string
  slug: string
  name: string
  roleNames: string[]
  abilities: string[]
  memberCount: number | null
}

export interface ApprovalSummary {
  id: string
  kind: string
  workspaceId: string
  workspaceName: string
  targetId: string | null
  /** 申请人摘要（后端 enrich：display_name || email；sponsorship 行 = 公司名） */
  requesterName: string
  /** 审批对象标题（enrollment = 活动/课程名；join_request/sponsorship = 工作台名） */
  contextTitle: string | null
  /** 价格档位名（仅 sponsorship 行携带；enrollment 行为 null） */
  tierName: string | null
  /** 金额，单位元（仅 sponsorship 行携带意向金额；enrollment 行为 null） */
  amount: number | null
  status: string
  approvalDeadline: string | null
}

export interface SessionSnapshot {
  user: UserSummary | null
  workspaces: WorkspaceSummary[]
  approvals: ApprovalSummary[]
  /**
   * 掉线标记：曾有 token 但会话查询失败被降级（auth 错误或服务端错误清 token）。
   * UI 据此区分「未登录」与「登录已失效」。网络瞬态失败（token 保留）为 false。
   */
  authExpired: boolean
}

export interface EnrollmentSummary {
  id: string
  workspaceId: string
  targetId: string
  kind: ContentKind
  title: string
  status: EnrollmentStatus
  approvalDeadline: string | null
  rejectionReason: string | null
  /** #411 同活动折叠的分组/排序键（服务端 create_timestamp，ISO 时间串） */
  insertedAt: string
  /**
   * 6 位核销码（KTD5：仅本人 confirmed 报名由后端返回，其余为 null；course 恒 null）
   * ——「我的报名」confirmed 卡出示用。
   */
  checkInCode: string | null
  /** 目标缴费模式（后端 Enrollment.paymentMode 计算字段）：押金场取消文案与规则行据此分叉 */
  paymentMode: PaymentMode | null
  /**
   * 押金快照金额（分；后端 Enrollment.depositAmountCents 计算字段，源 = 报名提交
   * 时物化的 submission_payload 键，与下单实付金额同源）。order-pay 的**创单前**
   * 披露用它表态；脏值/无键 → null（文案走「押金（金额待定）」，绝不 ¥0）。
   * 创单后一律切到订单快照 `order.amountCents`（权威，见 order-pay 页）。
   */
  depositAmountCents: number | null
  /**
   * #617 目标开始时间（后端 Enrollment.startsAt 计算字段，ISO8601；null = 时间待定）。
   * 改期（event_schedule_changed）与开课提醒（event_reminder）都以本页为落页，
   * 二者通知正文里的「新时间」在本卡对应这一行——通知的权威落点。
   */
  startsAt: string | null
  /**
   * #617 目标场地（后端 Enrollment.venue 计算字段）。**已文本化**为
   * `city+district`（Events.Venue.text/1，如「杭州市西湖区」；课程/无场地 = null），
   * 与 event_reminder 模板 thing4 同源——不是 CatalogItem.venue 那种 JsonString。
   */
  venue: string | null
  /** 报名截止时间（ISO8601；null = 无截止，自助取消恒在截止前） */
  registrationDeadline: string | null
}

export interface EnrollmentForm {
  target: CatalogItem
  // 对齐 web 端一键报名:身份=登录用户(user_id),不再收集姓名/邮箱/理由
  // (web 无此表单;submission_payload 键无任何读者——三端确认孤岛)。
  inviteCode?: string
  /** 收费目标必选档（R5：报名选档 → 占位 → payment_pending） */
  tierId?: string
  /** 年龄门槛确认（#510：minAge 非空的目标必传 true） */
  ageConfirmed?: boolean
}

// ── 志愿者招募（R20/R21；U5 招募域 GraphQL 面的小程序侧形状）────────────────
//
// 三资源的读面投影：批次（匿名可读 open，但小程序侧解析 workspace 需登录——见
// domain/recruitment.ts 的 moduledoc）、简历档案（仅本人，不含文件内容）、申请
// （仅本人）。字段与 operations.ts 的 selection 一一对应，判据/文案在
// domain/recruitment.ts。

/** 招募职位（后端未建表，字符串枚举；与 CreateVolunteerApplicationInput.position 同集） */
export type VolunteerPosition = 'event_moderator' | 'tutor' | 'coach'

/** 申请段位（R12 状态图：submitted → interview → training → assigned，任一审核段可转 rejected；canceled 由 2046 管理员操作） */
export type VolunteerStatus =
  | 'submitted'
  | 'interview'
  | 'training'
  | 'assigned'
  | 'rejected'
  | 'canceled'

/** 批次状态（仅 open 对申请侧可见；draft/closed 只在管理面） */
export type RecruitmentCohortStatus = 'draft' | 'open' | 'closed'

export interface RecruitmentCohort {
  id: string
  name: string
  /** 申请截止（ISO8601，展示走既有 formatDateTime） */
  applyDeadlineAt: string
  startsAt: string | null
  endsAt: string | null
  status: RecruitmentCohortStatus
}

export interface ResumeProfileSummary {
  id: string
  fullName: string
  /** 联系邮箱 = R14 邮件保底通道收件地址（手机号建号用户必须自己填） */
  contactEmail: string
  weeklyHours: number | null
  skills: string[]
  /** 简历文件元数据（U2 上传管道写入；未上传 → null）。文件内容不出 GraphQL 面。 */
  fileName: string | null
  fileContentType: string | null
  fileSize: number | null
  uploadedAt: string | null
}

export interface VolunteerApplicationSummary {
  id: string
  cohortId: string
  position: VolunteerPosition
  city: string | null
  heardAboutUs: string | null
  hasInternalReferrer: boolean
  message: string | null
  status: VolunteerStatus
  rejectionReason: string | null
  assignedEventId: string | null
  assignmentNote: string | null
  assignedAt: string | null
}

/** 第 2 步申请项（user_id 由后端按 actor 强制填充，不接受客户端传入） */
export interface VolunteerApplicationForm {
  cohortId: string
  position: VolunteerPosition
  city?: string
  heardAboutUs?: string
  hasInternalReferrer?: boolean
  message?: string
}

/** 第 1 步档案（姓名/联系邮箱必填；一人一档，二次 upsert 更新同一行） */
export interface ResumeProfileForm {
  fullName: string
  contactEmail: string
  weeklyHours?: number
  skills?: string[]
}

/** 简历文件上传入参（KTD3：base64-over-JSON，U2 单入口；本地文件元数据不参与请求） */
export interface ResumeFileInput {
  fileName: string
  /** 声明 MIME（须与扩展名同族；由 domain/recruitment.resumeContentTypeFor 派生） */
  contentType: string
  contentBase64: string
}

/** 文件选择结果（wx.chooseMessageFile 的本地临时文件，尚未上传） */
export interface ResumeFileSelection {
  name: string
  path: string
  size: number
  /** 按扩展名派生的同族 MIME；扩展名不受支持 → null（resumeFileError 已拦） */
  contentType: string
}

export interface NotificationItem {
  id: string
  title: string
  body: string
  createdAt: string
  read: boolean
}

export interface MiniProgramCode {
  invitationId: string
  platform: string
  scene: string
  codeBase64: string
  expiresAt: string
}

export interface AdmitResult {
  workspaceId: string
  workspaceName: string
}

/** 核销方式（scan = 主理人扫码；manual = 扫码失败手输 6 位码兜底，KTD5） */
export type CheckInMethod = 'scan' | 'manual'

/**
 * 主理人核销结果（#508-A）：业务失败不抛错而是进联合——「已核销」是幂等提示态
 * 而非错误（重复扫码是现场常态），页面按 kind 分叉呈现。
 * network 类故障仍按 reject 上抛（页面给可重试反馈）。
 */
export type CheckInOutcome =
  | { kind: 'success'; checkedInAt: string | null; depositRefund: string | null }
  | { kind: 'already' }
  | { kind: 'invalid' }
  | { kind: 'forfeited' }
  | { kind: 'forbidden' }
  | { kind: 'rate_limited' }


export interface PlatformPhonePayload {
  loginCode?: string
  code?: string
  encryptedData?: string
  iv?: string
}

// ── 闪念间「我的」（U9/R28：回访正门 = 登录账号绑定档案） ──────────────

/** 雾面区间（KTD4：start/len 落在原文坐标上；reason 导入期标记为 owner 由本人调整） */
export interface FlashbackFogSpan {
  start: number
  len: number
  reason?: string | null
}

/** 本人当年答案（KTD4：本人视图原文永远完整；text 为雾化版） */
export interface FlashbackMeAnswer {
  id: string
  questionKey: string
  rawText: string
  fogSpans: FlashbackFogSpan[]
  text: string
}

export interface FlashbackMyToday {
  nowStatus: string | null
  want: string | null
  need: string | null
  say: string | null
  /** today 句级雾区间(field → spans),本人管理面专用 */
  fogSpans: Record<string, Array<{ start: number; len: number }>> | null
  sentToWallAt: string | null
}

export interface FlashbackMyCard {
  id: string
  fullName: string
  surname: string | null
  city: string | null
  occupationThen: string | null
  participation: 'attended' | 'not_selected'
  appliedAt: string | null
  quote: string | null
  /** 金句授权档原始值（R31：off/anonymous/credited；非法值由 parseQuoteLevel 落 off） */
  quoteLevel: string
  /** 句子白名单区间（多选；首句 = 消费面展示句，圈选器回显全量） */
  quoteSpans: { questionKey: string; start: number; len: number }[] | null
  /** 本人金句点赞数（R36；未授权档为 null） */
  quoteStats: { likeCount: number } | null
  today: FlashbackMyToday | null
  answers: FlashbackMeAnswer[]
  /**
   * 卡片公开开关（#771）。**TS 侧可选**只为兼容旧 fixture/旧后端快照；真实
   * payload 恒带本字段（后端非空）。缺省 = 「未知」，页面须按**关**处理
   * （判据 `me.cardSharing?.enabled === true`，fail-closed：非 true 一律按关）。
   */
  cardSharing?: FlashbackCardSharing
}

/** 名册答案段（对外版）：fog=true 时 text 恒空（原文字符不出 DOM，KTD4） */
export interface FlashbackRosterSegment {
  text: string
  fog: boolean
  len: number
}

export interface FlashbackRosterAnswer {
  questionKey: string
  segments: FlashbackRosterSegment[]
}

// ── 卡片站外公开（#771/R14：分享给朋友 → 朋友点开看到「我的卡」） ──────

/**
 * 对外分享卡（#771）：朋友视角的**雾面版**卡面。与本人卡（FlashbackMyCard）
 * 是两条投影——这里只有白名单字段，姓名走 `surname_masked` 口径，
 * 当年答案只出 self_intro/funny_thing/os 三题（PII 行 phone/email/social_media
 * 不进），today 四问全出。
 *
 * 段结构复用名册口径（FlashbackRosterSegment）：fog=true 时 `text` 恒空字符串
 * ——原文字符不进 DOM，渲染层画**定宽**雾块（不按 `len` 定宽：句长本身也是
 * 信息，不该从雾块宽度泄出去）。**这是唯一不可原谅的错误防线**：
 * 本类型的入参形状里根本没有原文（后端投影只出段结构），映射层
 * （api/real.mapSharedCard）无从回退到本人卡原文，页面也不得自行补字。
 */
export interface FlashbackSharedCard {
  /** 隐名（后端 surname_masked 口径：王**）——不是本人卡的全名 */
  displayName: string
  city: string | null
  /** 报名时间戳（ISO8601，精确到秒）——落款用：她写下这张卡的那一刻 */
  appliedAt: string | null
  /** 活动举办日（ISO8601 日期，如 2014-01-11）——头部场景定位：记忆真正发生的那天 */
  occurredOn: string | null
  /** 当年答案白名单（self_intro/funny_thing/os） */
  answers: FlashbackRosterAnswer[]
  /** 今天的你（questionKey = today.now/want/need/say；无内容时空数组） */
  today: FlashbackRosterAnswer[]
}

/**
 * 卡片公开开关状态（capsule.me.cardSharing / flashbackSetCardSharing 返回值）。
 *
 * 与金句授权档（quoteLevel）**互相独立**：开实名档不会连带公开回忆（#771 设计
 * 要点 3）。`shareId` 首次开启时生成、此后**永不变更**——关闭只清公开态，
 * 不改 id（ADR-0014：发布即锁死，无 rename 后门），重新开启复用同一 id。
 */
export interface FlashbackCardSharing {
  enabled: boolean
  /** null 仅在「从未开启过」时出现；开过之后关闭也保留 */
  shareId: string | null
  /** 本人视角的卡面预览（与公开读面同形，同一份段结构） */
  preview: FlashbackSharedCard
}

/** 场次名册成员（R12 分层墙）：未寄出者只有结构化字段，寄出者才有全名与内容 */
export interface FlashbackRosterEntry {
  id: string
  surnameMasked: string
  fullName: string | null
  appliedAt: string | null
  city: string | null
  occupationThen: string | null
  sentToWallAt: string | null
  today: { nowStatus: string | null; want: string | null; say: string | null } | null
  answers: FlashbackRosterAnswer[]
}

/** 城市堆（#933 服务端聚合）：按人的城市计数（含未寄出者的聚合数）+ 已回来数 */
export interface FlashbackArchivePile {
  city: string
  count: number
  returned: number
}

export interface FlashbackCapsuleArchive {
  key: string
  name: string | null
  city: string | null
  occurredOn: string | null
  appliedCount: number | null
  attendedCount: number | null
  /** 长廊场次格叙事短标签（原型 D ia-frame-label）：「六城同日」写故事不写地名 */
  label: string | null
  isMine: boolean
  piles: FlashbackArchivePile[]
  roster: FlashbackRosterEntry[]
}

export interface FlashbackWishComment {
  id: string
  content: string
  commenterMasked: string | null
  insertedAt: string
}

export interface FlashbackWish {
  id: string
  content: string
  city: string | null
  wisherMasked: string | null
  endorsementCount: number
  endorsedByMe: boolean
  /** 本人许愿（删除入口只对本人显示，R14） */
  mine: boolean
  comments: FlashbackWishComment[]
  /** 最新一条可见回响（#834；无则 null） */
  latestEcho: FlashbackPublicWishEcho | null
  /** 可见回响条数（#834） */
  echoCount: number
  /** 全部可见回响，按首次发布时间正序（#834） */
  echoes: FlashbackPublicWishEcho[]
  insertedAt: string
}

/** #834 回响（非 admin 公开读面，与 Web 同形） */
export interface FlashbackPublicWishEcho {
  id: string
  content: string
  /** published（首次发布）或 corrected（更正过）；draft/revoked 不出现在公开读面 */
  status: 'published' | 'corrected'
  publishedAt: string
  correctedAt: string | null
}

export interface FlashbackFutureEvent {
  id: string
  slug: string
  title: string
  city: string | null
  startsAt: string | null
  capacity: number | null
  confirmedCount: number
  registrationDeadline: string | null
}

export interface FlashbackFutureFrame {
  initiativeSlug: string
  initiativeName: string
  /** 未显影帧时间(initiative 窗口开始;null=窗口未定) */
  initiativeStartsAt: string | null
  events: FlashbackFutureEvent[]
}

export interface FlashbackCapsule {
  me: FlashbackMyCard
  /** 未来场次帧（KTD1）：按 initiative 分组、时间升序 */
  futureEvents: FlashbackFutureFrame[]
  /** 公开愿望（附议数降序） */
  publicWishes: FlashbackWish[]
  /** 本人私有许愿（仅自己可见，折叠段） */
  myPrivateWishes: FlashbackWish[]
  /** 本人今年剩余许愿条数（R20：每年 3 条，含私有与已软删，删除不退还）；未登录/无 person 为 null */
  myWishQuotaRemaining: number | null
  /** 城市钉数据源（R34）：有名册成员的城市，去重排序；不随 city 过滤收缩 */
  cities: string[]
  /** 场次时间轴与名册（长廊/场次页数据源；city 过滤时空名册场次被服务端撤下） */
  archives: FlashbackCapsuleArchive[]
}

// ── 首程旅程（token 面；mp 版原型 F） ─────────────────────────────────

export interface FlashbackEnterArchiveRef {
  key: string
  name: string | null
  city: string | null
  occurredOn: string | null
}

export interface FlashbackEnterProfile {
  fullName: string
  surname: string | null
  city: string | null
  occupationThen: string | null
  participation: 'attended' | 'not_selected'
  role: string
  appliedAt: string | null
  archive: FlashbackEnterArchiveRef | null
  answers: { id: string; questionKey: string; rawText: string; fogSpans: FlashbackFogSpan[] }[]
}

export interface FlashbackEnterResult {
  line: 'memory' | 'dream'
  profile: FlashbackEnterProfile | null
  progress: {
    quoteLevel: string
    maskedPhone: string | null
    maskedEmail: string | null
    today: FlashbackMyToday | null
  } | null
}

/** 微信一键收好（R27）：bound=false = 库里没有匹配的未认领档案 */
export interface FlashbackClaimResult {
  bound: boolean
  boundCount: number
  maskedPhone: string | null
}

/** 公开统计层（R32）：路人态长廊数据源 */
export interface FlashbackPublicStatsArchive {
  key: string
  name: string | null
  city: string | null
  occurredOn: string | null
  appliedCount: number | null
  attendedCount: number | null
  label: string | null
}

export interface FlashbackPublicStats {
  archives: FlashbackPublicStatsArchive[]
  returnedCount: number
  sentCount: number
}

/** 附议提交结果（幂等：再点 = 改角色，firstTime=false） */
export interface FlashbackEndorseResult {
  cardId: string
  status: string
  roleClaimed: string | null
  firstTime: boolean
}

/** 订单（U12 学员面：order-pay 页 + my-enrollments 缴费态） */
export interface OrderSummary {
  id: string
  enrollmentId: string
  status: OrderStatus
  amountCents: number
  expireAt: string
  transactionId: string | null
  /**
   * 订单口径（后端 Order.order_kind 下单时快照）：'deposit' 才是押金单。
   * 资金动作门（押金同意）以此为准——活动的实时缴费配置会改，这一笔不会。
   */
  orderKind: OrderKind
}

/** createOrder 产物：订单 + JSAPI 凭据（原样透传给 mapPaymentCredential） */
export interface CreatedOrder {
  order: OrderSummary
  credential: string | null
}

export interface MiniProgramApi {
  /** #355 P2-10：keyword 非空 → 服务端 title ilike 过滤；空/缺省 → 全量公开目录 */
  getCatalog(keyword?: string): Promise<CatalogItem[]>
  getContent(kind: ContentKind, id: string): Promise<CatalogItem>
  getSession(): Promise<SessionSnapshot>
  signIn(payload: PlatformPhonePayload): Promise<SessionSnapshot>
  /** #930 回访静默登录：已绑定本平台身份 → 会话；未绑定或已主动退出 → null（退回手机号登录） */
  signInSilently(loginCode: string): Promise<SessionSnapshot | null>
  signOut(): Promise<void>
  getEnrollments(): Promise<EnrollmentSummary[]>
  /** #355 P1-4：按 id 回查单条本人报名（服务端过滤）；查无 → null */
  getEnrollment(id: string): Promise<EnrollmentSummary | null>
  cancelEnrollment(id: string): Promise<void>
  createEnrollment(form: EnrollmentForm): Promise<EnrollmentSummary>
  /**
   * U12：JSAPI 下单（provider 固定 wechat_jsapi，R13）。
   * depositConsent（#727 后端权威闸）：押金单必须 true，缺失/false 一律被拒
   * （order_deposit_consent_required）；非押金单忽略——调用方只在预检判定押金
   * 且用户已勾选时携带（同 #510 ageConfirmed 的条件携带口径）。
   */
  createOrder(enrollmentId: string, depositConsent?: boolean): Promise<CreatedOrder>
  /** U12：订单状态轮询（R14 轻量面） */
  getOrderStatus(orderId: string): Promise<OrderSummary>
  /** U12：我的订单（缴费态展示数据源） */
  getMyOrders(): Promise<OrderSummary[]>
  approvePending(approval: ApprovalSummary): Promise<void>
  rejectPending(approval: ApprovalSummary, reason?: string): Promise<void>
  grantConsent(scenario: SubscriptionScenario): Promise<number>
  generateMiniProgramCode(workspaceId: string): Promise<MiniProgramCode>
  admitMember(scene: string): Promise<AdmitResult>
  /**
   * #508-A：当前用户能否核销该活动（入口门，UX 层）。成员面探测（workspace_id
   * field_policy）+ session 角色（owner/admin）；匿名/非成员/读取失败 → false。
   * 真授权由后端 checkInEnrollment policy fail-closed 承担。
   */
  canModerateEvent(eventId: string): Promise<boolean>
  /** #508-A：主理人核销提交（扫码/手输共用）；业务失败进 CheckInOutcome 联合 */
  checkInEnrollment(eventId: string, code: string, method: CheckInMethod): Promise<CheckInOutcome>
  getNotifications(): Promise<NotificationItem[]>
  /**
   * U9/R28「我的闪念间」：登录账号绑定档案的时间胶囊投影（me + 行动板）。
   * 未绑定档案 → FlashbackNotBoundError（页面引导去 web 首程/自助找回）。
   */
  /** city（R34 城市钉）：非空时行动板按城市过滤；cities 供钉条渲染 */
  /** token：首程链接身份（KTD2）；缺省走登录会话腿 */
  getFlashbackCapsule(city?: string | null, token?: string | null): Promise<FlashbackCapsule>
  /** 首程进入（R1/R2，token 面）：分流 + 本人档案 + 进度快照 */
  flashbackEnter(token: string): Promise<FlashbackEnterResult>
  /** 显影完成打点（四率之 revealed） */
  flashbackMarkRevealed(token: string): Promise<void>
  /** 寄出上墙（R11，幂等） */
  /** #931：token 为 null 时按登录账号绑定档案 */
  flashbackSendToWall(token: string | null): Promise<void>
  /** #933 相册：已登录即可读每一场的名册（未寄出者只有姓氏遮罩） */
  getFlashbackArchives(city?: string | null): Promise<{ archives: FlashbackCapsuleArchive[]; cities: string[] }>
  /** #931 撤下（双入口） */
  flashbackRetract(token: string | null): Promise<void>
  /** #931 删除档案：先取摘要，再以 DELETE 确认 */
  flashbackDeletePreview(token: string | null): Promise<import('./flashback-retract').FlashbackDeletePreview>
  flashbackDelete(token: string | null, confirm: string): Promise<void>
  /** #932 小程序内找回·发起（同 web：命中与未命中同形返回，不泄露存在性） */
  flashbackRecover(identifier: string): Promise<void>
  /** #932 小程序内找回·验证：档案绑定到当前登录账号（不另建账号）；返回找到的张数 */
  flashbackRecoverVerifyForAccount(identifier: string, code: string): Promise<{ count: number }>
  /** 邮箱找回·贴链接：找回邮件里的链接原样上送，同邮箱的档案绑到当前登录账号；返回找到的张数 */
  flashbackRecoverClaimForAccount(link: string): Promise<{ count: number }>
  /** 微信一键收好（R27）：带 token 收该链接档案并作废链接；不带按登录手机/邮箱自动匹配 */
  flashbackClaim(token?: string | null): Promise<FlashbackClaimResult>
  /** 公开统计层（R32 路人态长廊）：场次档案 + 已回来人数 */
  getFlashbackPublicStats(): Promise<FlashbackPublicStats>
  /** wish2 U9/R8：编辑「今天的你」（会话面不重计意图率）；旅程 token 面传 token（KTD2） */
  flashbackSubmitToday(
    input: {
      nowStatus?: string | null
      want?: string | null
      need?: string | null
      say?: string | null
    },
    token?: string | null
  ): Promise<void>
  /** wish2 U9/R31：金句授权三档（off/anonymous/credited） */
  /** R35：档位与圈选区间一起提交（questionKey/span 缺省 = 不动既有区间） */
  flashbackSetQuoteLicense(
    level: 'off' | 'anonymous' | 'credited',
    chosenQuoteSpans?: { questionKey: string; start: number; len: number }[] | null
  ): Promise<void>
  /** wish2 U9/R16：句子级雾化调整（提交整份 spans，服务端校验重叠/越界）；
   *  token 可选=会话腿（跳过注册的回访者），与 today 版同规则 */
  flashbackAdjustFog(answerId: string, spans: FlashbackFogSpan[], token?: string | null): Promise<void>
  /** wish2 U10:今天的你句级雾面(field ∈ now/want/need/say;整份 spans,服务端校验重叠/越界) */
  flashbackAdjustTodayFog(field: string, spans: FlashbackFogSpan[], token?: string | null): Promise<void>
  // U4 愿望写操作(双入口 token)；wish2 U8/U10 扩参返回三态（listed/pending_review/private）
  flashbackCreateWish(
    content: string,
    visibility: 'private' | 'public',
    token?: string | null,
    options?: {
      signatureChoice?: 'anonymous' | 'display_name'
      expectedCity?: string | null
      publicListingConsent?: boolean
      requestId?: string
    }
  ): Promise<{ id: string; status: string }>
  /** wish2 U6/KTD3：附议（登录版，旧 token 匿名腿下线）；出力多选 + 留言 ≤500 +
   *  回响通知意愿（真实授权由微信 accept 上报 grant，本意愿不冒充授权） */
  flashbackEndorseWish(
    wishId: string,
    options?: { contributionTypes?: string[]; message?: string | null; notify?: boolean }
  ): Promise<number>
  /** wish2 U6/U9（KTD2）：期待/取消期待（登录强制 u: 键，匿名 a: 设备键） */
  flashbackExpectWish(wishId: string, expected: boolean, anonVoterKey?: string | null): Promise<number>
  /** wish2 U6/U9（KTD3）：取消附议（登录） */
  flashbackCancelEndorseWish(wishId: string): Promise<void>
  /** wish2 U6/U9（KTD5）：举报（预设理由 + ≤200 补充；匿名带设备键） */
  flashbackReportWish(
    wishId: string,
    reasonType: string,
    reasonFree?: string | null,
    anonVoterKey?: string | null
  ): Promise<void>
  flashbackAddWishComment(wishId: string, content: string, token?: string | null): Promise<void>
  flashbackDeleteWish(wishId: string, token?: string | null): Promise<void>
  /**
   * #771/R14：站外公开开关（本人可调，默认关）。开启时后端生成 shareId，
   * 关闭只解除公开、**不改 id**（重新开启复用同一 id）。
   * token 可选 = 首程链接身份（KTD2），与 today/雾面写面同规则。
   */
  flashbackSetCardSharing(enabled: boolean, token?: string | null): Promise<FlashbackCardSharing>
  /**
   * #771：按 shareId 读公开卡（**匿名面**，朋友无账号也可读）。
   * 关闭/不存在/已删档 → null（合法空态，不是错误）；网络/服务端故障照常抛。
   */
  getFlashbackSharedCard(shareId: string): Promise<FlashbackSharedCard | null>
  // ── 志愿者招募（R20；页面 pages/volunteer-apply，微信端专属）──────────────
  //
  // 三资源都带 workspace_id 租户（入口 workspaceId 显式 argument，KTD2）：小程序
  // 无 URL slug，入口工作台由 slug 解析（见 domain/recruitment.RECRUITMENT_WORKSPACE_SLUG），
  // 因此**本组方法都要求已登录**（getWorkspace 的策略是 actor_present）。
  /** 当前 open 招募批次（无 open → null = 空态；读取失败抛错 = 失败态，两者不同桶） */
  getCurrentRecruitmentCohort(): Promise<RecruitmentCohort | null>
  /** 本人简历档案（未建档 → null） */
  getMyResumeProfile(): Promise<ResumeProfileSummary | null>
  /** 建档 / 更新档案（一人一档；上传前必须先建档，U2 契约） */
  saveResumeProfile(form: ResumeProfileForm): Promise<ResumeProfileSummary>
  /** 上传本人简历文件（U2 单入口：扩展名/声明 MIME/魔术数三者一致 + ≤5MB） */
  uploadResumeFile(input: ResumeFileInput): Promise<ResumeProfileSummary>
  /** 本人的志愿者申请列表（跨批次，新→旧） */
  getMyVolunteerApplications(): Promise<VolunteerApplicationSummary[]>
  /** 提交申请（R11 第 2 步；同批一份，重复提交由后端 volunteer_application_already_submitted 拒绝） */
  createVolunteerApplication(form: VolunteerApplicationForm): Promise<VolunteerApplicationSummary>
}

/** 登录账号没有绑定闪念间档案（capsule 双入口的会话腿 miss）——页面按引导态渲染。 */
export class FlashbackNotBoundError extends Error {
  constructor() {
    super('flashback person not bound')
    this.name = 'FlashbackNotBoundError'
  }
}

/** 首程链接已失效（KTD2）：已注册/已删除/不存在三分支——页面按 code 渲染失效落地。 */
export type FlashbackTokenInvalidCode =
  | 'flashback_token_not_found'
  | 'flashback_token_claimed'
  | 'flashback_token_revoked'

export class FlashbackTokenInvalidError extends Error {
  readonly code: FlashbackTokenInvalidCode

  constructor(code: FlashbackTokenInvalidCode) {
    super(code)
    this.name = 'FlashbackTokenInvalidError'
    this.code = code
  }
}
