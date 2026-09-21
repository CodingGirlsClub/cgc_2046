import assert from 'node:assert/strict'
import { existsSync } from 'node:fs'
import { dirname, join, resolve } from 'node:path'
import { fileURLToPath } from 'node:url'
import automator from 'miniprogram-automator'
import { resolveAnchorSelectors } from './anchors.mjs'

const here = dirname(fileURLToPath(import.meta.url))
const projectPath = resolve(here, '..')
const cliCandidates = [
  process.env.CGC_WECHAT_DEVTOOLS_CLI,
  '/Applications/wechatwebdevtools.app/Contents/MacOS/cli',
  '/Applications/微信web开发者工具.app/Contents/MacOS/cli'
].filter(Boolean)
const cliPath = cliCandidates.find((candidate) => existsSync(candidate))

if (!cliPath) {
  throw new Error(
    '缺少微信开发者工具 CLI；请安装后设置 CGC_WECHAT_DEVTOOLS_CLI，再运行 pnpm e2e'
  )
}

// 选择器：CSS-module 类名，运行时从 dist/weapp 产物解析（#579：data-testid 不进渲染树）
const sel = resolveAnchorSelectors(join(projectPath, 'dist/weapp'))

// 分组计数：防「流程走岔导致某组断言没执行」的静默通过（比全局 >=N 严，比写死总数好维护）
const counts = {}
const EXPECTED_COUNTS = {
  discover: 2,
  detail: 2,
  login: 2,
  register: 1,
  result: 2,
  enrollments: 1,
  workspace: 2,
  profile: 1
}

const WAIT_MS = 5000

// 轮询等元素出现（页面数据加载/导航渲染都是异步，固定 sleep 永远在赌时序）
async function waitForElement(page, selector) {
  const deadline = Date.now() + WAIT_MS
  for (;;) {
    const element = await page.$(selector)
    if (element) return element
    if (Date.now() >= deadline) return null
    await page.waitFor(200)
  }
}

// tap 触发导航后等新页面就位（currentPage 在导航完成前返回的还是旧页）
async function awaitPage(miniProgram, pathPart) {
  const deadline = Date.now() + WAIT_MS
  for (;;) {
    const page = await miniProgram.currentPage()
    if (page.path.includes(pathPart)) return page
    if (Date.now() >= deadline) {
      throw new Error(`页面未跳转到 *${pathPart}*（当前 ${page.path}）`)
    }
    await page.waitFor(200)
  }
}

async function expectText(page, selector, expected, stage) {
  const element = await waitForElement(page, selector)
  assert.ok(element, `缺少元素 ${selector}`)
  assert.match(await element.text(), expected)
  counts[stage] = (counts[stage] ?? 0) + 1
  return element
}

// 等到本步要操作的元素出现再 tap（执行前等待，不是导航后等待）；
// tap 后的导航/弹窗/同页更新一律由 awaitPage / waitForElement 轮询兜底
async function tap(page, selector) {
  const element = await waitForElement(page, selector)
  assert.ok(element, `缺少可点击元素 ${selector}`)
  await element.tap()
  return element
}

// 列表卡选择：discover 的 initiative 卡复用 contentCard（无法用类名区分 event 卡），
// WXSS 选择器又没有 :not——按文本挑卡（与断言同款正则，选错卡=文本不匹配=红）
async function tapCardByText(page, selector, expected) {
  for (const card of await page.$$(selector)) {
    if (expected.test(await card.text())) {
      await card.tap()
      return card
    }
  }
  assert.fail(`缺少文本匹配 ${expected} 的卡片 ${selector}`)
}

async function run() {
  const miniProgram = await automator.launch({ cliPath, projectPath })

  try {
    let page = await miniProgram.reLaunch('/pages/discover/index')
    await expectText(page, sel['page-title'], /^发现$/, 'discover')
    await expectText(page, sel['visitor-state'], /登录后可报名/, 'discover')

    await tapCardByText(page, sel['event-card-event-1'], /Python 入门工作坊/)
    page = await awaitPage(miniProgram, 'pages/event-detail/index')
    await expectText(page, sel['detail-title'], /Python 入门工作坊/, 'detail')
    await expectText(page, sel['qualification-badge'], /还差 3 人成班/, 'detail')

    await tap(page, sel['register-action'])
    page = await awaitPage(miniProgram, 'pages/login/index')
    await expectText(page, sel['login-title'], /手机号快捷登录/, 'login')
    // 协议确认弹窗：点登录先弹窗，「同意并登录」才发起授权（同页弹层）
    await tap(page, sel['platform-login'])
    await expectText(page, sel['agree-dialog'], /隐私授权说明/, 'login')
    await tap(page, sel['agree-login'])

    page = await awaitPage(miniProgram, 'pages/register-form/index')
    await expectText(page, sel['register-title'], /确认报名/, 'register')
    // 一键报名（对齐 web）：登录即身份,无姓名/邮箱/理由表单
    await tap(page, sel['submit-enrollment'])

    page = await awaitPage(miniProgram, 'pages/enrollment-result/index')
    await expectText(page, sel['enrollment-result'], /等待审批/, 'result')
    await tap(page, sel['subscribe-result'])
    // M1 文案（#635）：pending 报名 → 按钮「订阅报名进展通知」→ 接受后「已订阅，报名进展会通知你」
    await expectText(page, sel['subscription-state'], /已订阅，报名进展会通知你/, 'result')

    // 我的报名已降为「我的」页内入口（原 tabBar 项）——从「我的」Tab 点卡片进入
    // （入口卡与「去 OpenClacky」等同款组合类，按卡片文本挑，同 discover 的 event 卡先例）
    page = await miniProgram.switchTab('/pages/profile/index')
    await tapCardByText(page, sel['profile-entry-card'], /查看报名与核销/)
    page = await awaitPage(miniProgram, 'pages/my-enrollments/index')
    await expectText(page, sel['enrollment-enrollment-1'], /等待审批/, 'enrollments')

    page = await miniProgram.switchTab('/pages/workspace/index')
    await expectText(page, sel['urgent-summary'], /24 小时内过期/, 'workspace')
    await tap(page, sel['approve-enrollment-1'])
    await expectText(page, sel['approval-empty'], /暂无待审批/, 'workspace')

    page = await miniProgram.switchTab('/pages/profile/index')
    await expectText(page, sel['notification-list'], /审批已完成/, 'profile')

    assert.deepEqual(counts, EXPECTED_COUNTS)
    const total = Object.values(counts).reduce((sum, n) => sum + n, 0)
    console.log(`E2E PASS: ${total} 条页面/状态断言`)
  } finally {
    await miniProgram.close()
  }
}

await run()
