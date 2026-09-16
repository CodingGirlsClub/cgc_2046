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
  | 'event_qualification_confirmed'
  | 'event_qualification_underfilled'
  | 'event_schedule_changed'
  | 'event_moderator_assigned'
  | 'speaker_accepted'
  | 'speaker_completed'
  | 'learning_stagnation'

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
  /** 开始时间（ISO8601）；null = 未定（R3，展示层兜底「时间待定」） */
  startsAt: string | null
  /** 结束时间（ISO8601）；null = 未定（R3） */
  endsAt: string | null
  /** 结构化场地 JsonString（parse 后 {country,province,city,district}）；仅 event 有位置槽，course 恒 null（R3） */
  venue: string | null
  /**
   * 挂载的 Initiative id（仅 event 有槽；公开字段白名单内）。详情页据此渲染
   * 「所属倡导活动」回链；列表查询不带该字段 → 恒 null。
   */
  initiativeId: string | null
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
  amountCents: number
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
  paymentMode: 'free' | 'pricing' | 'deposit' | null
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
  signOut(): Promise<void>
  getEnrollments(): Promise<EnrollmentSummary[]>
  /** #355 P1-4：按 id 回查单条本人报名（服务端过滤）；查无 → null */
  getEnrollment(id: string): Promise<EnrollmentSummary | null>
  cancelEnrollment(id: string): Promise<void>
  createEnrollment(form: EnrollmentForm): Promise<EnrollmentSummary>
  /** U12：JSAPI 下单（provider 固定 wechat_jsapi，R13） */
  createOrder(enrollmentId: string): Promise<CreatedOrder>
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
}
