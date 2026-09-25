import type { RequestDocument } from 'graphql-request'
// 相对 + 显式 .ts：mockTransport 同时被 node --experimental-strip-types 直接加载
// （tests/mock-transport.test.ts），该 runner 不认 `@/` 别名；Taro 侧同款先例
// 见 src/domain/entry.ts 的 './share-route.ts'。
import { venueCityDistrictText } from '../domain/format.ts'
import { TODAY_FIELDS } from '../domain/flashback.ts'

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
    initiativeId: 'initiative-1',
    // 无介绍样例：详情页不渲染「活动介绍」块（null 分支）
    description: null,
    // #538 公开主理人投影样例：一行有 displayName、一行 null 回退 memberNumber，
    // 详情页渲染「本场主理人：主讲小援 · CGC-9A3F2C」（与真机 [JsonString!] 同形）
    publicModerators: [
      JSON.stringify({ display_name: '主讲小援', member_number: 'CGC-000001' }),
      JSON.stringify({ display_name: null, member_number: 'CGC-9A3F2C' })
    ]
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
    // 多段介绍样例（空行分段）：详情页「活动介绍」块逐段渲染
    description: '两天的线下共学，一起读完《重构》并现场动手实践。\n\n适合有半年以上编程经验、想提升代码设计能力的同学。\n\n请自带电脑，现场提供午餐与饮品。',
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
  /** #727 押金快照金额（后端 Enrollment.depositAmountCents 计算字段同规则：非押金场 null） */
  depositAmountCents: number | null
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
  /**
   * #771 卡片站外公开开关。**默认关**（不开是唯一初始态，没有任何隐式开启），
   * 且与 quoteLevel 完全独立——开实名档不会连带公开回忆。`shareId` 首次开启
   * 时生成、此后永不变更（关闭只清公开态，重开复用同一 id）。
   */
  cardSharing: { enabled: boolean; shareId: string | null }
  /**
   * wish2 U9（#790）：愿望写面 mock 存量——capsule/publicWishes 投影与四个
   * 写 mutation（Create/Endorse/Comment/Delete）+ Expect/Report 共用。
   * seed 两条公开 + 一条私愿对齐旧硬编码样例（w-1/w-2/pw-1）。
   */
  wishes: Array<{
    id: string
    content: string
    visibility: 'public' | 'private'
    city: string | null
    signature: string
    insertedAt: string
    deleted: boolean
    mine: boolean
    /** #837 回响 mock 样例;空数组 = 无回响。按首次发布时间正序 */
    echoes: Array<{
      id: string
      content: string
      status: 'published' | 'corrected'
      publishedAt: string
      correctedAt: string | null
    }>
  }>
  /** 本人已附议的愿望 id（mock 单设备单账号语义） */
  endorsedWishIds: string[]
  /** 本人已期待的愿望 id */
  expectedWishIds: string[]
  /** 愿望留言（wishId → 列表；commenter 恒本人——mock 会话语义） */
  wishComments: Record<string, Array<{ id: string; content: string; insertedAt: string }>>
}

const FLASHBACK_INITIAL_STATE: FlashbackMockState = {
  fogSpans: [{ start: 0, len: 7 }],
  quoteLevel: 'off',
  chosenQuoteSpans: [],
  likeCount: 3,
  today: { nowStatus: null, want: null, need: null, say: null, sentToWallAt: null },
  todayFogSpans: {},
  endorsedCardIds: [],
  cardSharing: { enabled: false, shareId: null },
  wishes: [
    {
      id: 'w-1',
      content: '一起出一本书:《她们的第一行代码》',
      visibility: 'public',
      city: '北京',
      signature: '李**',
      insertedAt: '2026-09-17T00:00:00Z',
      deleted: false,
      mine: false,
      // #837 多条回响+l+ 一场 corrected —— 验证「全部 N 条回响」展开态与已更正徽标
      echoes: [
        { id: 'e-1a', content: '书名想好了,叫《她的编译器》。第一章已写完,发给三位老学员看过。', status: 'published', publishedAt: '2026-09-20T08:30:00Z', correctedAt: null },
        { id: 'e-1b', content: '签约了!明年 3 月出版,稿费 10% 捐给 CGC 奖学金。', status: 'corrected', publishedAt: '2026-09-22T10:00:00Z', correctedAt: '2026-09-22T14:00:00Z' }
      ]
    },
    {
      id: 'w-2',
      content: '开一门 Rust 系统课',
      visibility: 'public',
      city: '上海',
      signature: '陈*',
      insertedAt: '2026-09-18T00:00:00Z',
      deleted: false,
      mine: false,
      // #837 单条回响 —— 默认渲染,无需展开
      echoes: [
        { id: 'e-2a', content: '已经开始备课了,先做 4 期免费直播试试水。', status: 'published', publishedAt: '2026-09-21T09:00:00Z', correctedAt: null }
      ]
    },
    {
      id: 'pw-1',
      content: '想学 Rust(私人)',
      visibility: 'private',
      city: '北京',
      signature: '我',
      insertedAt: '2026-09-18T00:00:00Z',
      deleted: false,
      mine: true,
      // #837 无回响 —— 不渲染回响卡,不显示「有回响」徽章
      echoes: []
    }
  ],
  endorsedWishIds: ['w-2'],
  expectedWishIds: [],
  wishComments: { 'w-1': [{ id: 'c-1', content: '算我一个', insertedAt: '2026-09-17T00:00:00Z' }] }
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
      parsed.endorsedCardIds.every((id) => typeof id === 'string') &&
      // #771：旧快照（本字段出现前写的）缺 cardSharing → 整体回落初始态。
      // 初始态 = 关且无 id，等价于「这台设备从没开过公开」——正是旧快照的真实
      // 语义，故回落不会伪造出一次公开（不做「补默认关」的部分合并：那会让
      // 脏数据里的 enabled:true 被静默保留）。
      typeof parsed.cardSharing === 'object' &&
      parsed.cardSharing !== null &&
      typeof parsed.cardSharing.enabled === 'boolean' &&
      (parsed.cardSharing.shareId === null || typeof parsed.cardSharing.shareId === 'string') &&
      // wish2 U9：旧快照（wishes 出现前）缺字段 → 整体回落（等价于该设备从没写过愿望）
      Array.isArray(parsed.wishes) &&
      parsed.wishes.every((wish) => typeof wish.mine === 'boolean') &&
      Array.isArray(parsed.endorsedWishIds) &&
      Array.isArray(parsed.expectedWishIds) &&
      typeof parsed.wishComments === 'object' &&
      parsed.wishComments !== null
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
const WORKSPACE_ACCESS_DENIED_KEY = 'cgc.e2e.workspace_access_denied'
const flashbackClaimedTokens = new Set<string>()
let flashbackUnclaimed = false

function e2eFlag(key: string): boolean {
  // module-level override(node --test 优先,storage 兜底——e2e weapp 流程未起 wx 模块)
  if (e2eModuleFlags[key] !== undefined) return e2eModuleFlags[key] === true
  try {
    return wxStorage()?.getStorageSync(key) === '1'
  } catch {
    return false
  }
}
const e2eModuleFlags: Record<string, boolean> = {}

/** e2e 钩子(node --test):workspace_access_denied 开后,Session.meWorkspaces 恒空 */
export function __setWorkspaceAccessDenied(value: boolean): void {
  if (value) e2eModuleFlags['cgc.e2e.workspace_access_denied'] = true
  else delete e2eModuleFlags['cgc.e2e.workspace_access_denied']
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

// ── #771 卡片站外公开：公开面 fixture 与生成规则 ──────────────────────────
// 公开卡是**独立投影**，不复用本人卡字段：姓名走 surname_masked 口径（王**），
// 当年答案只出 self_intro/funny_thing/os 三题（PII 行 phone/email/social_media
// 与 why_join 都不进），today 四问全出。雾段 text 恒空——与后端 FogSpans.segments
// 同规则（原文字符不出服务端）。
const FLASHBACK_SHARE_ANSWERS = [
  { questionKey: 'self_intro', raw: FLASHBACK_RAW_TEXT },
  { questionKey: 'funny_thing', raw: FLASHBACK_FUN_RAW },
  { questionKey: 'os', raw: '当年我用的是 Windows XP，装了个假的 Mac 主题。' }
]

/** 48 位十六进制（与后端 share id 同格式：24 字节随机数的 hex）。 */
function newShareId(): string {
  let out = ''
  while (out.length < 48) {
    out += Math.floor(Math.random() * 0x100000000)
      .toString(16)
      .padStart(8, '0')
  }
  return out.slice(0, 48)
}

/** 与后端 FogSpans.segments 同规则：按已验证区间切段，fog 段 text 恒空。
 *  校验失败（重叠/越界/非法 span）按**全雾** fail-closed——宁过度保护不泄露。 */
function safeSegments(
  raw: string,
  spans: Array<{ start: number; len: number }>
): Array<{ text: string; fog: boolean; len: number }> {
  const sorted = [...spans].sort((a, b) => a.start - b.start)
  const valid =
    sorted.every((span) => Number.isInteger(span.start) && Number.isInteger(span.len) && span.len > 0 && span.start >= 0) &&
    sorted.every((span, index) => index === 0 || span.start >= sorted[index - 1].start + sorted[index - 1].len) &&
    sorted.every((span) => span.start + span.len <= raw.length)
  if (!valid) return [{ text: '', fog: true, len: raw.length }]

  const segments: Array<{ text: string; fog: boolean; len: number }> = []
  let cursor = 0
  for (const span of sorted) {
    const head = raw.slice(cursor, span.start)
    if (head) segments.push({ text: head, fog: false, len: 0 })
    segments.push({ text: '', fog: true, len: span.len })
    cursor = span.start + span.len
  }
  const tail = raw.slice(cursor)
  if (tail) segments.push({ text: tail, fog: false, len: 0 })
  return segments
}

/** 公开卡（#771）：本人预览与匿名读面**同一份**——一处口径，两条入口不漂移。 */
function flashbackSharedCard(state: FlashbackMockState) {
  const todayRows: Array<[string, string | null, Array<{ start: number; len: number }>]> = [
    ['today.now', state.today.nowStatus, state.todayFogSpans?.now ?? []],
    ['today.want', state.today.want, state.todayFogSpans?.want ?? []],
    ['today.need', state.today.need, state.todayFogSpans?.need ?? []],
    ['today.say', state.today.say, state.todayFogSpans?.say ?? []]
  ]
  return {
    // surname_masked 口径（王**）——不是本人卡的全名
    displayName: '王**',
    city: '北京',
    appliedAt: '2014-01-11T13:06:00+08:00',
    occurredOn: FLASHBACK_E2E_ARCHIVE.occurredOn,
    answers: FLASHBACK_SHARE_ANSWERS.map(({ questionKey, raw }) => ({
      questionKey,
      segments: safeSegments(raw, questionKey === 'self_intro' ? state.fogSpans : [])
    })),
    today: todayRows
      .filter(([, text]) => typeof text === 'string' && text !== '')
      .map(([questionKey, text, spans]) => ({
        questionKey,
        segments: safeSegments(text as string, spans)
      }))
  }
}

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

function wishEndorsementCount(state: FlashbackMockState, wishId: string): number {
  const otherPeople = wishId === 'w-1' ? 5 : wishId === 'w-2' ? 1 : 0
  return otherPeople + Number(state.endorsedWishIds.includes(wishId))
}

function wishQuotaRemaining(state: FlashbackMockState): number {
  const shanghaiYear = new Date(Date.now() + 8 * 3_600_000).getUTCFullYear()
  const yearStartUtc = Date.UTC(shanghaiYear, 0, 1) - 8 * 3_600_000
  // 删除只改 deleted，不移除原行；年度额度仍统计已软删的本人愿望。
  return Math.max(0, 3 - state.wishes.filter((wish) => wish.mine && Date.parse(wish.insertedAt) >= yearStartUtc).length)
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

// ── 志愿者招募（R20/R21）mock 态：一人一档 + 一人一批一份申请 ────────────────
// 与后端语义对齐的最小投影：批次恒有 open（空态分支由 e2e 脚本改 mock 也走不到，
// 见 e2e 的招募路径说明）；档案与申请在登录后才可见（getWorkspace 需登录）。
const RECRUITMENT_WORKSPACE = { id: workspace.id, name: workspace.name }
let resumeProfile: {
  id: string
  fullName: string
  contactEmail: string
  weeklyHours: number | null
  skills: string[]
  fileName: string | null
  fileContentType: string | null
  fileSize: number | null
  uploadedAt: string | null
} | null = null
let volunteerApplications: Array<Record<string, unknown>> = []

const recruitmentCohort = {
  id: 'cohort-1',
  name: '第 1 批 · 首批志愿者招募',
  applyDeadlineAt: new Date(Date.now() + 21 * 24 * 3_600_000).toISOString(),
  startsAt: new Date(Date.now() + 30 * 24 * 3_600_000).toISOString(),
  endsAt: null,
  status: 'open'
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
    const state = flashbackState()
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
        // #837 从 state.wishes 投影,回响样例与 FlashbackPublicWishes 一致流通
        publicWishes: state.wishes
          .filter((w) => w.visibility === 'public' && !w.deleted)
          .map((w) => {
            const echoes = w.echoes ?? []
            return {
              id: w.id,
              content: w.content,
              city: w.city,
              wisherMasked: w.signature,
              endorsementCount: wishEndorsementCount(state, w.id),
              endorsedByMe: state.endorsedWishIds.includes(w.id),
              mine: w.mine,
              comments: (state.wishComments[w.id] ?? []).map((comment) => ({ ...comment, commenterMasked: '王**' })),
              latestEcho: echoes.length > 0 ? echoes[echoes.length - 1] : null,
              echoCount: echoes.length,
              echoes,
              insertedAt: w.insertedAt
            }
          }),
        myPrivateWishes: state.wishes
          .filter((w) => w.visibility === 'private' && !w.deleted)
          .map((w) => {
            return {
              id: w.id,
              content: w.content,
              city: w.city,
              wisherMasked: null,
              endorsementCount: 0,
              endorsedByMe: false,
              mine: true,
              comments: [],
              latestEcho: null,
              echoCount: 0,
              echoes: [],
              insertedAt: w.insertedAt
            }
          }),
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
      meWorkspaces: loggedIn && !e2eFlag(WORKSPACE_ACCESS_DENIED_KEY) ? [workspace] : [],
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
      // #727：押金快照金额（与后端 Enrollment.depositAmountCents 同源口径——
      // 报名提交时物化；非押金场 null）。order-pay 创单前披露的金额源
      depositAmountCents:
        paymentMode === 'deposit' && target && 'depositAmountCents' in target
          ? (target.depositAmountCents ?? null)
          : null,
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
    const input = (values.input ?? {}) as Record<string, unknown>
    // #727 押金同意门（后端 action 语义的 mock 投影，同 #510 年龄门）：押金单
    // 未带 depositConsent=true → 业务错误（与真实后端同 code，前端文案表命中）
    if (depositOrder && input.depositConsent !== true) {
      return {
        createOrder: {
          result: null,
          errors: [
            {
              message: 'deposit consent is required before creating a deposit order',
              code: 'order_deposit_consent_required'
            }
          ],
          metadata: null
        }
      }
    }
    order = {
      id: 'order-1',
      enrollmentId: String(input.enrollmentId ?? ''),
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
  // ── 志愿者招募（R20/R21）：slug 解析 → 批次 / 档案 / 申请 ──────────────────
  if (document.includes('query RecruitmentWorkspace')) {
    // getWorkspace 需登录（策略 actor_present）——匿名按未授权口径返回 null，
    // 真端是 GraphQL 错误 → real.ts 的 resolveRecruitmentWorkspaceId 早退在
    // 登录检查上（这里只是兜底不给跨租户数据）
    return { getWorkspace: loggedIn ? RECRUITMENT_WORKSPACE : null }
  }
  if (document.includes('query CurrentRecruitmentCohort')) {
    return { currentRecruitmentCohort: loggedIn ? recruitmentCohort : null }
  }
  if (document.includes('query MyResumeProfile')) {
    return { myResumeProfile: loggedIn ? resumeProfile : null }
  }
  if (document.includes('query MyVolunteerApplications')) {
    return { myVolunteerApplications: loggedIn ? volunteerApplications : [] }
  }
  if (document.includes('mutation UpsertResumeProfile')) {
    const input = values.input as Record<string, unknown>
    const skills = Array.isArray(input.skills) ? (input.skills as string[]) : resumeProfile?.skills ?? []
    resumeProfile = {
      // 一人一档：二次 upsert 更新同一行（保留已上传的文件元数据）
      id: resumeProfile?.id ?? 'resume-profile-1',
      fullName: String(input.fullName ?? ''),
      contactEmail: String(input.contactEmail ?? ''),
      weeklyHours: typeof input.weeklyHours === 'number' ? input.weeklyHours : null,
      skills,
      fileName: resumeProfile?.fileName ?? null,
      fileContentType: resumeProfile?.fileContentType ?? null,
      fileSize: resumeProfile?.fileSize ?? null,
      uploadedAt: resumeProfile?.uploadedAt ?? null
    }
    return { upsertResumeProfile: { result: resumeProfile, errors: [] } }
  }
  if (document.includes('mutation UploadResumeFile')) {
    const input = values.input as Record<string, unknown>
    // 先建档再上传（U2 契约：档案缺失 → resume_profile_not_found）
    if (!resumeProfile) {
      return {
        uploadResumeFile: {
          result: null,
          errors: [
            { message: 'resume profile not found', code: 'resume_profile_not_found' }
          ]
        }
      }
    }
    // 大小以**实际解码字节数**为准（与后端同规则）：base64 长度 → 原始字节数
    const content = typeof input.contentBase64 === 'string' ? input.contentBase64 : ''
    resumeProfile = {
      ...resumeProfile,
      fileName: String(input.fileName ?? ''),
      fileContentType: String(input.contentType ?? ''),
      fileSize: Math.floor((content.length * 3) / 4),
      uploadedAt: new Date().toISOString()
    }
    return { uploadResumeFile: { result: resumeProfile, errors: [] } }
  }
  if (document.includes('mutation CreateVolunteerApplication')) {
    const input = values.input as Record<string, unknown>
    const cohortId = String(input.cohortId ?? '')
    if (cohortId !== recruitmentCohort.id) {
      return {
        createVolunteerApplication: {
          result: null,
          errors: [
            { message: 'recruitment cohort not found', code: 'volunteer_application_cohort_not_found' }
          ]
        }
      }
    }
    // 同批一份（后端 unique_per_cohort 的 mock 投影，AE2 数据面）
    if (volunteerApplications.some((row) => row.cohortId === cohortId)) {
      return {
        createVolunteerApplication: {
          result: null,
          errors: [
            {
              message: 'volunteer application already submitted for this cohort',
              code: 'volunteer_application_already_submitted'
            }
          ]
        }
      }
    }
    const application = {
      id: `volunteer-application-${volunteerApplications.length + 1}`,
      cohortId,
      position: String(input.position ?? ''),
      city: typeof input.city === 'string' ? input.city : null,
      heardAboutUs: typeof input.heardAboutUs === 'string' ? input.heardAboutUs : null,
      hasInternalReferrer: input.hasInternalReferrer === true,
      message: typeof input.message === 'string' ? input.message : null,
      status: 'submitted',
      rejectionReason: null,
      assignedEventId: null,
      assignmentNote: null,
      assignedAt: null
    }
    volunteerApplications = [application, ...volunteerApplications]
    return { createVolunteerApplication: { result: application, errors: [] } }
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
          appliedAt: '2014-01-11T13:06:00+08:00',
          quoteLevel: state.quoteLevel,
          quote: (() => {
            const first = (state.chosenQuoteSpans ?? [])[0]
            if (!first) return null
            const todayHost = TODAY_FIELDS.find((row) => row.questionKey === first.questionKey)
            const host = (todayHost ? state.today[todayHost.field] : null) || FLASHBACK_RAW_TEXT
            return host ? host.slice(first.start, first.start + first.len) : null
          })(),
          quoteSpans: state.chosenQuoteSpans ?? [],
          quoteStats:
            state.quoteLevel === 'off' ? null : { likeCount: state.likeCount ?? 0 },
          today: { ...state.today, fogSpans: state.todayFogSpans ?? {} },
          // #771：开关与本人预览恒带（后端非空字段）。enabled/shareId 从 state
          // 派生，preview 与匿名读面同一份投影——关着时预览仍在（本人视角）。
          cardSharing: {
            enabled: state.cardSharing.enabled === true,
            shareId: state.cardSharing.shareId ?? null,
            preview: flashbackSharedCard(state)
          },
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
        // #837 从 state.wishes 投影,回响样例与 FlashbackPublicWishes 一致流通
        publicWishes: state.wishes
          .filter((w) => w.visibility === 'public' && !w.deleted)
          .map((w) => {
            const echoes = w.echoes ?? []
            return {
              id: w.id,
              content: w.content,
              city: w.city,
              wisherMasked: w.signature,
              endorsementCount: wishEndorsementCount(state, w.id),
              endorsedByMe: state.endorsedWishIds.includes(w.id),
              mine: w.mine,
              comments: (state.wishComments[w.id] ?? []).map((comment) => ({ ...comment, commenterMasked: '王**' })),
              latestEcho: echoes.length > 0 ? echoes[echoes.length - 1] : null,
              echoCount: echoes.length,
              echoes,
              insertedAt: w.insertedAt
            }
          }),
        myPrivateWishes: state.wishes
          .filter((w) => w.visibility === 'private' && !w.deleted)
          .map((w) => {
            return {
              id: w.id,
              content: w.content,
              city: w.city,
              wisherMasked: null,
              endorsementCount: 0,
              endorsedByMe: false,
              mine: true,
              comments: [],
              latestEcho: null,
              echoCount: 0,
              echoes: [],
              insertedAt: w.insertedAt
            }
          }),
        myWishQuotaRemaining: wishQuotaRemaining(state),
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
          appliedAt: '2014-01-11T13:06:00+08:00',
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
        need: typeof input.need === 'string' ? input.need : state.today.need,
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
        // 提交即覆盖（对齐后端 tokens.ex：resolver 把缺省与 null 一律传成 nil，
        // attribute 允许 nil → Ash 照写即清空）。所以前端**关档时也带现有区间
        // 原值回写**，圈选才保得住；真清空 = 提交空数组（等价 null）。
        chosenQuoteSpans: spans ?? []
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
  // ── wish2 U9（#790 补齐）：愿望写面四 mutation + 期待/举报 + viewer 读面 ──

  if (document.includes('mutation FlashbackCreateWish')) {
    const state = flashbackState()
    if (wishQuotaRemaining(state) === 0) {
      return { errors: [{ message: '今年的许愿名额已用完（每年最多 3 条）。', code: 'flashback_wish_quota_exceeded' }] }
    }
    const visibility: 'public' | 'private' = values.visibility === 'private' ? 'private' : 'public'
    const id = `mw-${state.wishes.length + 1}`
    const wish = {
      id,
      content: String(values.content ?? ''),
      visibility,
      city: typeof values.expectedCity === 'string' && values.expectedCity ? values.expectedCity : '北京',
      signature: values.signatureChoice === 'display_name' ? '王小明' : '王**',
      insertedAt: new Date().toISOString(),
      deleted: false,
      mine: true,
      // #837 新许愿无回响;由后续 admin 流程再加
      echoes: []
    }
    updateFlashbackState((s) => ({ ...s, wishes: [wish, ...state.wishes] }))
    // wish2 U10：三态返回——公开+consent=listed（mock 无信用门），private=private
    const status = visibility === 'public' && values.publicListingConsent === true ? 'listed' : 'private'
    return { flashbackCreateWish: { id, endorsementCount: 0, endorsedByMe: false, status } }
  }
  if (document.includes('query FlashbackCities')) {
    // wish2 U10（KTD11）：期望地候选名单——名单样例子集（真源 flashbackCities）
    return {
      flashbackCities: [
        { name: '北京', fullName: '北京市', pinyin: 'beijing', lngLat: [116.407, 39.904] },
        { name: '上海', fullName: '上海市', pinyin: 'shanghai', lngLat: [121.474, 31.23] },
        { name: '成都', fullName: '成都市', pinyin: 'chengdu', lngLat: [104.066, 30.572] },
        { name: '广州', fullName: '广州市', pinyin: 'guangzhou', lngLat: [113.264, 23.129] },
        { name: '深圳', fullName: '深圳市', pinyin: 'shenzhen', lngLat: [114.058, 22.543] },
        { name: '杭州', fullName: '杭州市', pinyin: 'hangzhou', lngLat: [120.155, 30.274] },
        { name: '武汉', fullName: '武汉市', pinyin: 'wuhan', lngLat: [114.306, 30.593] },
        { name: '西安', fullName: '西安市', pinyin: 'xian', lngLat: [108.94, 34.341] }
      ]
    }
  }
  if (document.includes('mutation FlashbackEndorseWish')) {
    // 幂等 add-only（与后端 endorse_by_user 同义：重复附议 UPDATE 不双计）；
    // 取消只走独立 FlashbackCancelEndorseWish（下方已有 handler）
    const state = flashbackState()
    const wishId = String(values.wishId ?? '')
    const has = state.endorsedWishIds.includes(wishId)
    const next = updateFlashbackState((s) => ({
      ...s,
      endorsedWishIds: has ? s.endorsedWishIds : [...s.endorsedWishIds, wishId]
    }))
    return { flashbackEndorseWish: { endorsementCount: wishEndorsementCount(next, wishId), endorsedByMe: true } }
  }
  if (document.includes('mutation FlashbackCancelEndorseWish')) {
    const state = flashbackState()
    const wishId = String(values.wishId ?? '')
    const next = updateFlashbackState((s) => ({
      ...s,
      endorsedWishIds: state.endorsedWishIds.filter((id) => id !== wishId)
    }))
    return { flashbackCancelEndorseWish: { endorsementCount: wishEndorsementCount(next, wishId), endorsedByMe: false } }
  }
  if (document.includes('mutation FlashbackAddWishComment')) {
    const state = flashbackState()
    const wishId = String(values.wishId ?? '')
    const comments = state.wishComments[wishId] ?? []
    updateFlashbackState((s) => ({
      ...s,
      wishComments: {
        ...s.wishComments,
        [wishId]: [...comments, { id: `mc-${comments.length + 1}`, content: String(values.content ?? ''), insertedAt: new Date().toISOString() }]
      }
    }))
    return { flashbackAddWishComment: { endorsementCount: wishEndorsementCount(flashbackState(), wishId), endorsedByMe: flashbackState().endorsedWishIds.includes(wishId) } }
  }
  if (document.includes('mutation FlashbackDeleteWish')) {
    const state = flashbackState()
    const wishId = String(values.wishId ?? '')
    if (!state.wishes.some((wish) => wish.id === wishId && wish.mine && !wish.deleted)) {
      return { errors: [{ message: '只有本人可以删除自己的愿望', code: 'flashback_wish_not_owned' }] }
    }
    updateFlashbackState((s) => ({
      ...s,
      wishes: state.wishes.map((w) => (w.id === wishId ? { ...w, deleted: true } : w))
    }))
    return { flashbackDeleteWish: true }
  }
  if (document.includes('mutation FlashbackExpectWish')) {
    const state = flashbackState()
    const wishId = String(values.wishId ?? '')
    const expected = values.expected === true
    const has = state.expectedWishIds.includes(wishId)
    const next = expected
      ? has
        ? state.expectedWishIds
        : [...state.expectedWishIds, wishId]
      : state.expectedWishIds.filter((id) => id !== wishId)
    updateFlashbackState((s) => ({ ...s, expectedWishIds: next }))
    // per-wish 计数（mock 基础 2 条样例期待 + 本人对该 wish 的 0/1）
    const base = 2
    const mine = next.includes(wishId)
    return { flashbackExpectWish: { expectationCount: base + (mine ? 1 : 0), expectedByMe: mine } }
  }
  if (document.includes('mutation FlashbackReportWish')) {
    return { flashbackReportWish: { reportId: `rep-${Date.now()}`, status: 'pending' } }
  }
  if (document.includes('query FlashbackPublicWishes')) {
    const state = flashbackState()
    const cityFilter = typeof values.city === 'string' && values.city ? values.city : null
    return {
      flashbackPublicWishes: state.wishes
        .filter((w) => w.visibility === 'public' && !w.deleted && (!cityFilter || w.city === cityFilter))
        .map((w) => {
          // #837 回响投影对齐 real 读面:latestEcho/echoCount/echoes
          const echoes = w.echoes ?? []
          return {
            id: w.id,
            content: w.content,
            city: w.city,
            signature: w.signature,
            expectationCount: state.expectedWishIds.includes(w.id) ? 1 : 0,
            endorsementCount: state.endorsedWishIds.includes(w.id) ? 1 : 0,
            contributionDistribution: {},
            expectedByViewer: state.expectedWishIds.includes(w.id),
            endorsedByViewer: state.endorsedWishIds.includes(w.id),
            latestEcho: echoes.length > 0 ? echoes[echoes.length - 1] : null,
            echoCount: echoes.length,
            echoes,
            listedAt: w.insertedAt,
            insertedAt: w.insertedAt
          }
        })
    }
  }
  if (document.includes('mutation FlashbackSetCardSharing')) {
    // #771：本人可调开关。要求登录（会话腿）或有效 token（链接腿）——匿名不给
    // 任何写面。开启时**首次**生成 shareId，之后复用；关闭只清 enabled，
    // **保留 shareId**（ADR-0014：发布即锁死，重开同一 id）。
    const token = typeof values.token === 'string' && values.token ? values.token : null
    if (!loggedIn && !token) {
      return { errors: [{ message: 'token or sign-in required', code: 'flashback_auth_required' }] }
    }
    // 已作废的首程链接（claim 之后）不构成写权限——与 capsule token 腿同规则
    if (token && flashbackClaimedTokens.has(token)) {
      return { errors: [{ message: 'token claimed', code: 'flashback_token_claimed' }] }
    }
    const enabled = values.enabled === true
    const next = updateFlashbackState((state) => ({
      ...state,
      cardSharing: {
        enabled,
        // shareId 只在**首次开启**时生成（后端口径：从未开启过时恒 null）。
        // 因此「从未开过的人点关闭」必须保持 null，不能凭空铸一个 id——
        // 铸了就等于宣告「这个人开过」，而分享链接本不该存在。
        shareId: enabled ? (state.cardSharing.shareId ?? newShareId()) : state.cardSharing.shareId
      }
    }))
    return {
      flashbackSetCardSharing: {
        enabled: next.cardSharing.enabled,
        shareId: next.cardSharing.shareId,
        preview: flashbackSharedCard(next)
      }
    }
  }

  if (document.includes('query FlashbackSharedCard')) {
    // #771 匿名公开读面：无 token、无 slug、无 auth——朋友拿到链接就能读。
    // 只有「开着且有 id」才出卡；未开启/未知 id/已关闭一律 null（合法空态）。
    const state = flashbackState()
    const shareId = typeof values.shareId === 'string' ? values.shareId : ''
    if (!state.cardSharing.enabled || !state.cardSharing.shareId || shareId !== state.cardSharing.shareId) {
      return { flashbackSharedCard: null }
    }
    return { flashbackSharedCard: flashbackSharedCard(state) }
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
