import type { CatalogItem, ContentKind, EnrollmentBadge, EnrollmentStatus, EnrollmentSummary } from './models'

export function remainingLabel(deadline: string | null, now = Date.now()): string {
  if (!deadline) return '未设置截止时间'
  const remaining = new Date(deadline).getTime() - now
  if (remaining <= 0) return '已到期'
  const hours = Math.floor(remaining / 3_600_000)
  const minutes = Math.floor((remaining % 3_600_000) / 60_000)
  return `${hours} 小时 ${minutes} 分钟`
}

export function isUrgent(deadline: string | null, now = Date.now()): boolean {
  if (!deadline) return false
  const remaining = new Date(deadline).getTime() - now
  return remaining > 0 && remaining <= 24 * 3_600_000
}

export function canManageMembers(abilities: string[]): boolean {
  return abilities.includes('manage_members')
}

export function parseEnrollmentPolicy(value: string): CatalogItem['enrollmentPolicy'] {
  if (value === 'open' || value === 'request' || value === 'invite_only') return value
  throw new Error(`服务端返回未知报名策略：${value}`)
}

export function parseEnrollmentStatus(value: string): EnrollmentStatus {
  if (value === 'pending' || value === 'payment_pending' || value === 'confirmed' || value === 'rejected' || value === 'expired' || value === 'cancelled') return value
  throw new Error(`服务端返回未知报名状态：${value}`)
}

export function parseEnrollmentBadge(value: string | null): EnrollmentBadge {
  if (value === 'enrolling' || value === 'starting_soon' || value === 'closed' || value === 'full') return value
  throw new Error(`服务端返回未知报名标签：${value}`)
}

/** 缴费模式（后端 Enrollment.paymentMode 计算字段；null = 读面不可得，展示层按免费态兜底） */
export function parsePaymentMode(value: string | null): EnrollmentSummary['paymentMode'] {
  if (value === null) return null
  if (value === 'free' || value === 'pricing' || value === 'deposit') return value
  throw new Error(`服务端返回未知缴费模式：${value}`)
}

/** 报名状态展示文案（my-enrollments 卡片与详情页「已报名」态共用单源） */
export const enrollmentStatusText: Record<EnrollmentStatus, string> = {
  pending: '等待审批',
  payment_pending: '待支付',
  confirmed: '已通过',
  rejected: '已拒绝',
  expired: '审批超时',
  cancelled: '已取消'
}

/** badge 展示文案（KTD1；公开面以派生标签替代原始名额计数） */
export const enrollmentBadgeText: Record<EnrollmentBadge, string> = {
  enrolling: '报名中',
  starting_soon: '即将开始',
  closed: '报名截止',
  full: '已满'
}

/**
 * 报名阻断提示（双门：条目状态优先，报名 badge 兜底）；null = 可报名。
 *
 * - `status !== 'open'`（cancelled/closed/draft）一律阻断 —— 公开留档读
 *   （initiative 挂载的 closed/cancelled 匿名可读）会把归档场送到详情页与
 *   register-form，而 badge 只看 capacity/截止，曾在此漏出报名表单（#574）；
 *   closed 按 endsAt 区分「活动已结束」与「报名已截止」。
 * - open 时沿用 badge 文案（与 web 端 closedHint/fullHint 逐字一致）。
 *
 * 详情页 CTA 与 register-form 表单页共用本函数（表单页此前只有 badge 门）。
 */
export function enrollmentBlockedNotice(
  item: Pick<CatalogItem, 'status' | 'endsAt' | 'enrollmentBadge'>
): string | null {
  if (item.status !== 'open') {
    if (item.status === 'cancelled') return '活动已取消，仅供查看。'
    if (item.endsAt && Date.parse(item.endsAt) <= Date.now()) return '活动已结束，仅供查看。'
    return '报名已截止，仅供查看。'
  }
  if (item.enrollmentBadge === 'closed') return '报名已截止，不再接受新的报名。'
  if (item.enrollmentBadge === 'full') return '名额已满，不再接受新的报名。'
  return null
}

/**
 * 详情页「报名状态」槽文案：open 用报名 badge；非 open 显示条目状态词——
 * 归档场不再并列显示「报名中 + 已取消」（#574）。
 */
export function enrollmentMetricText(item: Pick<CatalogItem, 'status' | 'enrollmentBadge'>): string {
  if (item.status === 'open') return enrollmentBadgeText[item.enrollmentBadge]
  if (item.status === 'cancelled') return '已取消'
  if (item.status === 'closed') return '已结束'
  return '草稿'
}

// 与详情页既有截止日期同款 toLocaleString 惯例（R15 随行展示不引新格式）
export function formatDateTime(iso: string): string {
  return new Date(iso).toLocaleString()
}

/**
 * 报名卡核销码出示文本（R11/KTD5）：仅 confirmed 报名且后端返回码时出示
 * （后端按「本人 confirmed 报名」门控，course 恒 null）；其余 → null。
 * 文本承载 6 位码本身——主理人现场手输/扫码用。
 */
export function checkInCodeText(status: EnrollmentStatus, checkInCode: string | null): string | null {
  if (status !== 'confirmed' || !checkInCode) return null
  return `核销码 ${checkInCode}`
}

/** 时间行展示（R3）：双全为区间，单值带方向，全空兜底「时间待定」 */
export function scheduleText(startsAt: string | null, endsAt: string | null): string {
  if (startsAt && endsAt) return `${formatDateTime(startsAt)} - ${formatDateTime(endsAt)}`
  if (startsAt) return `${formatDateTime(startsAt)} 开始`
  if (endsAt) return `${formatDateTime(endsAt)} 结束`
  return '时间待定'
}

/**
 * venue JsonString → 展示文本（KTD5/R3）。解析遵循严格四键形状（与 backend
 * Venue.valid?/1 同构）：对象恰有 country/province/city/district 四键且值均为
 * string 才算解析成功；缺键/多键/非字符串值/JSON.parse 失败/输入非 string
 * 一律 null（展示层兜底「地点待定」，同 web parseVenue 解析失败按 nil 的
 * 容错纪律：展示层不假定结构，不报错不出空白）。四键全空串同样 null。
 */
function parseVenue(raw: string | null): { country: string; province: string; city: string; district: string } | null {
  if (typeof raw !== 'string') return null
  try {
    const parsed: unknown = JSON.parse(raw)
    if (typeof parsed !== 'object' || parsed === null || Array.isArray(parsed)) return null
    const venue = parsed as Record<string, unknown>
    if (Object.keys(venue).length !== 4) return null
    if (
      typeof venue.country !== 'string' ||
      typeof venue.province !== 'string' ||
      typeof venue.city !== 'string' ||
      typeof venue.district !== 'string'
    ) {
      return null
    }
    return { country: venue.country, province: venue.province, city: venue.city, district: venue.district }
  } catch {
    return null
  }
}

/** venue → 单行展示（空段跳过；解析失败/全空 → null，展示层兜底「地点待定」，R3） */
export function venueText(raw: string | null): string | null {
  const venue = parseVenue(raw)
  if (!venue) return null
  const parts = [venue.country, venue.province, venue.city, venue.district].filter((s) => s.trim() !== '')
  return parts.length > 0 ? parts.join(' ') : null
}

/**
 * 公开主理人投影（#538）→ 展示名列表：逐行 parse `[JsonString!]`（每行
 * {display_name, member_number}），脏行丢弃。回退链与 #537 管理面、web
 * `moderatorNames` 同语义：displayName → memberNumber（后端恒非空；
 * displayName 为 null 是「用户没填名字」的固有成本，不做特殊兜底）。
 * 空/解析全失败 → []（展示层「无主理人不渲染」）。
 */
export function moderatorNames(raw: readonly string[] | null | undefined): string[] {
  if (!raw) return []
  return raw.flatMap((item): string[] => {
    try {
      const v: unknown = JSON.parse(item)
      if (typeof v !== 'object' || v === null) return []
      const r = v as Record<string, unknown>
      if (typeof r.display_name === 'string' && r.display_name !== '') return [r.display_name]
      if (typeof r.member_number === 'string' && r.member_number !== '') return [r.member_number]
      return []
    } catch {
      return []
    }
  })
}

// ── #617 「我的报名」读面时间/地点行 ──
//
// 改期（event_schedule_changed）与开课提醒（event_reminder）的通知落页都是
// 「我的报名」，两条模板正文里都带 starts_at 与 venue，故本页必须有权威落点。
//
// **venue 形态（勿与 CatalogItem.venue 混淆）**：后端 `Enrollment.venue`
// （admission/enrollment.ex 计算字段）取的是 `Offering.fetch_schedule_by_ids`
// 的结果，而后者对 Event 走 `Events.Venue.text/1` **文本化为 city+district**
// （无 venue 的 Course → nil）。同一文本也是 event_reminder 模板 thing4 的值
// （event_reminder_worker.ex `Venue.text(venue) || ""`），故三处同形。
// 与之相对，`CatalogItem.venue` 是 Event 的 **JsonString**，走 `venueText`
// 严格四键解析——两套形态各有各的解析器，不要互相套用。

/**
 * `Venue.text/1` 的端内等价（仅 mock/e2e 与测试需要）：
 * 取 city + district 直接拼接（nil 段跳过，空串结果 → null）。
 *
 * 真机路径不调用本函数——`Enrollment.venue` 由后端算好文本下发；
 * 本函数只为让 mockTransport 的 create 回包与真机同形（否则 e2e 会拿
 * JsonString 冒充文本，测试掩盖真机不渲染）。
 */
export function venueCityDistrictText(raw: string | null): string | null {
  if (typeof raw !== 'string') return null
  try {
    const parsed: unknown = JSON.parse(raw)
    if (typeof parsed !== 'object' || parsed === null || Array.isArray(parsed)) return null
    const venue = parsed as Record<string, unknown>
    const parts = [venue.city, venue.district].filter((part): part is string => typeof part === 'string')
    const text = parts.join('')
    return text === '' ? null : text
  } catch {
    return null
  }
}

/**
 * 「我的报名」卡片时间行（#617）：event → 「活动时间」、course → 「开课时间」。
 *
 * 格式单源 = 既有 `formatDateTime`（详情页同款 toLocaleString 惯例），不引第二种
 * 时间格式；`startsAt` 为 null（时间待定）→ 返回 null，调用方不渲染空行。
 * 卡面不带「开始」后缀：`startsAt` 即开始时刻，标签已含「时间」。
 */
export function enrollmentScheduleText(kind: ContentKind, startsAt: string | null): string | null {
  if (!startsAt) return null
  return `${kind === 'event' ? '活动时间' : '开课时间'}：${formatDateTime(startsAt)}`
}

/**
 * 「我的报名」卡片地点行（#617）：入参是后端已文本化的 `city+district`
 * （见上方形态说明），原样展示，**不做 JSON 解析**。
 *
 * null/非字符串/空串 → 返回 null，调用方不渲染空行（不编造「地点待定」——
 * 卡面是信息行，无值就没有这一行；课程与线上场恒 null）。
 */
export function enrollmentVenueText(venue: string | null): string | null {
  if (typeof venue !== 'string') return null
  const text = venue.trim()
  return text === '' ? null : `地点：${text}`
}

/**
 * 「我的报名」历史行时间文案（#617）：显式标注为**报名时间**而非活动时间。
 *
 * 同一 (kind, targetId) 的历史记录与主卡片同页显示：主卡片新增「活动时间」后，
 * 历史行若继续渲染裸时间串，读者会把它误当活动时间（历史行的值其实是记录创建
 * 时刻 insertedAt）。加「报名于」前缀即消除该歧义；历史行**不**显示 startsAt
 * （与主卡片同值，重复无信息量）。
 */
export function enrollmentHistoryTimeText(insertedAt: string): string {
  return `报名于 ${formatDateTime(insertedAt)}`
}
