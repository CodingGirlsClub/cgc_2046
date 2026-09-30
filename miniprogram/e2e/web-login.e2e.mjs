/** CGC_E2E_MOCK UI acceptance. Requires a compiled, open and ready WechatIDE window; no phone API or publishing. */
import { execFileSync } from 'node:child_process'
import { readFileSync } from 'node:fs'
import { fileURLToPath } from 'node:url'
import { join, resolve } from 'node:path'
import assert from 'node:assert/strict'

// WechatIDE keys runtime sessions by project path; never alternate a trailing slash.
const root = resolve(fileURLToPath(new URL('../', import.meta.url)))
const client = process.env.CGC_WECHATIDE_CLIENT || 'Codex'
function tool(name, args = []) {
  const raw = execFileSync('wechatide', ['-c', client, name, '--project', root, ...args], { encoding: 'utf8', timeout: 60000 })
  const result = JSON.parse(raw)
  assert.equal(result.ok, true, `${name}: ${result.message || 'failed'}`)
  assert.equal(result.result?.success, true, `${name} needs user confirmation or failed`)
  return result.result
}
function selector(page, name) {
  const css = readFileSync(join(root, 'dist/weapp/pages', page, 'index.wxss'), 'utf8')
  const matches = [...new Set([...css.matchAll(new RegExp(`\\.([\\w-]*__${name}___[\\w-]+)`, 'g'))].map(m => m[1]))]
  assert.equal(matches.length, 1, `unique class required: ${page}/${name}`)
  return `.${matches[0]}`
}
function texts() {
  const data = tool('automation_page_action', ['--action', 'getData', '--wait', '0.2']).data
  const values = []
  function walk(node) {
    if (!node || typeof node !== 'object') return
    if (typeof node.v === 'string') values.push(node.v)
    for (const value of Object.values(node)) if (typeof value === 'object') walk(value)
  }
  walk(data)
  return values.join('\n')
}
function waitText(text) {
  for (let i = 0; i < 20; i++) { const value = texts(); if (value.includes(text)) return value }
  throw new Error(`Expected visible text: ${text}`)
}
function tap(page, name) {
  const css = selector(page, name)
  tool('automation_element_action', ['--selector', css, '--action', 'tap', '--wait-for-selector', css])
}

// Initializer owns opening/compilation. Reopening here can invalidate the active runtime bridge.
tool('automation_navigate', ['--action', 'reLaunch', '--url', '/pages/web-login/index?requestId=abcdefghijklmnopqrstuv'])
let body = waitText('仅确认你本人刚刚发起的登录。')
assert.ok(!body.includes('已确认登录'))
if (body.includes('手机号快捷登录') || body.includes('当前账号')) {
  tap('web-login', body.includes('当前账号') ? 'secondary' : 'primary')
  waitText('手机号快捷登录')
  tap('login', 'loginButton')
  body = texts()
  if (body.includes('隐私授权说明')) tap('login', 'dialogPrimary')
}
waitText('当前账号')
assert.ok(!texts().includes('已确认登录'), 'account login alone must not approve the browser')
tap('web-login', 'primary')
waitText('已确认登录')
const confirmed = tool('simulator_screenshot', ['--path', '/tmp/cgc-mini-web-confirmed.jpg']).path
tool('automation_navigate', ['--action', 'reLaunch', '--url', '/pages/web-login/index?requestId=bcdefghijklmnopqrstuvw'])
waitText('当前账号')
tap('web-login', 'cancel')
waitText('已取消确认')
const cancelled = tool('simulator_screenshot', ['--path', '/tmp/cgc-mini-web-cancelled.jpg']).path
console.log(JSON.stringify({ pass: true, cases: ['explicit approval', 'login return', 'fresh request', 'cancel'], screenshots: [confirmed, cancelled] }))
