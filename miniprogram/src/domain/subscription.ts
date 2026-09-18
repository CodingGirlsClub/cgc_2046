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
 * - `event_moderator_assigned` / `event_moderator_removed`（#538）有鸡生蛋问题：
 *   用户正是通过 assigned 通知才首次得知被指派，故**第一次指派必然送不到**；
 *   removed 同构——未点过 M5 就被移除的那条也送不到。M5 双键覆盖的是
 *   「当前是主理人者」订阅后续指派与移除（移除授权必须发生在移除前，唯一
 *   能提前授权的人 = 当前主理人，故扩 M5 而非新触点；M8 已 3/3 满且面向
 *   Owner/Admin，被移除者通常是普通成员）。
 * - `refund_succeeded` / `refund_failed` / `payment_expired` 有**双受众**（付款人 +
 *   管理者/发起人）：付款人腿由 M7 付费卡覆盖（#683）；**管理者腿无小程序入口**
 *   ——最佳授权时刻是「管理员点退款时的顺手授权」，但小程序无退款操作面
 *   （refundOrder 仅 web/GraphQL），留待后续 issue。先例 = speaker_completed
 *   分享者腿，由后端 `consent_exhausted` 可观测性暴露。
 * - `enrollment_completed` 的 **web 报名腿无授权路径**：微信一次性订阅只能在微信
 *   内发起（`grantMiniProgramNotificationConsent` 只在小程序），web 报名的用户
 *   仍收不到——已知残余缺口（记录在 #664 / #683），不可由小程序场景闭合。
 */

/** 全部订阅场景。与 models.ts 的 SubscriptionScenario 联合、config/index.ts 的 WECHAT_SCENARIOS 三者双射（守卫测试钉住）。 */
export const ALL_SCENARIOS = [
  'approval_result',
  'approval_reminder',
  'event_reminder',
  'enrollment_completed',
  'enrollment_check_in_code',
  'event_qualification_confirmed',
  'event_qualification_underfilled',
  'event_qualification_manager',
  'event_schedule_changed',
  'event_moderator_assigned',
  'event_moderator_removed',
  'speaker_accepted',
  'speaker_completed',
  'learning_stagnation',
  'payment_succeeded',
  'payment_expired',
  'refund_succeeded',
  'refund_failed',
  'enrollment_submitted',
  'payment_received'
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
 * M0 报名表单（pages/register-form）· **提交前**——报名结果两条通知（#546 核销码
 * + #664 报名成功）唯一能赶在 `confirmed` 之前拿到授权的时刻。
 *
 * 一次性订阅 = 一次授权换一条消息（后端 Consent grant +1 / take −1）。两条通知
 * 的触发点是同一个「报名落 confirmed」信号（后端 `Subscriber.enqueue_completed/1`
 * 一次发两条），而免费 open 场 / 课程的 confirmed 与 createEnrollment **同一事务**
 * 落定 → 信号 → 入队 → 发送在数百毫秒内完成。结果页 / 我的报名 / 支付成功页上的
 * 任何后置触点都只能在**发送之后**拿到授权（`consent_exhausted` → discarded），
 * 首次报名必然收不到——这正是本触点必须前移到提交之前的原因（顺序判据由
 * submitAfterConsent 钉住）。
 *
 * 场景按报名类型分派（一次问齐，同刻触发的两条一起要）：
 * - 活动：报名成功 + 核销码（Event 报名有 6 位码，两条同刻下发）；
 * - 课程：仅报名成功（course 恒无码，后端不发核销码通知）。
 */
export function preSubmitTouchpoint(kind: ContentKind): SubscriptionTouchpoint {
  const isEvent = kind === 'event'

  return {
    page: 'pages/register-form/index（提交前）',
    trigger: '用户点按「确认报名」，先请求授权再提交报名请求',
    label: isEvent ? '订阅报名结果与核销码' : '订阅报名通知',
    scenarios: isEvent
      ? ['enrollment_completed', 'enrollment_check_in_code']
      : ['enrollment_completed'],
    acceptedCopy: isEvent ? '已订阅，报名结果与核销码会通知你' : '已订阅，报名结果会通知你',
    deniedCopy: '你暂未授权，可再试或在「我的报名」查看报名结果'
  }
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
    // 文案按状态分派：审批中要的是「进展」，已通过要的是「成班与活动变动」，
    // 用一句通用文案会在已通过时误导（审批早已结束）。
    label: pending ? '订阅报名进展通知' : '订阅成班与活动提醒',
    scenarios: [pending ? 'approval_result' : 'event_reminder', 'event_qualification_confirmed', 'event_qualification_underfilled'],
    acceptedCopy: pending ? '已订阅，报名进展会通知你' : '已订阅，成班与活动变动会通知你',
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
 * ——唯一能证明「我是主理人」的页面，也是两个主理人模板共同的深链落页。
 * #538 扩为双键（assigned + removed，2/3）：移除通知的受众 = 被移除者，授权
 * 必须发生在移除前，唯一入口就是本触点。
 */
export function moderatorTouchpoint(): SubscriptionTouchpoint {
  return {
    page: 'pages/event-detail/index（canCheckIn 为真）',
    trigger: '主理人打开自己主理的活动详情页，点按订阅按钮',
    label: '订阅主理人指派与变动通知',
    scenarios: ['event_moderator_assigned', 'event_moderator_removed'],
    acceptedCopy: '已订阅，主理人指派与变动会通知你',
    deniedCopy: '你暂未授权，可稍后再试'
  }
}
/**
 * M6 订单支付页（pages/order-pay）· **双态**——`payment_succeeded` 的授权时刻
 * （#683 收紧 2）。pending 态（「立即支付」旁）是唯一能赶在发送前的时刻：授权
 * 先落库（grant +1）→ 用户支付 → 渠道回调 → PaymentSettlementWorker 发送 →
 * Consent.take 命中，**首单即送达**。paid 态对「没授权就付了」的用户兜底：此刻
 * 发送与轮询确认几乎同刻，本单大概率已 discard，授权结转下一单（remaining_uses
 * 累积）。用户不点订阅直接付款 = 用户选择，非结构缺陷。
 *
 * 两态同一场景集（2/3）：支付凭证 + 活动提醒（付费活动的开始/改期同样关心，
 * 此前 paid 态本就单独问 event_reminder）。
 */
export function paymentResultTouchpoint(paid: boolean): SubscriptionTouchpoint {
  return {
    page: 'pages/order-pay/index（等待支付 + 支付成功）',
    trigger: '用户在支付页点按订阅按钮（付款前先授权，或付款后补授权）',
    label: paid ? '订阅支付与活动通知' : '订阅支付结果通知',
    scenarios: ['payment_succeeded', 'event_reminder'],
    acceptedCopy: '已订阅，支付结果与活动变动会通知你',
    deniedCopy: '你暂未授权，可再试或在「我的报名」查看支付记录'
  }
}

/**
 * M7 我的报名 · 付费卡（pages/my-enrollments）——资金类三键的付款人腿，恰好
 * 用满单次上限 3。渲染判据 = 该报名名下有「有缴费事实」订单（payment.ts 的
 * `paidEnrollmentIds`，白名单 paid/refunding/refunded/refund_failed/forfeited），
 * **不看 enrollment.status**：退款落定时报名可能已 cancelled，卡上仍可补授权
 * （配额结转下一次退款/下一单过期）。管理者腿缺口见 moduledoc。
 */
export function refundCardTouchpoint(): SubscriptionTouchpoint {
  return {
    page: 'pages/my-enrollments/index（付费报名卡）',
    trigger: '有缴费事实的用户点按订阅按钮',
    label: '订阅退款与订单变动通知',
    scenarios: ['refund_succeeded', 'refund_failed', 'payment_expired'],
    acceptedCopy: '已订阅，退款到账与订单变动会通知你',
    deniedCopy: '你暂未授权，可稍后再试或在「我的报名」查看退款进度'
  }
}

/**
 * M8 工作台（pages/workspace）· 第二订阅按钮——M4 用满 3 后的管理者增量
 * （#683 裁决 A：加按钮而非重组既有分组）。两键的深链落页都是工作台
 * （client.ex `@manager_templates`），按钮落在自己通知的落页上。渲染门同
 * M4：仅 `manageable`，不要求有待审批项。
 */
export function workspaceOpsTouchpoint(): SubscriptionTouchpoint {
  return {
    page: 'pages/workspace/index',
    trigger: 'Owner/Admin 打开工作台，点按第二个订阅按钮',
    label: '订阅新报名、收款与开班通知',
    scenarios: ['enrollment_submitted', 'payment_received', 'event_qualification_manager'],
    acceptedCopy: '已订阅，新报名、收款与开班结果会通知你',
    deniedCopy: '你暂未授权，可稍后再试'
  }
}

// --- 请求期 fail-closed（纯函数，页面/transport 只做调起） ---------------------

/**
 * #546/#664 顺序契约：报名结果通知的授权**必须先于报名提交**（理由见
 * preSubmitTouchpoint）。页面只做渲染与调起，顺序判据下沉到此——
 * 小程序无页面渲染测试（AGENTS.md），顺序只能靠纯函数 + `node --test` 钉住。
 *
 * 调用序：request（微信授权弹窗，同步进入用户手势栈）→ 逐个 grant（后端 +1
 * 配额）→ 最后 submit（可能立刻落 confirmed 并触发发送）。
 *
 * 授权被拒 / 模板未配置 / 平台报错一律**不阻断报名**：报名结果与核销码始终可在
 * 「我的报名」查看，通知只是顺手。
 */
export async function submitAfterConsent<T>(
  touchpoint: SubscriptionTouchpoint,
  deps: {
    request: (scenarios: SubscriptionScenario[]) => Promise<SubscriptionScenario[]>
    grant: (scenario: SubscriptionScenario) => Promise<unknown>
  },
  submit: () => Promise<T>
): Promise<T> {
  try {
    const accepted = await deps.request(touchpoint.scenarios)
    for (const scenario of accepted) await deps.grant(scenario)
  } catch {
    // 未授权不阻断报名（同上）
  }
  return submit()
}

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
