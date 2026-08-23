export type ContentKind = 'event' | 'course'
/** 公开派生报名标签（后端 EnrollmentBadge 单源，R6/KTD1） */
export type EnrollmentBadge = 'enrolling' | 'starting_soon' | 'full'
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
  workspaceName: string
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
  status: string
  approvalDeadline: string | null
}

export interface SessionSnapshot {
  user: UserSummary | null
  workspaces: WorkspaceSummary[]
  approvals: ApprovalSummary[]
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
}

export interface EnrollmentForm {
  target: CatalogItem
  name: string
  email: string
  reason: string
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
  getCatalog(): Promise<CatalogItem[]>
  getContent(kind: ContentKind, id: string): Promise<CatalogItem>
  getSession(): Promise<SessionSnapshot>
  signIn(payload: PlatformPhonePayload): Promise<SessionSnapshot>
  signOut(): Promise<void>
  getEnrollments(): Promise<EnrollmentSummary[]>
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
