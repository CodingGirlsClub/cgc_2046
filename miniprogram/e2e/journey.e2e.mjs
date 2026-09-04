import assert from 'node:assert/strict'
import { existsSync } from 'node:fs'
import { dirname, resolve } from 'node:path'
import { fileURLToPath } from 'node:url'
import automator from 'miniprogram-automator'

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

let assertionCount = 0

async function expectText(page, selector, expected) {
  const element = await page.$(selector)
  assert.ok(element, `缺少元素 ${selector}`)
  assert.match(await element.text(), expected)
  assertionCount += 1
  return element
}

async function tap(page, selector) {
  const element = await page.$(selector)
  assert.ok(element, `缺少可点击元素 ${selector}`)
  await element.tap()
  await page.waitFor(120)
  return element
}

async function run() {
  const miniProgram = await automator.launch({ cliPath, projectPath })

  try {
    let page = await miniProgram.reLaunch('/pages/discover/index')
    await page.waitFor(200)
    await expectText(page, '[data-testid="page-title"]', /^发现$/)
    await expectText(page, '[data-testid="visitor-state"]', /登录后可报名/)

    await tap(page, '[data-testid="event-card-event-1"]')
    page = await miniProgram.currentPage()
    await expectText(page, '[data-testid="detail-title"]', /Python 入门工作坊/)
    await expectText(page, '[data-testid="schema-field-audience"]', /零基础学习者/)

    await tap(page, '[data-testid="register-action"]')
    page = await miniProgram.currentPage()
    await expectText(page, '[data-testid="login-title"]', /手机号一键登录/)
    await tap(page, '[data-testid="platform-login"]')

    page = await miniProgram.currentPage()
    await expectText(page, '[data-testid="register-title"]', /确认报名/)
    // 一键报名（对齐 web）：登录即身份,无姓名/邮箱/理由表单
    await tap(page, '[data-testid="submit-enrollment"]')

    page = await miniProgram.currentPage()
    await expectText(page, '[data-testid="enrollment-result"]', /等待审批/)
    await tap(page, '[data-testid="subscribe-result"]')
    await expectText(page, '[data-testid="subscription-state"]', /已订阅审批结果通知/)

    page = await miniProgram.switchTab('/pages/my-enrollments/index')
    await expectText(page, '[data-testid="enrollment-enrollment-1"]', /等待审批/)

    page = await miniProgram.switchTab('/pages/workspace/index')
    await expectText(page, '[data-testid="urgent-summary"]', /24 小时内过期/)
    await tap(page, '[data-testid="approve-enrollment-1"]')
    await expectText(page, '[data-testid="approval-empty"]', /暂无待审批/)

    page = await miniProgram.switchTab('/pages/profile/index')
    await expectText(page, '[data-testid="notification-list"]', /审批已完成/)

    assert.equal(assertionCount, 12)
    console.log(`E2E PASS: ${assertionCount} 条页面/状态断言`)
  } finally {
    await miniProgram.close()
  }
}

await run()
