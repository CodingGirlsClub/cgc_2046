// Measure actual native WeChat text layout against local synthetic fixtures.
import { spawnSync } from 'node:child_process'
import { readFileSync, mkdirSync, writeFileSync } from 'node:fs'
import { resolve, dirname } from 'node:path'
import { fileURLToPath } from 'node:url'
const project = resolve(dirname(fileURLToPath(import.meta.url)), '..')
const output = resolve(project, 'e2e/artifacts/voices/layout')
mkdirSync(output, { recursive: true })
let last = 0
function call(tool, args = []) {
  const pause = 1500 - (Date.now() - last)
  if (pause > 0) Atomics.wait(new Int32Array(new SharedArrayBuffer(4)), 0, 0, pause)
  last = Date.now()
  const result = spawnSync('wechatide', ['-c', 'Codex', tool, '--project', project, ...args], { encoding: 'utf8', timeout: 30000 })
  const raw = result.stdout ?? ''
  if (result.status !== 0) throw new Error(`${tool}: ${raw} ${result.stderr}`)
  const data = JSON.parse(raw.slice(raw.indexOf('{')))
  if (!data.ok || data.result?.success === false) throw new Error(raw)
  return data.result
}
const css = readFileSync(resolve(project, 'dist/weapp/pages/flashback-voices/index.wxss'), 'utf8')
const selector = name => '.' + css.match(new RegExp(`index-module__${name}___[A-Za-z0-9_]+`))[0]
const query = await fetch('http://127.0.0.1:4107/api/graphql', {
  method: 'POST', headers: { 'Content-Type': 'application/json' },
  body: JSON.stringify({ query: '{ flashbackPublicQuotes(city:"广州") { quoteId text attribution } }' })
}).then(result => result.json())
const samples = query.data?.flashbackPublicQuotes?.filter(row => row.attribution.startsWith('排**')).sort((a,b) => a.text.length - b.text.length)
if (samples?.length !== 4) throw new Error('Seed voices-layout.exs in the isolated local backend first')
const names = ['reader', 'quote', 'meta', 'shareQuote', 'actions', 'random', 'consent', 'pager', 'footer']
const selectors = names.map(selector)
const measures = []
for (const sample of samples) {
  call('automation_navigate', ['--action', 'reLaunch', '--url', `/pages/flashback-voices/index?quoteId=${sample.quoteId}`])
  const rendered = call('automation_element_action', ['--action','text','--selector',selector('quote'),'--wait-for-selector',selector('quote')])
  if (rendered !== sample.text) throw new Error('Quote text was clipped or changed')
  call('automation_viewport_action', ['--action','pageScrollTo','--scroll-top','0'])
  const result = call('automation_evaluate', ['--fn-source', `function(){return new Promise(resolve=>{const q=wx.createSelectorQuery();${JSON.stringify(selectors)}.forEach(s=>q.select(s).fields({rect:true,size:true,computedStyle:['fontSize','lineHeight','whiteSpace','overflow']}));q.exec(rects=>resolve({window:wx.getWindowInfo(),rects}));})}`]).result.result
  const rects = Object.fromEntries(names.map((name,i) => [name, result.rects[i]]))
  const quote = rects.quote
  const lines = Math.round(quote.height / parseFloat(quote.lineHeight))
  if (rects.meta.top < quote.bottom || rects.actions.top < rects.meta.bottom) throw new Error('Long text overlaps controls')
  if (rects.consent.height > parseFloat(rects.consent.lineHeight) + 1) throw new Error('Consent is not one line')
  if (rects.shareQuote.bottom > rects.random.top + 1) throw new Error('Share is not above random CTA')
  const row = { chars: [...sample.text].length, lines, windowWidth: result.window.windowWidth, windowHeight: result.window.windowHeight, rects }
  measures.push(row)
  call('simulator_screenshot', ['--path',resolve(output, `${row.chars}-top.png`)])
  call('automation_viewport_action', ['--action','pageScrollTo','--scroll-top',String(Math.max(0, rects.reader.top-16))])
  call('simulator_screenshot', ['--path',resolve(output, `${row.chars}-reader.png`),'--wait','0.5'])
  console.log(JSON.stringify({chars:row.chars,lines,width:row.windowWidth,viewport:row.windowHeight,quoteHeight:quote.height,actionBottom:rects.actions.bottom}))
}
writeFileSync(resolve(output, 'measurements.json'), JSON.stringify(measures,null,2))
// The promoted CTA still performs random browsing; the quiet button still shares a quote.
call('automation_element_action', ['--action','tap','--selector',selector('random'),'--wait-for-selector',selector('random')])
call('automation_element_action', ['--action','text','--selector',selector('quote'),'--wait-for-selector',selector('quote')])
const share = call('automation_evaluate', ['--fn-source', 'function(){return getCurrentPages().slice(-1)[0].onShareAppMessage({from:"button",target:{dataset:{scope:"quote"}}})}']).result.result
if (!share.path?.startsWith('/pages/flashback-voices/index?quoteId=')) throw new Error('Quote sharing lost its public target')
console.log('PASS promoted random CTA and quote sharing')
// Leave the representative medium-length sample open for human acceptance.
call('automation_navigate', ['--action','reLaunch','--url',`/pages/flashback-voices/index?quoteId=${samples[1].quoteId}`])
console.log('PASS 4 complete texts, no overlap, single-line consent, share above random CTA')
