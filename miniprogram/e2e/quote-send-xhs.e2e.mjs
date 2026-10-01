/**
 * 寄出选择在小红书 2.0 IDE 的回归。先用 CGC_E2E_MOCK=true taro build --type xhs，
 * 在 IDE 打开本 worktree 的 dist/xhs；XHS_CDP_PORT 指向 IDE 的 CDP 端口。
 * 操作 mp-service 的页面事件入口（Taro eh），不把 mp-render DOM 当作视觉证据。
 * 画面需另用窗口截图核对。本脚本只使用 mock 数据，不请求生产。
 */
import assert from 'node:assert/strict'

const port = process.env.XHS_CDP_PORT
if (!port) throw Error('Set XHS_CDP_PORT to the running IDE CDP port')
const targets = await (await fetch(`http://localhost:${port}/json/list`)).json()
// query 中也可能含 mp-service 扩展名，只匹配 pathname，避免误连 mp-render。
const target = targets.find(t => new URL(t.url).pathname.endsWith('/mp-service.html'))
if (!target) throw Error('Open the current worktree in the IDE first')
const ws = new WebSocket(target.webSocketDebuggerUrl)
await new Promise((resolve, reject) => { ws.onopen = resolve; ws.onerror = reject })
let id = 0
const pending = new Map()
ws.onmessage = e => {
  const message = JSON.parse(e.data)
  const callback = pending.get(message.id)
  if (callback) { pending.delete(message.id); callback(message) }
}
const evaluate = expression => new Promise((resolve, reject) => {
  const callId = ++id
  const timer = setTimeout(() => { pending.delete(callId); reject(Error('CDP timed out')) }, 5000)
  pending.set(callId, m => {
    clearTimeout(timer)
    if (m.error || m.result?.exceptionDetails) reject(Error(JSON.stringify(m.error ?? m.result.exceptionDetails)))
    else resolve(m.result.result.value)
  })
  ws.send(JSON.stringify({ id: callId, method: 'Runtime.evaluate', params: { expression, returnByValue: true, awaitPromise: true } }))
})
const nodes = `const p=getCurrentPages().at(-1);const all=[];const walk=n=>{all.push(n);(n.cn||[]).forEach(walk)};walk(p.data.root);`
const text = className => evaluate(`(()=>{${nodes}const n=all.find(n=>n.cl?.includes('__${className}___'));const txt=n=>(n?.v||'')+(n?.cn||[]).map(txt).join('');return n?txt(n):null})()`)
const waitFor = async className => {
  for (let i=0; i<80; i++) { const value = await text(className); if(value !== null) return value; await new Promise(r=>setTimeout(r,100)) }
  throw Error(`Missing CSS module node: ${className}`)
}
const event = (className, type='tap', detail={}) => evaluate(`(()=>{${nodes}const n=all.find(n=>n.cl?.includes('__${className}___'));if(!n)throw Error('Missing ${className}');p.eh({type:${JSON.stringify(type)},timeStamp:Date.now(),target:{id:n.sid,dataset:{sid:n.sid}},currentTarget:{id:n.sid,dataset:{sid:n.sid}},detail:${JSON.stringify(detail)}});return true})()`)

try {
  assert.equal(await evaluate('typeof getCurrentPages'), 'function')
  for (const withQuote of [false, true]) {
    await evaluate(`(()=>{wx.removeStorageSync('cgc.e2e.flashback_mock_state');wx.removeStorageSync('cgc.flashback_token');wx.reLaunch({url:'/pages/flashback-journey/index?token=e2e-flashback-token'});return true})()`)
    await waitFor('shutter'); await event('shutter')
    await waitFor('quizOption'); await event('quizOption')
    await waitFor('polaroid'); await event('polaroid')
    await waitFor('backTitle')
    await event('textarea', 'input', { value: 'CDP 寄出验收' })
    assert.equal(await waitFor('quoteChoiceWithQuote'), '寄出，并把这句匿名放进金句墙 →')
    assert.equal(await text('quoteChoiceAlbumOnly'), '寄出到相册')
    assert.equal(await text('quoteChoiceCite'), '王** · 2014 · 北京')
    assert.equal(await text('quoteChoiceText'), '「想亲眼看看是不是真的！」')
    if (withQuote) {
      await event('quoteChoiceShuffle')
      // React 的事件渲染异步提交；等到新预览后再寄出。
      for (let i=0;i<40 && (await text('quoteChoiceText'))!=='「后来我成了程序员。」';i++) await new Promise(r=>setTimeout(r,100))
      assert.equal(await text('quoteChoiceText'), '「后来我成了程序员。」')
    }
    await event(withQuote ? 'quoteChoiceWithQuote' : 'quoteChoiceAlbumOnly')
    await waitFor('overlayTitle')
    const state = await evaluate(`(()=>{const s=wx.getStorageSync('cgc.e2e.flashback_mock_state');return typeof s==='string'?JSON.parse(s):s})()`)
    assert.ok(state.today.sentToWallAt)
    assert.equal(state.today.nowStatus, 'CDP 寄出验收')
    assert.equal(state.quoteLevel, withQuote ? 'anonymous' : 'off')
    if (withQuote) {
      assert.deepEqual(state.chosenQuoteSpans, [{ questionKey: 'self_intro', start: 19, len: 9 }])
      assert.match(await text('overlayVoices'), /这句话已放进金句墙/)
    } else assert.equal(state.chosenQuoteSpans?.length ?? 0, 0)
    console.log(`PASS xhs: ${withQuote ? '寄出并匿名放句，所选句已保存' : '只寄出，不写授权'}`)
  }
} finally { ws.close() }
