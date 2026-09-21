import { readFileSync } from 'node:fs'
import { join } from 'node:path'

/**
 * E2E 选择器锚点表（#579）。
 *
 * Taro 4 weapp 运行时不把 data-testid 渲染进 WXML（渲染树只有 id/class/data-sid），
 * 且 miniprogram-automator 的 page.$ 只支持 WXSS 选择器子集——属性选择器不可用。
 * 因此 e2e 锚点一律用 CSS-module 类名；哈希随样式内容变，运行时从 dist 产物解析，
 * 绝不写死。CI 侧由 scripts/check-anchors.mjs 在构建后逐锚静态自检（本表单源共用）。
 *
 * 锚点键沿用旧 data-testid 名，便于历史对照；每项 = [wxss 路径（相对 dist/weapp）, module 类名]。
 * 解析源分两类：
 * - 页面样式 → pages/<page>/index.wxss（同页同名类只有一个哈希）
 * - 组件公共块 → common.wxss（Taro 把 AppTabBar/PageState 等非页面组件的样式打进这里）
 *
 * 锚点纪律（增删必读）：
 * - 只选语义稳定的 module 类；不选原子/状态类（urgentText、tierActive 这类纯样式态）
 * - tap 锚必须在渲染树上唯一（page.$ 取首个匹配，多匹配 = 点错不报错）
 * - 列表锚依赖 mockTransport 数据顺序（event-1 = records[0]、待审批唯一项 = 刚提交
 *   的 enrollment），改 mock 顺序需同步 journey.e2e.mjs
 */
export const ANCHORS = {
  // discover
  'page-title': ['pages/discover/index.wxss', 'title'],
  'visitor-state': ['pages/discover/index.wxss', 'visitor'],
  // 注意：initiative 卡复用 contentCard（组合类），journey 里按卡片文本挑 event 卡
  'event-card-event-1': ['pages/discover/index.wxss', 'contentCard'],
  // event-detail：schema-field-audience 已随页面重构删除（受众字段不再展示），
  // 改钉成班徽章（domain qualificationBadgeText：short_by → 「还差 N 人成班」）
  'detail-title': ['pages/event-detail/index.wxss', 'title'],
  'qualification-badge': ['pages/event-detail/index.wxss', 'qualificationBadge'],
  'register-action': ['pages/event-detail/index.wxss', 'primaryButton'],
  // 活动介绍块（无介绍的场不渲染——锚点仅供静态自检与有介绍 fixture 的 e2e 使用）
  'detail-description': ['pages/event-detail/index.wxss', 'descriptionPara'],
  // login（协议弹窗在 mask 上）
  'login-title': ['pages/login/index.wxss', 'title'],
  'platform-login': ['pages/login/index.wxss', 'loginButton'],
  'agree-dialog': ['pages/login/index.wxss', 'dialogMask'],
  'agree-login': ['pages/login/index.wxss', 'dialogPrimary'],
  // register-form
  'register-title': ['pages/register-form/index.wxss', 'formTitle'],
  'submit-enrollment': ['pages/register-form/index.wxss', 'primaryButton'],
  // enrollment-result
  'enrollment-result': ['pages/enrollment-result/index.wxss', 'title'],
  'subscribe-result': ['pages/enrollment-result/index.wxss', 'subscribeButton'],
  'subscription-state': ['pages/enrollment-result/index.wxss', 'subscriptionState'],
  // my-enrollments（列表唯一项 = 刚提交的 enrollment）
  'enrollment-enrollment-1': ['pages/my-enrollments/index.wxss', 'card'],
  // workspace
  'urgent-summary': ['pages/workspace/index.wxss', 'approvalSummary'],
  'approve-enrollment-1': ['pages/workspace/index.wxss', 'approve'],
  'approval-empty': ['common.wxss', 'state'], // PageState 根类（公共样式块）
  // profile（通知面板 = 本页首个 panel）
  'notification-list': ['pages/profile/index.wxss', 'panel'],
  // profile 页内入口卡（「我的报名」「去 OpenClacky」同款组合类）——journey 按卡片文本挑
  'profile-entry-card': ['pages/profile/index.wxss', 'openclacky']
}

// 同一 wxss 供多个锚点共用（discover 3 锚等），内容按路径缓存
const wxssCache = new Map()

function readWxss(wxssPath) {
  if (!wxssCache.has(wxssPath)) {
    try {
      wxssCache.set(wxssPath, readFileSync(wxssPath, 'utf8'))
    } catch {
      throw new Error(
        `锚点解析：读不到 ${wxssPath}——先构建（CGC_E2E_MOCK=true taro build --type weapp）`
      )
    }
  }
  return wxssCache.get(wxssPath)
}

/** 把锚点表解析成 { 锚点键: 类选择器 }；任何一个锚点不可唯一定位都直接抛错。 */
export function resolveAnchorSelectors(distRoot) {
  const selectors = {}
  for (const [key, [source, className]] of Object.entries(ANCHORS)) {
    if (!/^[A-Za-z0-9_-]+$/.test(className)) {
      throw new Error(`锚点 ${key}：类名 ${className} 不是合法的 module 导出名`)
    }
    const wxssPath = join(distRoot, source)
    const css = readWxss(wxssPath)
    const hashes = [
      ...new Set(css.match(new RegExp(`index-module__${className}___[A-Za-z0-9_]+`, 'g')) ?? [])
    ]
    if (hashes.length === 0) {
      throw new Error(
        `锚点 ${key}：${source} 里找不到类名 ${className}——样式改名后请同步 e2e/anchors.mjs`
      )
    }
    if (hashes.length > 1) {
      throw new Error(
        `锚点 ${key}：${source} 里类名 ${className} 有 ${hashes.length} 个哈希（${hashes.join(', ')}），无法唯一定位——换锚点`
      )
    }
    selectors[key] = `.${hashes[0]}`
  }
  return selectors
}
