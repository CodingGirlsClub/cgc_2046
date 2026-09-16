import type { ContentKind, EnrollmentStatus, SubscriptionScenario } from './models'

/**
 * 订阅消息触点（#635）：把「在什么时刻请求哪些场景、说什么文案」从页面里下沉成
 * 纯数据 + 纯函数，供 `node --test` 钉住（小程序无页面渲染测试，见 AGENTS.md）。
 *
 * ## 微信硬约束（决定本文件形状）
 *
 * - `requestSubscribeMessage` **一次最多 3 个 tmplIds** → 每个时刻的场景集 ≤ 3；
 * - **必须由用户点击或支付回调触发** → 所有触点都是显式按钮，没有任何自动弹窗，
 *   因此「拒绝后不再骚扰」是结构性成立的：用户不点就不会被问；
 * - 一次性订阅 = **一次授权换一条消息**（后端 `Consent` grant +1 / take −1），
 *   故同一时刻把「可能触发」的场景一次问齐更划算；未消耗的授权结转到下一条消息。
 *
 * ## 覆盖缺口（有意为之，勿默默补齐）
 *
 * - `speaker_completed` 有**双受众**：管理者 + 分享者本人。小程序**没有任何分享者
 *   面**（无分享者 GraphQL 查询、无页面），故只有管理者腿有入口；分享者腿当前
 *   **无入口**，由后端 `consent_exhausted` 可观测性暴露（#635 C1）。
 * - `learning_stagnation` 的学习行为发生在 OpenClacky 桌面端（见 pages/openclacky），
 *   小程序内唯一近似落点是「我的报名」里的**课程**卡。
 * - `event_moderator_assigned` 有鸡生蛋问题：用户正是通过该通知才首次得知被指派，
 *   故**第一次指派必然送不到**；M5 覆盖的是「已是某活动主理人者订阅后续指派」。
 */

/** 全部订阅场景。与 models.ts 的 SubscriptionScenario 联合、config/index.ts 的 WECHAT_SCENARIOS 三者双射（守卫测试钉住）。 */
export const ALL_SCENARIOS = [
  'approval_result',
  'approval_reminder',
  'event_reminder',
  'event_qualification_confirmed',
  'event_qualification_underfilled',
  'event_schedule_changed',
  'event_moderator_assigned',
  'speaker_accepted',
  'speaker_completed',
  'learning_stagnation'
] as const satisfies readonly SubscriptionScenario[]

/** 微信单次 `tmplIds` 上限（官方文档：一次调用最多可订阅 3 条消息）。 */
export const MAX_TMPL_IDS_PER_REQUEST = 3

export interface SubscriptionTouchpoint {
  /** 触点页面（产品语义文档面；一个时刻一处） */
  page: string
  /** 触发动作（必须是用户手势——微信硬约束） */
  trigger: string
  /** 按钮文案 */
  label: string
  /** 该时刻请求的场景集（≤ MAX_TMPL_IDS_PER_REQUEST） */
  scenarios: SubscriptionScenario[]
  /** 至少一个场景被接受后的提示 */
  acceptedCopy: string
  /** 全部被拒/未授权后的提示（按钮保留，用户可再点，故不写「不可再订阅」） */
  deniedCopy: string
}

/**
 * M1 报名结果页（pages/enrollment-result）——**刚提交完报名**，用户最想知道
 * 「我进了吗 / 开得成吗 / 会不会取消」，三问恰好用满单次上限 3。
 *
 * 两种状态**不设触点**：
 * - `rejected`/`expired`/`cancelled`：报名已终结，再问授权是打扰（既有实现也会
 *   渲染按钮并错配 `event_reminder`，此处一并修正）；
 * - `payment_pending`：仍待付款，此刻问授权为时过早——既有实现正是用
 *   `!paymentPending` 隐藏入口，本函数保持该口径。该状态用户在**支付成功页**
 *   （pages/order-pay）会被问 `event_reminder`；付款后回本页或「我的报名」即成
 *   `confirmed`，届时可问齐。
 */
export function enrollmentResultTouchpoint(
  status: EnrollmentStatus
): SubscriptionTouchpoint | null {
  if (status === 'rejected' || status === 'expired' || status === 'cancelled') return null
  if (status === 'payment_pending') return null

  const pending = status === 'pending'

  return {
    page: 'pages/enrollment-result/index',
    trigger: '报名提交后进入结果页，点按订阅按钮',
    // 文案按状态分派：审批中要的是「进展」，已通过要的是「开班与活动变动」，
    // 用一句通用文案会在已通过时误导（审批早已结束）。
    label: pending ? '订阅报名进展通知' : '订阅开班与活动提醒',
    scenarios: [pending ? 'approval_result' : 'event_reminder', 'event_qualification_confirmed', 'event_qualification_underfilled'],
    acceptedCopy: pending ? '已订阅，报名进展会通知你' : '已订阅，开班与活动变动会通知你',
    deniedCopy: '你暂未授权，可稍后在「我的报名」再次订阅'
  }
}

/**
 * M2 我的报名 · **活动**卡（pages/my-enrollments）与活动详情页（已报名者）——
 * 已报名者关心「什么时候开始 / 时间地点变了没有」。
 */
export function eventCardTouchpoint(): SubscriptionTouchpoint {
  return {
    page: 'pages/my-enrollments/index（活动卡）、pages/event-detail/index（已报名）',
    trigger: '已报名用户点按订阅按钮',
    label: '订阅活动变更提醒',
    scenarios: ['event_reminder', 'event_schedule_changed'],
    acceptedCopy: '已订阅活动变更提醒',
    deniedCopy: '你暂未授权，可稍后再试'
  }
}

/**
 * M3 我的报名 · **课程**卡——小程序内唯一能看到课程报名的地方，是
 * `learning_stagnation` 唯一近似落点（学习本身在 OpenClacky 桌面端）。
 *
 * 顺带修正既有错配：课程卡此前渲染「订阅活动提醒」并请求 `event_reminder`，
 * 而课程报名不会收到该模板（后端 `learning_stagnation` 才是课程侧提醒）。
 */
export function courseCardTouchpoint(): SubscriptionTouchpoint {
  return {
    page: 'pages/my-enrollments/index（课程卡）',
    trigger: '课程报名已确认的用户点按订阅按钮',
    label: '订阅学习提醒',
    scenarios: ['learning_stagnation'],
    acceptedCopy: '已订阅，学习进度停滞时会提醒你',
    deniedCopy: '你暂未授权，可稍后再试'
  }
}

/** 按报名条目类型分派 M2/M3（活动 → 变更提醒；课程 → 学习提醒）。 */
export function enrollmentCardTouchpoint(kind: ContentKind): SubscriptionTouchpoint {
  return kind === 'course' ? courseCardTouchpoint() : eventCardTouchpoint()
}

/**
 * M4 工作台（pages/workspace）——三个**管理者收件人**模板的落页
 * （后端 `client.ex` `@manager_templates` + `speaker_completed` 管理者腿）。
 * 恰好用满单次上限 3。入口只需 `manageable`，不要求当前有待审批项
 * （既有实现额外要求 `approvals.length > 0`，空队列时管理者无法订阅）。
 */
export function workspaceTouchpoint(): SubscriptionTouchpoint {
  return {
    page: 'pages/workspace/index',
    trigger: 'Owner/Admin 打开工作台，点按订阅按钮',
    label: '订阅团队协作通知',
    scenarios: ['approval_reminder', 'speaker_accepted', 'speaker_completed'],
    acceptedCopy: '已订阅团队协作通知',
    deniedCopy: '你暂未授权，可稍后再试'
  }
}

/**
 * M5 活动详情页 · 主理人（pages/event-detail，仅 `canModerateEvent()` 为真时渲染）
 * ——唯一能证明「我是主理人」的页面，也是该模板自身的深链落页。
 */
export function moderatorTouchpoint(): SubscriptionTouchpoint {
  return {
    page: 'pages/event-detail/index（canCheckIn 为真）',
    trigger: '主理人打开自己主理的活动详情页，点按订阅按钮',
    label: '订阅主理人指派通知',
    scenarios: ['event_moderator_assigned'],
    acceptedCopy: '已订阅，被指派为新活动主理人时会通知你',
    deniedCopy: '你暂未授权，可稍后再试'
  }
}

// --- 请求期 fail-closed（纯函数，页面/transport 只做调起） ---------------------

/** 订阅消息的调起平台。 */
export type SubscriptionPlatform = 'wechat' | 'tt' | 'xhs'

/**
 * 请求路径选择。
 *
 * - `passthrough`：**不经过微信 tmplIds**——E2E mock 构建（不触达微信 API）与
 *   小红书（服务通知由平台后台规则下发，无前端授权弹窗）都属此类，请求的
 *   场景全部视为已授权；
 * - `tmplIds`：微信/抖音真机路径，需按模板 ID 过滤后调起 `requestSubscribeMessage`。
 *
 * ⚠ 这条优先级必须**先于**「模板 ID 是否配置」的判断：mock 构建与 CI 都没有
 * 真实模板 ID，若先做缺配检查，mock 下点订阅会抛「缺少模板 ID」而不是成功。
 * 拆成纯函数正是为了让这条顺序可被 `tests/subscription-domain.test.ts` 钉住
 * ——它此前只存在于 `platform/index.ts` 的语句顺序里，改动顺序不会被任何测试发现。
 */
export function subscriptionTransport(
  isE2eMock: boolean,
  platform: SubscriptionPlatform
): 'passthrough' | 'tmplIds' {
  return isE2eMock || platform === 'xhs' ? 'passthrough' : 'tmplIds'
}

/**
 * 剔除未配置模板 ID 的场景。**这是 fail-closed 的关键**：构建缺配时模板 ID 是空串，
 * 空串递给 `requestSubscribeMessage` 会让整次调用失败或错配模板——宁可少问一个场景。
 */
export function configuredScenarios(
  scenarios: SubscriptionScenario[],
  templateIds: Record<string, string>
): SubscriptionScenario[] {
  return scenarios.filter((scenario) => (templateIds[scenario] ?? '') !== '')
}

/**
 * 从微信回调里挑出被接受的场景。
 *
 * `requested` 与 `tmplIds` 是**同序平行数组**（由 configuredScenarios 过滤后 map
 * 得到），故用下标取 `result[tmplIds[i]]` 严格对应 `requested[i]`——部分配置时
 * 不会把「A 的 accept」错记到「B 的场景」上（错配会让后端给错的 template_key
 * 加配额，即静默发错模板）。
 *
 * 结果值：`accept` / `reject` / `ban`（平台封禁），仅 `accept` 计入。
 */
export function acceptedScenarios(
  requested: SubscriptionScenario[],
  tmplIds: string[],
  result: Record<string, string>
): SubscriptionScenario[] {
  return requested.filter((_scenario, index) => result[tmplIds[index]] === 'accept')
}
