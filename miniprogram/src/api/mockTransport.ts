import type { RequestDocument } from 'graphql-request'
// 相对 + 显式 .ts：mockTransport 同时被 node --experimental-strip-types 直接加载
// （tests/mock-transport.test.ts），该 runner 不认 `@/` 别名；Taro 侧同款先例
// 见 src/domain/entry.ts 的 './share-route.ts'。
import { venueCityDistrictText } from '../domain/format.ts'

const workspace = {
  id: 'workspace-1',
  slug: 'beijing-cgc',
  name: '北京 CGC',
  joinPolicy: 'request',
  myRoleNames: ['owner'],
  myMembershipId: 'membership-1',
  canAccess: true,
  myAbilities: ['view_workspace', 'manage_members'],
  memberCount: 128
}

// 公开发现面 mock 记录（F2）：字段 = 匿名白名单，与 operations.ts 查询一致
// （押金字段为例外：仅详情查询请求，样例记录带着供详情/报名链使用——列表面
// 不渲染缴费槽，多带两键不影响）。
const DEPOSIT_AMOUNT_CENTS = 6900
const CHECK_IN_CODE = '042317'

const records = [
  {
    id: 'event-1',
    title: 'Python 入门工作坊',
    status: 'open',
    enrollmentPolicy: 'request',
    registrationDeadline: new Date(Date.now() + 72 * 3_600_000).toISOString(),
    pricingEnabled: false,
    availablePriceTiers: [],
    startsAt: new Date(Date.now() + 3 * 24 * 3_600_000).toISOString(),
    endsAt: new Date(Date.now() + (3 * 24 + 2) * 3_600_000).toISOString(),
    venue: JSON.stringify({ country: '中国', province: '北京市', city: '北京', district: '海淀区' }),
    enrollmentBadge: 'starting_soon',
    // 成班投影样例（阶段1）：short_by → 详情页/Initiative 卡片都渲染「还差 3 人成班」；
    // initiativeId 让 event-detail 的「所属倡导活动」回链有落点
    qualificationBadge: 'short_by',
    shortBy: 3,
    initiativeId: 'initiative-1'
  },
  {
    id: 'event-open',
    title: '周末开源分享会',
    status: 'open',
    enrollmentPolicy: 'open',
    registrationDeadline: null,
    pricingEnabled: false,
    availablePriceTiers: [],
    // 时间/地点未定：详情页走「时间待定」「地点待定」兜底（R3）
    startsAt: null,
    endsAt: null,
    venue: null,
    enrollmentBadge: 'enrolling',
    // 无成班需求的活动 → badge=open；详情页按 web 口径隐藏该徽章（阶段1 回归面）
    qualificationBadge: 'open',
    shortBy: null,
    initiativeId: null
  },
  {
    id: 'event-deposit',
    title: '押金场 · 线下共学',
    status: 'open',
    enrollmentPolicy: 'open',
    registrationDeadline: new Date(Date.now() + 48 * 3_600_000).toISOString(),
    pricingEnabled: false,
    availablePriceTiers: [],
    // 押金场（U11 样例）：详情页缴费块「押金 ¥69.00（到场退）」+「未到场不退」，
    // 报名落 payment_pending（零档位选择，走既有 paymentLandingUrl 支付）
    depositEnabled: true,
    depositAmountCents: DEPOSIT_AMOUNT_CENTS,
    minAge: 18,
    startsAt: new Date(Date.now() + 5 * 24 * 3_600_000).toISOString(),
    endsAt: new Date(Date.now() + (5 * 24 + 2) * 3_600_000).toISOString(),
    venue: JSON.stringify({ country: '中国', province: '上海市', city: '上海', district: '徐汇区' }),
    enrollmentBadge: 'enrolling'
  }
]

const course = {
  id: 'course-1',
  title: '社区组织者成长课',
  status: 'open',
  enrollmentPolicy: 'invite_only',
  registrationDeadline: null,
  pricingEnabled: false,
  availablePriceTiers: [],
  // 课程无 venue 槽（R3）；开课时间已定、结课未定（部分空）
  startsAt: new Date(Date.now() + 30 * 24 * 3_600_000).toISOString(),
  endsAt: null,
  enrollmentBadge: 'enrolling'
}

// 阶段1：Initiative 公开投影 fixture（发现页卡片 + 详情页 + event-detail 回链）。
// id 与 event-1 的 initiativeId 对应——回链据此把场次挂回倡导活动。
const initiativeCard = {
  id: 'initiative-1',
  name: '1024 程序员节',
  slug: 'python-1024',
  hashtag: '#1024',
  description: '跨城市的开源共学周，把同一套课程带到十个城市。',
  status: 'open',
  windowStartsAt: new Date(Date.now() + 7 * 24 * 3_600_000).toISOString(),
  windowEndsAt: new Date(Date.now() + 21 * 24 * 3_600_000).toISOString()
}

// Initiative 卡片里的场次：派生徽章 + 留档（不取原始计数/成员字段，与查询同源）
const initiativeEvent = {
  id: 'event-1',
  slug: 'python-workshop',
  title: 'Python 入门工作坊',
  status: 'open',
  startsAt: records[0].startsAt,
  endsAt: records[0].endsAt,
  registrationDeadline: records[0].registrationDeadline,
  venue: records[0].venue,
  archived: false,
  qualificationBadge: 'short_by',
  shortBy: 3,
  // 参与条件（#627）：押金三态 + 年龄门槛存在性（与后端公开投影同键）
  paymentMode: 'deposit',
  deposit: { enabled: true, amountCents: 6900, refundableOnCheckIn: true },
  minAge: 18,
  priceRangeMinCents: null
}

interface MockOrder {
  id: string
  enrollmentId: string
  status: string
  amountCents: number
  expireAt: string
  transactionId: string | null
  /** 与后端 order_kind/2 同规则：押金场开则 deposit，否则 enrollment */
  orderKind: 'enrollment' | 'deposit'
}

interface MockEnrollment {
  id: string
  workspaceId: string
  eventId: string | null
  courseId: string | null
  userId: string
  status: string
  submissionPayload: string
  approvalDeadline: string | null
  rejectionReason: string | null
  approvedAt: string | null
  expiredAt: string | null
  cancelledAt: string | null
  insertedAt: string
  /** 6 位核销码（KTD5：仅 confirmed 报名由后端返回；置前导零验证字符串口径） */
  checkInCode: string | null
  /** 目标缴费模式（后端 Enrollment.paymentMode 计算字段同规则：押金 > 定价 > 免费） */
  paymentMode: string | null
  /** #617 目标开始时间（后端 Enrollment.startsAt 计算字段同规则：从目标记录取） */
  startsAt: string | null
  /** #617 目标场地：后端 Enrollment.venue 同形 = Venue.text/1 文本化 city+district */
  venue: string | null
  /** 报名截止时间（ISO8601；null = 无截止） */
  registrationDeadline: string | null
}

let loggedIn = false
let enrollment: MockEnrollment | null = null
let order: MockOrder | null = null
let orderStatusOverride: string | null = null
// #508-A：核销幂等标记（同一报名第二次核销 → already； enrollment 重置时随之复位）
let checkedIn = false

// ── 闪念间「我的」（U9）：登录即视为已绑定档案的会话腿 ──────────────────
// 与后端 flashbackCapsule 会话入口同形；四态卡各一（行动板分组的样例覆盖）。
const FLASHBACK_RAW_TEXT = '我在盛大做测试。想亲眼看看是不是真的！后来我成了程序员。'

// mock 写面落 FLASHBACK_MOCK_STATE（wx storage）：开发者工具重编译（JS 上下文
// 重建）后仍保持，模拟后端存量；e2e 脚本段 0 清该 key 保证幂等。node --test
// 直接加载本模块且无 wx storage——探测不到就回落纯模块态（单进程内行为不变）。
// 本模块不 import Taro：它被 node --experimental-strip-types 直接加载，`@/`
// 别名与 Taro 副作用在该 runner 下都不可用（同文件头部 format.ts 注释）。
const FLASHBACK_MOCK_STATE = 'cgc.e2e.flashback_mock_state'

interface FlashbackMockState {
  fogSpans: Array<{ start: number; len: number }>
  quoteLevel: 'off' | 'anonymous' | 'credited'
  /** R35 圈选结果（questionKey + 区间）：capsule 回读 + 点赞徽章共用 */
  chosenQuoteSpans: Array<{ questionKey: string; start: number; len: number }>
  /** R36 点赞数（mock 固定 3：授权档下有值，供回访面回读） */
  likeCount: number
  today: {
    nowStatus: string | null
    want: string | null
    need: string | null
    say: string | null
    sentToWallAt: string | null
  }
  /** today 句级雾面(field → spans) */
  todayFogSpans: Record<string, Array<{ start: number; len: number }>>
  endorsedCardIds: string[]
}

const FLASHBACK_INITIAL_STATE: FlashbackMockState = {
  fogSpans: [{ start: 0, len: 7 }],
  quoteLevel: 'off',
  chosenQuoteSpans: [],
  likeCount: 3,
  today: { nowStatus: null, want: null, need: null, say: null, sentToWallAt: null },
  todayFogSpans: {},
  endorsedCardIds: []
}

interface WxLikeStorage {
  getStorageSync(key: string): unknown
  setStorageSync(key: string, value: string): void
}

function wxStorage(): WxLikeStorage | null {
  const scope = globalThis as { wx?: WxLikeStorage }
  return scope.wx ?? null
}

// 持久态恢复：形状不符（旧版本/手改脏数据）整体回落初始——fail-closed，不做部分合并
function loadFlashbackState(): FlashbackMockState {
  try {
    const raw = wxStorage()?.getStorageSync(FLASHBACK_MOCK_STATE)
    if (typeof raw !== 'string' || !raw) return FLASHBACK_INITIAL_STATE
    const parsed = JSON.parse(raw) as FlashbackMockState
    const valid =
      Array.isArray(parsed.fogSpans) &&
      parsed.fogSpans.every((span) => Number.isInteger(span?.start) && Number.isInteger(span?.len)) &&
      (parsed.quoteLevel === 'off' || parsed.quoteLevel === 'anonymous' || parsed.quoteLevel === 'credited') &&
      (parsed.chosenQuoteSpans === null ||
        (Array.isArray(parsed.chosenQuoteSpans) &&
          parsed.chosenQuoteSpans.every(
            (span) =>
              typeof span?.questionKey === 'string' &&
              Number.isInteger(span?.start) &&
              Number.isInteger(span?.len),
          ))) &&
      Number.isInteger(parsed.likeCount) &&
      typeof parsed.today === 'object' &&
      parsed.today !== null &&
      Array.isArray(parsed.endorsedCardIds) &&
      parsed.endorsedCardIds.every((id) => typeof id === 'string')
    return valid ? parsed : FLASHBACK_INITIAL_STATE
  } catch {
    return FLASHBACK_INITIAL_STATE
  }
}

function saveFlashbackState(state: FlashbackMockState): void {
  try {
    wxStorage()?.setStorageSync(FLASHBACK_MOCK_STATE, JSON.stringify(state))
  } catch {
    // 无 wx storage（node --test）：仅模块态，进程内仍一致
  }
}

let flashback: FlashbackMockState = loadFlashbackState()

// ── 首程 token 面（mp 版原型 F：旅程 → 长廊 → 场次；R1/R4-R11/R27） ──
// 链接作废（claim 后）用模块态即可：e2e 在同一段内断言「收好后链接失效」。
// 三级视角开关走 wx storage（e2e 脚本经 automation_evaluate 可写，node --test
// 无 storage 读为 false = 默认行为不变）：
//   cgc.e2e.flashback_unclaimed = '1' → 登录了但库里没有匹配档案（capsule 会话腿
//     报 flashback_person_not_bound，驱动长廊自动认领分支）；
//   cgc.e2e.flashback_claim_miss = '1' → claim 不命中（bound:false，驱动
//     「找回你的那一张」会话引导）。
const FLASHBACK_UNCLAIMED_KEY = 'cgc.e2e.flashback_unclaimed'
const FLASHBACK_CLAIM_MISS_KEY = 'cgc.e2e.flashback_claim_miss'
const flashbackClaimedTokens = new Set<string>()
let flashbackUnclaimed = false

function e2eFlag(key: string): boolean {
  try {
    return wxStorage()?.getStorageSync(key) === '1'
  } catch {
    return false
  }
}

/** e2e 钩子（node --test 用）：模拟登录账号暂无匹配档案 */
export function __setFlashbackUnclaimed(value: boolean): void {
  flashbackUnclaimed = value
}

// 首程档案（2014-01-11 六城同日 · 北京）：与既有 capsule 的「我」同一个人——
// 旅程（token 面）与回访（会话面）在 e2e 里可交叉断言同一档案。
const FLASHBACK_E2E_ARCHIVE = {
  key: '2014-01-11-bj',
  name: 'Rails Girls Beijing',
  city: '北京',
  occurredOn: '2014-01-11'
}
const FLASHBACK_FUN_RAW = '我做过的有意思的事情：给机器人写了一个会讲笑话的按钮。'

// 场次名册 fixture（R12：仅 attended；未寄出者只有结构化字段，无内容层）。
// 城市分布（北京3/上海2/广州1 + 上海场3）= 长廊城市堆计数与场次页雾卡的
// e2e 断言数据源；「我」的寄出态跟随 mock state（旅程寄出后回访同源可见）。
function flashbackArchives(mySentAt: string | null) {
  const rosterEntry = (
    id: string,
    surnameMasked: string,
    fullName: string | null,
    city: string,
    occupationThen: string | null,
    sentToWallAt: string | null
  ) => ({
    id,
    surnameMasked,
    fullName,
    appliedAt: sentToWallAt ? '2014-01-11T13:06:00Z' : null,
    city,
    occupationThen,
    sentToWallAt,
    today: sentToWallAt ? { nowStatus: '还在写代码', want: null, say: null } : null,
    // 名册内容层（web 翻卡读面）mp 场次页不消费——空段即可
    answers: [] as Array<{ questionKey: string; segments: Array<{ text: string; fog: boolean; len: number }> }>
  })

  return [
    {
      ...FLASHBACK_E2E_ARCHIVE,
      appliedCount: 344,
      attendedCount: 102,
      label: '六城同日',
      isMine: true,
      roster: [
        rosterEntry('fb-person-1', '王**', '王小明', '北京', '测试工程师', mySentAt),
        rosterEntry('fb-person-2', '李**', '李一诺', '上海', '学生', '2026-09-17T02:00:00Z'),
        rosterEntry('fb-person-3', '陈**', '陈静怡', '北京', '学生', '2026-09-17T03:00:00Z'),
        rosterEntry('fb-person-4', '杨**', null, '北京', '工程师', null),
        rosterEntry('fb-person-5', '周**', null, '广州', '设计', null),
        rosterEntry('fb-person-6', '吴**', null, '上海', '学生', null)
      ]
    },
    {
      key: '2012-02-26-sh',
      name: 'Rails Girls Shanghai',
      city: '上海',
      occurredOn: '2012-02-26',
      appliedCount: 30,
      attendedCount: 12,
      label: '一切的开始',
      isMine: false,
      roster: [
        rosterEntry('fb-person-7', '郑**', '郑子涵', '上海', '学生', '2026-09-16T01:00:00Z'),
        rosterEntry('fb-person-8', '冯**', '冯欣然', '上海', '教师', '2026-09-16T02:00:00Z'),
        rosterEntry('fb-person-9', '蒋**', null, '上海', '学生', null)
      ]
    }
  ]
}

// wx storage 是闪念间 mock 态的唯一真源：模块态跨 e2e 脚本运行存活（同 loggedIn），
// 清 storage 必须等价于完全重置——有 storage 时每次读都从 storage 载入；
// node --test 无 storage，回落模块态（进程内一致）。
function flashbackState(): FlashbackMockState {
  return wxStorage() ? loadFlashbackState() : flashback
}

function updateFlashbackState(patch: (state: FlashbackMockState) => FlashbackMockState): FlashbackMockState {
  flashback = patch(flashbackState())
  saveFlashbackState(flashback)
  return flashback
}

// 与后端 FogSpans.mask 同规则（mock 文本 BMP 字符，len 即字符数）：区间替换 ▓
function fogMaskedText(raw: string, spans: Array<{ start: number; len: number }>): string {
  let out = ''
  let cursor = 0
  for (const { start, len } of [...spans].sort((a, b) => a.start - b.start)) {
    out += raw.slice(cursor, start) + '▓'.repeat(len)
    cursor = start + len
  }
  return out + raw.slice(cursor)
}

// 与后端 Enrollment.active_statuses 同口径（pending/payment_pending/confirmed）
const ACTIVE_STATUSES: Record<string, true> = {
  pending: true,
  payment_pending: true,
  confirmed: true
}

/** e2e 钩子:测试脚本推进订单态(支付完成模拟) */
export function __setOrderStatus(status: string | null): void {
  orderStatusOverride = status
}

function variablesRecord(variables: object): Record<string, unknown> {
  return variables as Record<string, unknown>
}

// #355 P1-3：登录且在目标上有活跃报名 → myEnrollment 投影（后端活跃集口径）
function myEnrollmentFor(kind: 'event' | 'course', offeringId: string) {
  if (!loggedIn || !enrollment) return null
  const targetId = kind === 'event' ? enrollment.eventId : enrollment.courseId
  if (targetId !== offeringId || !ACTIVE_STATUSES[enrollment.status]) return null
  return {
    id: enrollment.id,
    status: enrollment.status,
    approvalDeadline: enrollment.approvalDeadline
  }
}



function responseFor(document: string, variables: object): unknown {
  const values = variablesRecord(variables)

  if (document.includes('query PublicInitiatives')) return { publicInitiatives: [initiativeCard] }
  if (document.includes('query PublicInitiative(')) {
    // 1024 横幅(R9)指向 hackerstart1024(dev/prod 真实 slug);mock 归一到样例卡
    const knownSlugs = [initiativeCard.slug, 'hackerstart1024']
    if (typeof values.slug !== 'string' || !knownSlugs.includes(values.slug)) return { publicInitiative: null }
    return {
      publicInitiative: {
        ...initiativeCard,
        slug: values.slug,
        cityCount: 1,
        eventCount: 1,
        confirmedCount: 1,
        qualifiedEventCount: 1,

        futureEvents: [
          {
            initiativeSlug: 'hackerstart1024',
            initiativeName: 'Hacker Start 1024',
            initiativeStartsAt: '2026-10-24T00:00:00Z',
            events: [
              { id: 'ev-1', slug: 'hs-bj-01', title: 'Agent 入门工作坊', city: '北京', startsAt: '2026-10-24T06:00:00Z', capacity: 32, confirmedCount: 23, registrationDeadline: null },
              { id: 'ev-2', slug: 'hs-sh-01', title: '上海站 · 1024 黑客松', city: '上海', startsAt: '2026-11-24T06:00:00Z', capacity: 16, confirmedCount: 16, registrationDeadline: null },
              { id: 'ev-3', slug: 'hs-gz-01', title: '广州站(已截止)', city: '广州', startsAt: '2026-12-01T06:00:00Z', capacity: 24, confirmedCount: 5, registrationDeadline: '2026-09-01T00:00:00Z' }
            ]
          }
        ],
        publicWishes: [
          { id: 'w-1', content: '一起出一本书:《她们的第一行代码》', city: '北京', wisherMasked: '李**', endorsementCount: 5, endorsedByMe: false, mine: false, comments: [{ id: 'c-1', content: '算我一个', commenterMasked: '王**', insertedAt: '2026-09-17T00:00:00Z' }], insertedAt: '2026-09-17T00:00:00Z' },
          { id: 'w-2', content: '开一门 Rust 系统课', city: '上海', wisherMasked: '陈*', endorsementCount: 2, endorsedByMe: true, mine: false, comments: [], insertedAt: '2026-09-18T00:00:00Z' }
        ],
        myPrivateWishes: [
          { id: 'pw-1', content: '想学 Rust(私人)', city: '北京', wisherMasked: null, endorsementCount: 0, endorsedByMe: false, mine: true, comments: [], insertedAt: '2026-09-18T00:00:00Z' }
        ],
        cities: [{ city: '北京', events: [initiativeEvent] }]
      }
    }
  }

  if (document.includes('query Catalog')) {
    // #355 P2-10：CatalogSearch 带 title ilike `%kw%` 过滤变量（大小写不敏感 includes 语义）
    const filter = values.eventFilter ?? values.courseFilter
    let keyword: string | null = null
    if (filter && typeof filter === 'object' && 'title' in filter) {
      const title = filter.title
      if (title && typeof title === 'object' && 'ilike' in title && typeof title.ilike === 'string') {
        keyword = title.ilike.replace(/%/g, '').toLowerCase()
      }
    }
    const matches = (title: string) => !keyword || title.toLowerCase().includes(keyword)
    return {
      listEvents: { results: records.filter(({ title }) => matches(title)) },
      listCourses: { results: [course].filter(({ title }) => matches(title)) }
    }
  }
  if (document.includes('query EventDetail')) {
    return {
      getEvent: records.find(({ id }) => id === values.id) ?? null,
      myEnrollment: myEnrollmentFor('event', String(values.id ?? ''))
    }
  }
  if (document.includes('query EventModerationScope')) {
    // #508-A：成员面探测——登录即视为 workspace-1 成员（owner），活动存在即给 scope；
    // 未登录按匿名口径返回 null（真实端是 forbidden_field 整查询报错，real.ts 同归 false）
    const record = records.find(({ id }) => id === values.id) ?? null
    return {
      getEvent: loggedIn && record ? { id: record.id, workspaceId: workspace.id } : null
    }
  }
  if (document.includes('query EventModerators(')) {
    // 主理人列表（#558 后续）：mock 用户即 owner（manage 分支先行命中），
    // 列表恒含本人——非管理角色主理人的「我在列表」分支由 real 层单测覆盖
    return { eventModerators: loggedIn ? [{ userId: 'user-1' }] : [] }
  }
  if (document.includes('query CourseDetail')) {
    return {
      getCourse: values.id === course.id ? course : null,
      myEnrollment: myEnrollmentFor('course', String(values.id ?? ''))
    }
  }
  if (document.includes('query Enrollment(')) {
    return {
      enrollments: {
        results: loggedIn && enrollment && enrollment.id === values.id ? [enrollment] : []
      }
    }
  }
  if (document.includes('query Session')) {
    // 审批行 contextTitle 查表键（与后端 enrich 的 offering 标题装配同构）
    const targetId = enrollment?.eventId ?? enrollment?.courseId ?? null
    return {
      me: loggedIn
        ? {
            id: 'user-1',
            email: 'cheng@example.com',
            displayName: '小程',
            memberNumber: 'CGC-000001',
            joinedAt: new Date().toISOString(),
            isPlatformAdmin: false
          }
        : null,
      meWorkspaces: loggedIn ? [workspace] : [],
      myPendingApprovals: loggedIn && enrollment?.status === 'pending'
        ? [{
            id: enrollment.id,
            kind: 'enrollment',
            workspaceId: enrollment.workspaceId,
            userId: enrollment.userId,
            eventId: enrollment.eventId,
            courseId: enrollment.courseId,
            status: enrollment.status,
            approvalDeadline: enrollment.approvalDeadline,
            requesterName: '小程',
            // 与后端 enrich 的 offering 标题装配同构：按 event/course id 查标题
            contextTitle: [...records, course].find(
              ({ id }) => id === targetId
            )?.title ?? null,
            tierName: null,
            amount: null
          }]
        : []
    }
  }
  if (document.includes('query MyEnrollments')) {
    return { enrollments: { results: loggedIn && enrollment ? [enrollment] : [] } }
  }
  if (document.includes('mutation SignInWithPlatform')) {
    loggedIn = true
    return { signInWithPlatform: { id: 'user-1', email: 'cheng@example.com', isPlatformAdmin: false } }
  }
  if (document.includes('mutation SignOut')) {
    loggedIn = false
    return { signOut: true }
  }
  if (document.includes('mutation CreateEnrollment')) {
    const input = values.input as Record<string, unknown>
    const eventId = typeof input.eventId === 'string' ? input.eventId : null
    const courseId = typeof input.courseId === 'string' ? input.courseId : null
    // #510 年龄门控（后端 action 语义的 mock 投影）：min_age 非空的目标未带
    // ageConfirmed=true → 业务错误（与 check-in 三分支同款 errors 形状）
    const ageGateTarget = records.find(
      (record) => record.id === eventId && 'minAge' in record && typeof record.minAge === 'number'
    )
    if (ageGateTarget && input.ageConfirmed !== true) {
      return {
        createEnrollment: {
          result: null,
          errors: [
            {
              message: 'age confirmation is required for this enrollment',
              code: 'enrollment_age_confirmation_required'
            }
          ]
        }
      }
    }
    // 收费/押金路径 → payment_pending（R5/KTD2：定价场 tierId 在场；押金场零档位）
    const requiresPayment =
      (typeof input.tierId === 'string' && input.tierId !== '') ||
      records.some((record) => 'depositEnabled' in record && record.depositEnabled === true && record.id === eventId)
    const status = requiresPayment ? 'payment_pending' : eventId === 'event-1' ? 'pending' : 'confirmed'
    // 缴费模式/截止时间从目标记录推导（与后端 payment_mode 计算同规则：押金 > 定价 > 免费）
    const target = [...records, course].find(({ id }) => id === (eventId ?? courseId))
    const paymentMode =
      target && 'depositEnabled' in target && target.depositEnabled === true
        ? 'deposit'
        : target?.pricingEnabled === true
          ? 'pricing'
          : 'free'
    enrollment = {
      id: 'enrollment-1',
      workspaceId: workspace.id,
      eventId,
      courseId,
      userId: 'user-1',
      status,
      submissionPayload: String(input.submissionPayload ?? '{}'),
      approvalDeadline: status === 'pending'
        ? new Date(Date.now() + 12 * 3_600_000).toISOString()
        : null,
      rejectionReason: null,
      approvedAt: null,
      expiredAt: null,
      cancelledAt: null,
      insertedAt: new Date().toISOString(),
      // 生成时点 = create（KTD5）——confirmed 才出示，故仅免缴直通有码
      checkInCode: status === 'confirmed' ? CHECK_IN_CODE : null,
      paymentMode,
      // #617：与后端 Enrollment 计算字段同形——startsAt 直接取目标记录；
      // venue 必须文本化为 city+district（读面契约是 Venue.text 结果，不是
      // 目标记录里的 JsonString；course 无 venue 槽 → null）
      startsAt: target?.startsAt ?? null,
      venue: venueCityDistrictText(target && 'venue' in target ? target.venue : null),
      registrationDeadline: target?.registrationDeadline ?? null
    }
    checkedIn = false
    return { createEnrollment: { result: enrollment, errors: [] } }
  }
  if (document.includes('mutation CancelEnrollment')) {
    if (enrollment) {
      enrollment = {
        ...enrollment,
        status: 'cancelled',
        cancelledAt: new Date().toISOString()
      }
    }
    return { cancelEnrollment: { result: enrollment, errors: [] } }
  }
  if (document.includes('mutation ConfirmEnrollment')) {
    if (enrollment) {
      enrollment = {
        ...enrollment,
        status: 'confirmed',
        approvalDeadline: null,
        approvedAt: new Date().toISOString(),
        checkInCode: enrollment.checkInCode ?? CHECK_IN_CODE
      }
    }
    return { confirmEnrollment: { result: enrollment, errors: [] } }
  }
  if (document.includes('mutation RejectEnrollment')) {
    const input = values.input as Record<string, unknown> | undefined
    if (enrollment) {
      enrollment = {
        ...enrollment,
        status: 'rejected',
        approvalDeadline: null,
        rejectionReason: typeof input?.rejectionReason === 'string' ? input.rejectionReason : null
      }
    }
    return { rejectEnrollment: { result: enrollment, errors: [] } }
  }
  if (document.includes('mutation ApproveJoinRequest')) {
    return { approveJoinRequest: { result: { id: values.id, status: 'approved', approvedAt: new Date().toISOString() }, errors: [] } }
  }
  if (document.includes('mutation RejectJoinRequest')) {
    return { rejectJoinRequest: { result: { id: values.id, status: 'rejected', rejectionReason: null }, errors: [] } }
  }
  if (document.includes('mutation GrantConsent')) {
    return { grantMiniProgramNotificationConsent: 1 }
  }
  if (document.includes('mutation GenerateMiniProgramCode')) {
    return {
      generateMiniProgramCode: {
        invitationId: 'invitation-1',
        platform: 'wechat',
        scene: `mock_scene_${values.workspaceId}`,
        codeBase64: '',
        expiresAt: new Date(Date.now() + 24 * 3_600_000).toISOString()
      }
    }
  }
  if (document.includes('mutation CreateOrder')) {
    // e2e 边界(#172):止于订单生成 + JSAPI 凭据返回,不模拟支付完成
    const targetRecord = records.find(({ id }) => id === enrollment?.eventId)
    // 押金单金额 = 目标场押金（R2 单源，零改动的下单链在此被 mock 忠实复现）；
    // orderKind 与后端 order_kind/2 同规则（押金场开 → deposit）——支付页的押金
    // 同意门以它为准，mock 漏带字段会被 parseOrderKind fail-closed 抓住
    const depositOrder =
      targetRecord && 'depositEnabled' in targetRecord && targetRecord.depositEnabled === true
    order = {
      id: 'order-1',
      enrollmentId: String((values.input as Record<string, unknown>).enrollmentId ?? ''),
      status: 'pending',
      amountCents: depositOrder ? DEPOSIT_AMOUNT_CENTS : 19900,
      expireAt: new Date(Date.now() + 2 * 3_600_000).toISOString(),
      transactionId: null,
      orderKind: depositOrder ? 'deposit' : 'enrollment'
    }
    return {
      createOrder: {
        result: order,
        errors: [],
        metadata: {
          credential: JSON.stringify({
            type: 'jsapi',
            pay_params: {
              appId: 'wx-mock',
              timeStamp: String(Math.floor(Date.now() / 1000)),
              nonceStr: 'mock-nonce',
              package: 'prepay_id=mock123',
              signType: 'RSA',
              paySign: 'mock-sign'
            }
          })
        }
      }
    }
  }
  if (document.includes('query OrderStatus')) {
    return {
      orderStatus: order
        ? { ...order, status: orderStatusOverride ?? order.status }
        : null
    }
  }
  if (document.includes('query MyOrders')) {
    return { myOrders: { results: loggedIn && order ? [order] : [] } }
  }
  if (document.includes('mutation AdmitMemberByToken')) {
    return {
      admitMemberByToken: {
        id: 'invitation-1',
        workspaceId: workspace.id,
        workspaceName: workspace.name,
        status: 'accepted',
        acceptedAt: new Date().toISOString()
      }
    }
  }
  if (document.includes('query FlashbackCapsule')) {
    const state = flashbackState()
    const token = typeof values.token === 'string' && values.token ? values.token : null
    // token 面优先（claim 后链接作废 → 可区分错误）；会话腿：未登录 → auth_required
    if (token && flashbackClaimedTokens.has(token)) {
      return { errors: [{ message: 'token claimed', code: 'flashback_token_claimed' }] }
    }
    if (!loggedIn && !token) {
      return { errors: [{ message: 'token or sign-in required', code: 'flashback_auth_required' }] }
    }
    // 三级视角：登录了但库里还没有匹配档案（__setFlashbackUnclaimed / storage 开关驱动）
    if (!token && (flashbackUnclaimed || e2eFlag(FLASHBACK_UNCLAIMED_KEY))) {
      return { errors: [{ message: 'person not bound', code: 'flashback_person_not_bound' }] }
    }
    // R34 城市钉：cities 恒全量（模拟后端投影，字节序去重排序）
    const cityFilter = typeof values.city === 'string' && values.city ? values.city : null
    return {
      flashbackCapsule: {
        me: {
          id: 'fb-person-1',
          fullName: '王小明',
          surname: '王',
          city: '北京',
          occupationThen: '测试工程师',
          participation: 'attended',
          appliedAt: '2014-01-11T13:06:00Z',
          quoteLevel: state.quoteLevel,
          quote: (() => {
            const first = (state.chosenQuoteSpans ?? [])[0]
            if (!first) return null
            const host =
              first.questionKey === 'today.now'
                ? state.today.nowStatus
                : first.questionKey === 'today.want'
                  ? state.today.want
                  : first.questionKey === 'today.need'
                    ? state.today.need
                    : first.questionKey === 'today.say'
                      ? state.today.say
                      : FLASHBACK_RAW_TEXT
            return host ? host.slice(first.start, first.start + first.len) : null
          })(),
          quoteSpans: state.chosenQuoteSpans ?? [],
          quoteStats:
            state.quoteLevel === 'off' ? null : { likeCount: state.likeCount ?? 0 },
          today: { ...state.today, fogSpans: state.todayFogSpans ?? {} },
          answers: [
            {
              id: 'fb-answer-1',
              questionKey: 'self_intro',
              rawText: FLASHBACK_RAW_TEXT,
              // 雾面区间与雾化文本都从 mock state 推导（adjustFog 写后回读，P2）
              fogSpans: state.fogSpans,
              text: fogMaskedText(FLASHBACK_RAW_TEXT, state.fogSpans)
            },
            {
              id: 'fb-answer-2',
              questionKey: 'funny_thing',
              rawText: FLASHBACK_FUN_RAW,
              fogSpans: [],
              text: FLASHBACK_FUN_RAW
            }
          ]
        },
        // R34 城市钉同款语义：名册按人城市过滤，筛空场次整架撤下
        archives: flashbackArchives(state.today.sentToWallAt)
          .map((archive) => ({
            ...archive,
            roster: cityFilter
              ? archive.roster.filter((entry) => entry.city === cityFilter)
              : archive.roster
          }))
          .filter((archive) => archive.roster.length > 0),

        futureEvents: [
          {
            initiativeSlug: 'hackerstart1024',
            initiativeName: 'Hacker Start 1024',
            initiativeStartsAt: '2026-10-24T00:00:00Z',
            events: [
              { id: 'ev-1', slug: 'hs-bj-01', title: 'Agent 入门工作坊', city: '北京', startsAt: '2026-10-24T06:00:00Z', capacity: 32, confirmedCount: 23, registrationDeadline: null },
              { id: 'ev-2', slug: 'hs-sh-01', title: '上海站 · 1024 黑客松', city: '上海', startsAt: '2026-11-24T06:00:00Z', capacity: 16, confirmedCount: 16, registrationDeadline: null },
              { id: 'ev-3', slug: 'hs-gz-01', title: '广州站(已截止)', city: '广州', startsAt: '2026-12-01T06:00:00Z', capacity: 24, confirmedCount: 5, registrationDeadline: '2026-09-01T00:00:00Z' }
            ]
          }
        ],
        publicWishes: [
          { id: 'w-1', content: '一起出一本书:《她们的第一行代码》', city: '北京', wisherMasked: '李**', endorsementCount: 5, endorsedByMe: false, mine: false, comments: [{ id: 'c-1', content: '算我一个', commenterMasked: '王**', insertedAt: '2026-09-17T00:00:00Z' }], insertedAt: '2026-09-17T00:00:00Z' },
          { id: 'w-2', content: '开一门 Rust 系统课', city: '上海', wisherMasked: '陈*', endorsementCount: 2, endorsedByMe: true, mine: false, comments: [], insertedAt: '2026-09-18T00:00:00Z' }
        ],
        myPrivateWishes: [
          { id: 'pw-1', content: '想学 Rust(私人)', city: '北京', wisherMasked: null, endorsementCount: 0, endorsedByMe: false, mine: true, comments: [], insertedAt: '2026-09-18T00:00:00Z' }
        ],
        cities: [
          ...new Set([
            ...flashbackArchives(state.today.sentToWallAt).flatMap((archive) =>
              archive.roster.map((entry) => entry.city)
            )
          ])
        ].sort()
      }
    }
  }

  if (document.includes('query FlashbackPublicStats')) {
    // 路人态长廊（R32 统计层）：场次 + 城市 + 走进教室人数 + 全局已回来计数
    return {
      flashbackPublicStats: {
        archives: [
          {
            key: '2012-02-26-sh',
            name: 'Rails Girls Shanghai',
            city: '上海',
            occurredOn: '2012-02-26',
            appliedCount: 30,
            attendedCount: 12
          },
          {
            key: FLASHBACK_E2E_ARCHIVE.key,
            name: FLASHBACK_E2E_ARCHIVE.name,
            city: FLASHBACK_E2E_ARCHIVE.city,
            occurredOn: FLASHBACK_E2E_ARCHIVE.occurredOn,
            appliedCount: 344,
            attendedCount: 102
          }
        ],
        returnedCount: 4,
        sentCount: 4
      }
    }
  }

  if (document.includes('mutation FlashbackEnter')) {
    const token = typeof values.token === 'string' ? values.token : ''
    if (!token) {
      return { errors: [{ message: 'token not found', code: 'flashback_token_not_found' }] }
    }
    if (flashbackClaimedTokens.has(token)) {
      return { errors: [{ message: 'token claimed', code: 'flashback_token_claimed' }] }
    }
    const state = flashbackState()
    return {
      flashbackEnter: {
        line: 'memory',
        profile: {
          fullName: '王小明',
          surname: '王',
          city: '北京',
          occupationThen: '测试工程师',
          participation: 'attended',
          role: 'learner',
          appliedAt: '2014-01-11T13:06:00Z',
          archive: { ...FLASHBACK_E2E_ARCHIVE },
          answers: [
            {
              id: 'fb-answer-1',
              questionKey: 'self_intro',
              rawText: FLASHBACK_RAW_TEXT,
              fogSpans: state.fogSpans
            },
            {
              id: 'fb-answer-2',
              questionKey: 'funny_thing',
              rawText: FLASHBACK_FUN_RAW,
              fogSpans: []
            }
          ]
        },
        progress: {
          quoteLevel: state.quoteLevel,
          maskedPhone: '139****0001',
          maskedEmail: null,
          today: state.today
        }
      }
    }
  }

  if (document.includes('mutation FlashbackMarkRevealed')) {
    return { flashbackMarkRevealed: { recorded: true } }
  }

  if (document.includes('mutation FlashbackSendToWall')) {
    // 幂等（R11）：已有寄出时间原样返回，不覆盖
    const next = updateFlashbackState((state) => ({
      ...state,
      today: { ...state.today, sentToWallAt: state.today.sentToWallAt ?? new Date().toISOString() }
    }))
    return {
      flashbackSendToWall: {
        sentToWallAt: next.today.sentToWallAt,
        maskedPhone: '139****0001',
        maskedEmail: null
      }
    }
  }

  if (document.includes('mutation FlashbackClaim')) {
    if (!loggedIn) {
      return { errors: [{ message: 'authentication required', code: 'flashback_auth_required' }] }
    }
    // claim_miss 开关：模拟库里没有匹配（bound:false → 前端给找回引导）
    if (e2eFlag(FLASHBACK_CLAIM_MISS_KEY)) {
      return { flashbackClaim: { bound: false, boundCount: 0, maskedPhone: null } }
    }
    const token = typeof values.token === 'string' && values.token ? values.token : null
    if (token) flashbackClaimedTokens.add(token)
    // 登录即视为库内匹配成功（bound）；unclaimed 开关复位（模块态 + storage——
    // storage 不清会让后续 capsule 会话腿仍报 not_bound，前端认领循环）
    flashbackUnclaimed = false
    try {
      wxStorage()?.setStorageSync(FLASHBACK_UNCLAIMED_KEY, '0')
    } catch {
      // node --test 无 storage：模块态已复位
    }
    return { flashbackClaim: { bound: true, boundCount: 1, maskedPhone: '139****0001' } }
  }
  if (document.includes('mutation FlashbackSubmitToday')) {
    const input = (values.input ?? {}) as Record<string, unknown>
    const next = updateFlashbackState((state) => ({
      ...state,
      today: {
        ...state.today,
        nowStatus: typeof input.nowStatus === 'string' ? input.nowStatus : state.today.nowStatus,
        want: typeof input.want === 'string' ? input.want : state.today.want,
        say: typeof input.say === 'string' ? input.say : state.today.say
      }
    }))
    return { flashbackSubmitToday: { today: next.today } }
  }
  if (document.includes('mutation FlashbackSetQuoteLicense')) {
    const level = values.level
    const spans = (values.chosenQuoteSpans ?? null) as
      | Array<{ questionKey: string; start: number; len: number }>
      | null
    if (level === 'off' || level === 'anonymous' || level === 'credited') {
      updateFlashbackState((state) => ({
        ...state,
        quoteLevel: level,
        // R35 未圈选 = 不上墙：level 非 off 但没带区间时保留既有区间（后端同语义）
        chosenQuoteSpans: level === 'off' ? [] : (spans ?? state.chosenQuoteSpans)
      }))
    }
    return {
      flashbackSetQuoteLicense: {
        level: flashbackState().quoteLevel,
        chosenQuoteSpans: flashbackState().chosenQuoteSpans
      }
    }
  }
  if (document.includes('mutation FlashbackAdjustFog')) {
    // 写面落 mock state（capsule 回读不再恒定初始 span，P2）
    const next = updateFlashbackState((state) => ({
      ...state,
      fogSpans: (values.spans ?? []) as Array<{ start: number; len: number }>
    }))
    return {
      flashbackAdjustFog: {
        answerId: values.answerId,
        fogSpans: next.fogSpans
      }
    }
  }
  if (document.includes('mutation FlashbackAdjustTodayFog')) {
    // today 句级雾面写面(mock state.todayFogSpans[field] 整份覆写)
    const field = typeof values.field === 'string' ? values.field : ''
    const validFields = ['now', 'want', 'need', 'say']
    if (!validFields.includes(field)) {
      return { errors: [{ message: 'invalid today field', code: 'flashback_invalid_today_field' }] }
    }
    const next = updateFlashbackState((state) => ({
      ...state,
      todayFogSpans: {
        ...(state.todayFogSpans ?? {}),
        [field]: (values.spans ?? []) as Array<{ start: number; len: number }>
      }
    }))
    return {
      flashbackAdjustTodayFog: {
        field,
        fogSpans: JSON.stringify(next.todayFogSpans ?? {})
      }
    }
  }
  if (document.includes('mutation CheckInEnrollment')) {
    // #508-A：核销三分支（成功/重复/错码）。幂等由 checkedIn 标记承担——同一
    // 报名第二次核销稳定返回 already（后端唯一索引语义的 mock 投影）
    const code = typeof values.code === 'string' ? values.code : ''
    const current = enrollment
    const canCheckIn =
      loggedIn &&
      current?.status === 'confirmed' &&
      current.eventId === values.eventId &&
      current.checkInCode === code
    if (!canCheckIn || !current) {
      return {
        checkInEnrollment: {
          enrollmentId: null,
          checkedInAt: null,
          method: null,
          depositRefund: null,
          errors: [{ message: 'check-in code is invalid for this event', code: 'attendance_invalid_code' }]
        }
      }
    }
    if (checkedIn) {
      return {
        checkInEnrollment: {
          enrollmentId: null,
          checkedInAt: null,
          method: null,
          depositRefund: null,
          errors: [{ message: 'this enrollment has already been checked in', code: 'attendance_already_checked_in' }]
        }
      }
    }
    checkedIn = true
    // 押金单已付 → 核销即退（KTD6 分派表的 mock 投影）；无单/免费场 → null
    const depositRefund =
      order?.enrollmentId === current.id && order.status === 'paid' ? 'refunding' : null
    return {
      checkInEnrollment: {
        enrollmentId: current.id,
        checkedInAt: new Date().toISOString(),
        method: typeof values.method === 'string' ? values.method : 'manual',
        depositRefund,
        errors: []
      }
    }
  }

  throw new Error(`E2E GraphQL mock 未处理该 operation：${document.slice(0, 80)}`)
}

export function mockGraphQLRequest<TData>(document: RequestDocument, variables: object): TData {
  return responseFor(String(document), variables) as TData
}
