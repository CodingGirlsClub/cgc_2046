// #232: start from backend with PORT=4232 mix run --no-start --no-halt ../miniprogram/e2e/fixtures/notification-inbox.exs.
// Build CGC_GRAPHQL_ENDPOINT=http://127.0.0.1:4232/api/graphql CGC_E2E_MOCK=false for --live.
// For --mock build CGC_E2E_MOCK=true. Only synthetic fixtures; never print session values.
import assert from 'node:assert/strict'
import { spawnSync } from 'node:child_process'
import { readFileSync, mkdirSync, writeFileSync } from 'node:fs'
import { dirname, resolve } from 'node:path'
import { fileURLToPath } from 'node:url'

const project = resolve(dirname(fileURLToPath(import.meta.url)), '..')
const evidence = '/tmp/232-evidence'
mkdirSync(evidence, { recursive: true })
const live = process.argv.includes('--live')
assert(live || process.argv.includes('--mock'), 'Choose --live or --mock explicitly')
let lastCall = 0
const log = []
function call(tool, args = []) {
  const pause = 1500 - (Date.now() - lastCall)
  if (pause > 0) Atomics.wait(new Int32Array(new SharedArrayBuffer(4)), 0, 0, pause)
  lastCall = Date.now()
  const output = spawnSync('wechatide', ['-c', 'OMP', tool, '--project', project, ...args], { encoding: 'utf8', timeout: 30000 })
  const start = output.stdout.indexOf('{')
  if (output.status !== 0 || start < 0) throw new Error(`DevTools ${tool} failed, exit ${output.status}: ${output.stdout.slice(start)}`)
  const data = JSON.parse(output.stdout.slice(start))
  if (!data.ok || data.result?.success === false) throw new Error(`DevTools ${tool} rejected the operation`)
  return data.result
}
function evaluate(source) { return call('automation_evaluate', ['--fn-source', source]).result.result }
function cls(name, page = 'profile') {
  const path = page === 'common' ? 'common.wxss' : `pages/${page}/index.wxss`
  const matches = [...new Set(readFileSync(resolve(project, 'dist/weapp', path), 'utf8').match(new RegExp(`index-module__${name}___[A-Za-z0-9_]+`, 'g')) ?? [])]
  assert.equal(matches.length, 1, `Unique CSS-module anchor ${name}`)
  return '.' + matches[0]
}
function text(selector) { return call('automation_element_action', ['--action', 'text', '--selector', selector, '--wait-for-selector', selector]) }
function tap(selector) { call('automation_element_action', ['--action', 'tap', '--selector', selector, '--wait-for-selector', selector]) }
function count(selector) { return call('automation_page_action', ['--action', 'querySelectorAll', '--selector', selector]).elements.length }
function check(name, condition) { assert(condition, name); log.push(`PASS ${name}`); console.log(log[log.length - 1]) }
function showProfile() { call('automation_navigate', ['--action', 'switchTab', '--url', '/pages/profile/index', '--wait-for-selector', 'view']) }
function screenshot(name) { call('simulator_screenshot', ['--path', resolve(evidence, name + '.png'), '--wait-for-selector', cls('inbox')]) }
function bootstrap(account) {
  if (!live) {
    evaluate(`function(){wx.setStorageSync('cgc.e2e.platform_identity','1');wx.setStorageSync('cgc.e2e.notification_account_b','${account === 'b' ? '1' : '0'}');wx.removeStorageSync('cgc.auth_token');return true}`)
    call('simulator_refresh')
    call('automation_navigate', ['--action', 'reLaunch', '--url', '/pages/login/index', '--wait-for-selector', 'view'])
    // Mock platform login uses the existing login button + agreement flow.
    tap(cls('loginButton', 'login'))
    if (count(cls('dialogPrimary', 'login'))) tap(cls('dialogPrimary', 'login'))
    check(`mock account ${account} signed in`, evaluate("function(){return !!wx.getStorageSync('cgc.auth_token')}"))
    return
  }
  const result = evaluate(`function(){return new Promise(function(resolve){wx.request({url:'http://127.0.0.1:4232/api/graphql',method:'POST',data:{query:'mutation { signIn(login: "inbox-232-${account}@example.test", password: "sup3r-secret-password") { id } }'},success:function(r){var cookies=(r.cookies||[]).concat(r.header['set-cookie']||r.header['Set-Cookie']||[]);var found=cookies.map(function(c){return /cgc_token=([^;,]+)/.exec(c)}).find(Boolean);if(found&&!r.data.errors){wx.setStorageSync('cgc.auth_token',decodeURIComponent(found[1]));resolve({signedIn:true,status:r.statusCode})}else resolve({signedIn:false,status:r.statusCode})},fail:function(){resolve({signedIn:false,status:0})}})})}`)
  check(`synthetic account ${account} signed in through real HTTP`, result.signedIn && result.status === 200)
  call('simulator_refresh')
}

try {
  bootstrap('a')
  showProfile()
  const inbox = cls('inbox')
  const item = cls('notification')
  const mark = cls('markButton')
  const read = cls('read')
  check('first page has exactly 20 server records', count(item) === 20)
  check('accepted-not-delivered label is visible', text(inbox).includes('不代表渠道已送达'))
  const beforeRead = count(read)
  tap(mark)
  check('mark acknowledgement changes visible read state', count(read) === beforeRead + 1)
  tap(cls('more'))
  check('next page appends without duplicate records', count(item) === (live ? 27 : 23))
  screenshot(live ? 'live-inbox' : 'mock-inbox')
  evaluate("function(){var id=wx.getStorageSync('cgc.active_user_id');wx.removeStorageSync('cgc.notification_feed.v1.'+id);return true}")
  call('simulator_refresh')
  showProfile()
  check('fresh cache still reloads server history', count(item) === 20 && count(read) > 0)

  if (live) {
    evaluate("function(){globalThis.__inboxOriginalRequest=wx.request;wx.request=function(opts){if(String(opts.data&&opts.data.query).includes('query NotificationFeed')){var success=opts.success;opts.success=function(r){globalThis.__inboxRelease=function(){success(r)}}}return globalThis.__inboxOriginalRequest(opts)};return true}")
    tap(cls('refresh'))
    check('loading is visible while genuine HTTP result is held', text(inbox).includes('正在加载') && count(item) === 0)
    screenshot('live-loading')
    evaluate("function(){wx.request=globalThis.__inboxOriginalRequest;delete globalThis.__inboxOriginalRequest;globalThis.__inboxRelease();delete globalThis.__inboxRelease;return true}")
    check('held HTTP completion renders real records', count(item) === 20)
    // Fail only feed transport in the current simulator; no production state is injected.
    evaluate("function(){globalThis.__inboxOriginalRequest=wx.request;wx.request=function(opts){if(String(opts.data&&opts.data.query).includes('query NotificationFeed')){opts.fail&&opts.fail({errMsg:'request:fail synthetic offline'});return {abort:function(){}}}return globalThis.__inboxOriginalRequest(opts)};return true}")
    tap(cls('refresh'))
    check('offline uses explicitly labelled same-account cache', text(inbox).includes('缓存记录'))
    screenshot('live-cache-fallback')
    evaluate("function(){wx.request=globalThis.__inboxOriginalRequest;delete globalThis.__inboxOriginalRequest;return true}")
    tap(cls('refresh'))
    check('retry returns to server source', !text(inbox).includes('缓存记录'))
    tap(cls('viewButton'))
    check('safe local link opens existing enrollment page', evaluate("function(){return getCurrentPages().slice(-1)[0].route}") === 'pages/my-enrollments/index')
    showProfile()
  } else {
    evaluate("function(){wx.setStorageSync('cgc.e2e.notification_feed_error','1');return true}")
    tap(cls('more'))
    check('load-more failure preserves existing rows', count(item) === 20 && text(inbox).includes('重试加载更多'))
    evaluate("function(){wx.removeStorageSync('cgc.e2e.notification_feed_error');return true}")
    tap(cls('more'))
    check('load-more retry appends remaining records', count(item) === 23)
    evaluate("function(){wx.setStorageSync('cgc.e2e.notification_feed_error','1');return true}")
    tap(cls('refresh'))
    check('feed error has retry state', text(inbox).includes('通知加载失败'))
    evaluate("function(){wx.removeStorageSync('cgc.e2e.notification_feed_error');return true}")
    tap(cls('refresh'))
    check('error retry restores real rows', count(item) === 20)
    evaluate("function(){wx.setStorageSync('cgc.e2e.notification_mark_error','1');return true}")
    const unread = count(cls('unread'))
    tap(mark)
    check('failed mark remains unread', count(cls('unread')) === unread)
    evaluate("function(){wx.removeStorageSync('cgc.e2e.notification_mark_error');return true}")
    tap(mark)
    check('mark retry succeeds', count(cls('unread')) === unread - 1)
    evaluate("function(){wx.setStorageSync('cgc.e2e.notification_feed_empty','1');return true}")
    tap(cls('refresh'))
    check('empty state is not an error or stale history', count(item) === 0 && text(inbox).includes('最近 30 天暂无通知'))
    screenshot('mock-empty')
    evaluate("function(){wx.removeStorageSync('cgc.e2e.notification_feed_empty');return true}")
  }
  if (live) {
    evaluate("function(){globalThis.__inboxOriginalRequest=wx.request;wx.request=function(opts){if(String(opts.data&&opts.data.query).includes('query NotificationFeed')){var success=opts.success;opts.success=function(r){globalThis.__inboxRelease=function(){success(r)}}}return globalThis.__inboxOriginalRequest(opts)};return true}")
    tap(cls('refresh'))
    check('logout race starts with an actual in-flight feed', text(inbox).includes('正在加载'))
  }
  tap(cls('logout', 'profile'))
  if (live) {
    evaluate("function(){wx.request=globalThis.__inboxOriginalRequest;delete globalThis.__inboxOriginalRequest;globalThis.__inboxRelease();delete globalThis.__inboxRelease;return true}")
    check('late A response cannot restore the logged-out inbox', count(item) === 0)
  }
  check('logout removes account cache and UI', evaluate("function(){return !wx.getStorageSync('cgc.active_user_id')&&!wx.getStorageSync('cgc.auth_token')}") && count(item) === 0)
  bootstrap('b')
  showProfile()
  check('account B has only its own notification', count(item) === 1 && text(inbox).includes(live ? '账号 B 的活动' : '账号 B 报名成功') && !text(inbox).includes('通知验收活动'))
  screenshot(live ? 'live-account-b' : 'mock-account-b')
} finally {
  evaluate("function(){if(globalThis.__inboxOriginalRequest){wx.request=globalThis.__inboxOriginalRequest;delete globalThis.__inboxOriginalRequest}delete globalThis.__inboxRelease;return true}")
  writeFileSync(resolve(evidence, live ? 'gui-live.log' : 'gui-mock.log'), log.join('\n') + '\n')
}
console.log(`GUI ${live ? 'LIVE' : 'MOCK'} PASS: ${log.length} assertions`)
