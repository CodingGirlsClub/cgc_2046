// Native acceptance for a large city set. Seed fixtures/voices-cities.exs first.
import { spawnSync } from 'node:child_process'
import { readFileSync, mkdirSync, writeFileSync } from 'node:fs'
import { resolve, dirname } from 'node:path'
import { fileURLToPath } from 'node:url'
const project = resolve(dirname(fileURLToPath(import.meta.url)), '..')
const output = resolve(project, 'e2e/artifacts/voices/cities')
mkdirSync(output, { recursive: true })
let last = 0
// Independent entry point intentionally keeps its small paced CLI harness local.
function call(tool, args = []) {
  const pause = 1500 - (Date.now() - last)
  if (pause > 0) Atomics.wait(new Int32Array(new SharedArrayBuffer(4)), 0, 0, pause)
  last = Date.now()
  const result = spawnSync('wechatide', ['-c','Codex',tool,'--project',project,...args], { encoding:'utf8',timeout:30000 })
  const raw = result.stdout ?? ''
  if (result.status !== 0) throw new Error(`${tool}: ${raw} ${result.stderr}`)
  const data = JSON.parse(raw.slice(raw.indexOf('{')))
  if (!data.ok || data.result?.success === false) throw new Error(raw)
  return data.result
}
const css = readFileSync(resolve(project,'dist/weapp/common.wxss'),'utf8')
const pageCss = readFileSync(resolve(project,'dist/weapp/pages/flashback-voices/index.wxss'),'utf8')
const city = name => '.'+(css+pageCss).match(new RegExp(`city-filter-module__${name}___[A-Za-z0-9_]+`))[0]
const voice = name => '.'+pageCss.match(new RegExp(`index-module__${name}___[A-Za-z0-9_]+`))[0]
const text = selector => call('automation_element_action',['--action','text','--selector',selector,'--wait-for-selector',selector])
const tap = selector => call('automation_element_action',['--action','tap','--selector',selector,'--wait-for-selector',selector])
const elements = selector => call('automation_page_action',['--action','querySelectorAll','--selector',selector]).elements
const evaluate = fn => call('automation_evaluate',['--fn-source',fn]).result.result
const rects = selectors => evaluate(`function(){return new Promise(resolve=>{const q=wx.createSelectorQuery();${JSON.stringify(selectors)}.forEach(s=>q.select(s).boundingClientRect());q.exec(resolve)})}`)
const log = []
const check = (label, condition) => { if(!condition)throw new Error(label);log.push(`PASS ${label}`);console.log(log.at(-1)) }
const body = await fetch('http://127.0.0.1:4107/api/graphql',{method:'POST',headers:{'Content-Type':'application/json'},body:JSON.stringify({query:'{ flashbackVoiceCities { name pinyin } }'})}).then(r=>r.json())
const cities = body.data.flashbackVoiceCities
check('30 real public cities', cities.length === 30)
check('stable pinyin order', cities.every((city,index)=>!index || city.pinyin >= cities[index-1].pinyin))
call('automation_navigate',['--action','reLaunch','--url','/pages/flashback-voices/index'])
text(voice('quote'))
check('default filter is all', text(city('activeChip')) === '全部')
tap(voice('next'))
check('changing quote keeps all filter', text(city('activeChip')) === '全部')
const [fixedBefore] = rects([city('allCitiesButton')])
call('automation_element_action',['--action','scrollTo','--selector',city('cityStrip'),'--x','2400','--y','0'])
const [fixedAfter] = rects([city('allCitiesButton')])
check('all cities stays fixed during horizontal scrolling', Math.abs(fixedBefore.left-fixedAfter.left)<1)
tap(city('allCitiesButton'))
check('panel exposes all 30 cities plus all', elements(city('gridCity')).length === 31)
const cells = rects(['#voice-grid-0','#voice-grid-1','#voice-grid-2','#voice-grid-3','#voice-grid-4'])
check('panel is a four-column grid', cells.slice(0,4).every(cell=>Math.abs(cell.top-cells[0].top)<1) && cells[4].top>cells[0].bottom)
call('automation_element_action',['--action','scrollTo','--selector',city('cityGridScroll'),'--y','900','--x','0'])
tap('#voice-grid-30')
check('last city selected and panel closes', text(city('activeChip')) === cities[29].name && elements(city('citySheet')).length === 0)
check('selected city filters real quote', text(voice('attribution')).includes(cities[29].name))
const [active, strip] = rects([city('activeChip'),city('cityStrip')])
check('selected city scrolls into visible strip', active.left>=strip.left-1 && active.right<=strip.right+1)
tap(city('allCitiesButton'))
check('panel selection matches strip', text(city('activeGridCity')) === cities[29].name)
tap(city('closeCities'))
check('closing panel preserves selection', text(city('activeChip')) === cities[29].name)
tap(city('allCitiesButton'))
call('automation_element_action',['--action','scrollTo','--selector',city('cityGridScroll'),'--y','0','--x','0'])
tap('#voice-grid-0')
check('all clears city filter', text(city('activeChip')) === '全部')
tap(voice('random'))
check('random browsing leaves all filter selected', text(city('activeChip')) === '全部')
tap(city('allCitiesButton'))
writeFileSync(resolve(output,'result.txt'),log.join('\n')+'\n')
console.log(`${log.length} checks passed`)
