/** Deterministic WeChat simulator acceptance. Build CGC_E2E_MOCK=true first.
 * Uses synthetic public data; never reads or changes login credentials. */
import { spawnSync } from 'node:child_process'
import { readFileSync, mkdirSync, writeFileSync } from 'node:fs'
import { resolve, dirname } from 'node:path'
import { fileURLToPath } from 'node:url'
const project=resolve(dirname(fileURLToPath(import.meta.url)), '..')
const evidence=resolve(project,'e2e/artifacts/voices')
mkdirSync(evidence,{recursive:true})
const log=[]
let lastCall = 0
function call(tool,args=[]){
  // DevTools limits calls to 60/min; pace deterministically instead of retrying errors.
  const pause = 1500 - (Date.now() - lastCall)
  if (pause > 0) Atomics.wait(new Int32Array(new SharedArrayBuffer(4)), 0, 0, pause)
  lastCall = Date.now()
  const result=spawnSync('wechatide',['-c','Codex',tool,'--project',project,...args],{encoding:'utf8',timeout:30000})
  const raw=result.stdout||'';const start=raw.indexOf('{')
  if(result.status!==0||start<0)throw new Error(`${tool} failed (${result.error?.message ?? result.status}): ${raw} ${result.stderr}`)
  const data=JSON.parse(raw.slice(start));if(!data.ok||data.result?.success===false)throw new Error(`${tool}: ${JSON.stringify(data)}`)
  return data.result
}
const cls=(page,name)=>'.'+readFileSync(resolve(project,`dist/weapp/pages/${page}/index.wxss`),'utf8').match(new RegExp(`index-module__${name}___[A-Za-z0-9_]+`))[0]
const common=name=>'.'+readFileSync(resolve(project,'dist/weapp/common.wxss'),'utf8').match(new RegExp(`index-module__${name}___[A-Za-z0-9_]+`))[0]
const city=name=>'.'+(readFileSync(resolve(project,'dist/weapp/common.wxss'),'utf8')+readFileSync(resolve(project,'dist/weapp/pages/flashback-voices/index.wxss'),'utf8')).match(new RegExp(`city-filter-module__${name}___[A-Za-z0-9_]+`))[0]
const voice=name=>cls('flashback-voices',name)
const text=selector=>call('automation_element_action',['--action','text','--selector',selector,'--wait-for-selector',selector])
const waitText=(selector,predicate)=>{
  for(let attempt=0;attempt<5;attempt++){const value=text(selector);if(predicate(value))return value}
  throw new Error(`Text did not settle: ${selector}`)
}
const tap=selector=>call('automation_element_action',['--action','tap','--selector',selector,'--wait-for-selector',selector])
const navigate=url=>call('automation_navigate',['--action','reLaunch','--url',url])
const check=(name,value)=>{if(!value)throw new Error(name);log.push(`PASS ${name}`);console.log(log.at(-1))}
const evaluate=fn=>call('automation_evaluate',['--fn-source',fn]).result.result
if (process.argv.includes('--live')) {
  await verifyLive()
} else {
navigate('/pages/flashback-voices/index')
check('anonymous public sentence',text(voice('quote')).includes('我不会'))
check('initial count',text(voice('likeButton')).includes('32'))
tap(voice('likeButton'));check('like increments',text(voice('likeButton')).includes('33'))
call('automation_element_action',['--action','tap','--selector',voice('likeButton'),'--wait','2']);check('unlike restores',text(voice('likeButton')).includes('32'))
tap(voice('next'));check('next sentence',text(voice('quote')).includes('一群女生'))
tap(voice('previous'));check('previous sentence',text(voice('quote')).includes('我不会'))
tap(voice('random'));check('random includes less popular voice',text(voice('quote')).includes('允许自己'))
tap(city('allCitiesButton'));tap('#voice-grid-2')
check('server city filter',text(voice('quote')).includes('一群女生'))
tap(city('allCitiesButton'));tap('#voice-grid-0')
tap(voice('next'))
const share=evaluate('function(){return getCurrentPages().slice(-1)[0].onShareAppMessage({from:"button",target:{dataset:{scope:"quote"}}})}')
check('share direct quote only',share.path==='/pages/flashback-voices/index?quoteId=voice-chengdu')
const wallShare=evaluate('function(){return getCurrentPages().slice(-1)[0].onShareAppMessage({from:"button",target:{dataset:{scope:"wall"}}})}')
check('whole-wall path has no credentials',wallShare.path==='/pages/flashback-voices/index')
navigate(share.path);check('shared quote direct landing',text(voice('quote')).includes('一群女生'))
navigate('/pages/flashback-voices/index?quoteId=voice-quiet');check('share outside hottest list',text(voice('quote')).includes('允许自己'))
navigate('/pages/flashback-voices/index?quoteId=withdrawn');check('withdrawn quote terminal state',text(voice('gone')).includes('已经收回'))
tap(voice('primary'));check('continue from withdrawn to wall',text(voice('quote')).includes('我不会'))
evaluate('function(){wx.setStorageSync("cgc.e2e.voices.fail-next-read",true);return true}')
navigate('/pages/flashback-voices/index')
check('network failure does not leave stale quote',text(common('message')).includes('网络中断'))
// PageState component error CTA has a shared hashed class; resolve its only error button.
tap(common('retry'));check('retry succeeds',text(voice('quote')).includes('我不会'))
call('simulator_screenshot',['--path',resolve(evidence,'voices.png')])
navigate('/pages/flashback-shared-card/index?shareId=closed')
tap(cls('flashback-shared-card','voicesLink'));check('closed personal card continues to voices',text(voice('quote')).includes('我不会'))
call('automation_navigate',['--action','switchTab','--url','/pages/flashback-corridor/index'])
// Guests have no shutter; returning mock members may have one.
const shutter=cls('flashback-corridor','shutterBtn')
if(call('automation_page_action',['--action','querySelectorAll','--selector',shutter]).elements.length)tap(shutter)
tap(call('automation_page_action',['--action','querySelectorAll','--selector',cls('flashback-corridor','guestPage')]).elements.length ? cls('flashback-corridor','voicesPortal') : cls('flashback-corridor','voicesEntry'));check('existing corridor links to wall',text(voice('quote')).includes('我不会'))
call('simulator_screenshot',['--path',resolve(evidence,'final-wall.png')])
}
writeFileSync(resolve(evidence,process.argv.includes('--live') ? 'live-result.txt' : 'result.txt'),log.join('\n')+'\n')
console.log(`${log.length} assertions passed; ${evidence}`)


/** A real transport check against synthetic fixtures in the isolated local server. */
async function verifyLive() {
  const endpoint = 'http://127.0.0.1:4107/api/graphql'
  const query = async (document, variables = {}) => {
    const response = await fetch(endpoint, { method: 'POST', headers: { 'Content-Type': 'application/json' }, body: JSON.stringify({ query: document, variables }) })
    const body = await response.json()
    if (!response.ok || body.errors) throw new Error('Local GraphQL verification failed')
    return body.data
  }
  const list = async city => (await query('query($city: String) { flashbackPublicQuotes(city: $city) { quoteId text city likeCount } }', { city })).flashbackPublicQuotes
  let [sample] = await list('北京')
  if (!sample?.text.includes('我不会')) throw new Error('Requires synthetic voices fixtures in local worktree database')
  const path = `/pages/flashback-voices/index?quoteId=${sample.quoteId}`
  navigate(path)
  if (text(voice('likeButton')).includes('♥')) {
    tap(voice('likeButton'))
    waitText(voice('likeButton'), value => value.includes('♡'))
    ;[sample] = await list('北京')
  }
  check('live public quote matches HTTP response', text(voice('quote')) === sample.text)
  check('live count matches HTTP response', text(voice('likeButton')).includes(String(sample.likeCount)))
  tap(voice('likeButton'))
  waitText(voice('likeButton'), value => value.includes('♥'))
  check('live like persisted on server', (await list('北京'))[0].likeCount === sample.likeCount + 1)
  navigate(path)
  check('live reload preserves count', text(voice('likeButton')).includes(String(sample.likeCount + 1)))
  check('live reload preserves viewer vote', text(voice('likeButton')).includes('♥'))
  tap(voice('likeButton'))
  waitText(voice('likeButton'), value => value.includes('♡'))
  check('live unlike persisted on server', (await list('北京'))[0].likeCount === sample.likeCount)
  const { flashbackVoiceCities } = await query('{ flashbackVoiceCities { name } }')
  const cityIndex = flashbackVoiceCities.findIndex(city => city.name === '成都') + 1
  if (!cityIndex) throw new Error('Chengdu missing from public voice cities')
  tap(city('allCitiesButton'));tap(`#voice-grid-${cityIndex}`)
  const [chengdu] = await list('成都')
  check('live city filter matches HTTP response', text(voice('quote')) === chengdu.text)
  const shared = evaluate('function(){return getCurrentPages().slice(-1)[0].onShareAppMessage({from:"button",target:{dataset:{scope:"quote"}}})}')
  check('live share identifies selected quote', shared.path === `/pages/flashback-voices/index?quoteId=${chengdu.quoteId}`)
  navigate(shared.path)
  check('live shared quote opens directly', text(voice('quote')) === chengdu.text)
  navigate('/pages/flashback-voices/index?quoteId=00000000-0000-0000-0000-000000000000')
  check('live missing quote gives terminal state', text(voice('gone')).includes('已经收回'))
  tap(voice('primary'))
  tap(voice('recover'))
  call('simulator_screenshot',['--path',resolve(evidence,'live-corridor.png')])
  tap(call('automation_page_action',['--action','querySelectorAll','--selector',cls('flashback-corridor','guestPage')]).elements.length ? cls('flashback-corridor','voicesPortal') : cls('flashback-corridor','voicesEntry'))
  check('live original corridor entry remains usable', text(voice('quote')).length > 0)
  navigate(path)
  call('simulator_screenshot',['--path',resolve(evidence,'live-wall.png')])
}
