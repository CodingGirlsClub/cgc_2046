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
export type SubscriptionScenario = 'approval_result' | 'approval_reminder' | 'event_reminder'

export interface CatalogItem {
  id: string
  kind: ContentKind
  title: string
  enrollmentPolicy: 'open' | 'request' | 'invite_only'
  registrationDeadline: string | null
  /** 是否收费（默认免费；收费报名须选档并完成支付，R4 免费路径零变化） */
  pricingEnabled: boolean
  /** 可售价格档位（后端已过滤过期档，R2；空数组 = 无可售档） */
  priceTiers: PriceTier[]
  /** 开始时间（ISO8601）；null = 未定（R3，展示层兜底「时间待定」） */
  startsAt: string | null
  /** 结束时间（ISO8601）；null = 未定（R3） */
  endsAt: string | null
  /** 结构化场地 JsonString（parse 后 {country,province,city,district}）；仅 event 有位置槽，course 恒 null（R3） */
  venue: string | null
  /** 公开派生报名标签（KTD1；公开面只暴露派生标签，不暴露原始名额计数） */
  enrollmentBadge: EnrollmentBadge
  /**
   * 当前登录用户在本条目上的活跃报名（#355 P1-3；pending/payment_pending/
   * confirmed，后端仅返回活跃集——在场即「已报名」）。匿名/未报名 → null。
   */
  myEnrollment: MyEnrollmentState | null
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
  getNotifications(): Promise<NotificationItem[]>
}
