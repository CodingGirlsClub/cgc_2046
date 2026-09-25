import test from 'node:test'
import assert from 'node:assert/strict'
import { selectVoice, moveVoice, mergeVoices, voiceShare, type PublicVoice } from '../src/domain/flashback-voices.ts'
import { resolveEntry } from '../src/domain/share-route.ts'
const a: PublicVoice = { quoteId:'a', text:'一句公开的话', attribution:'王** · 北京', city:'北京', year:2014, likeCount:3, likedByViewer:false, level:'anonymous', publicSlug:null }
const b = { ...a, quoteId:'b', city:'成都' }
test('指定句子撤回时不能偷偷显示其他句子', () => {
  assert.equal(selectVoice([a], 'gone'), null)
  assert.equal(selectVoice([a], null)?.quoteId, 'a')
  assert.equal(selectVoice([], null), null)
})
test('换句循环；随机追加去重且不重排当前批次', () => {
  assert.equal(moveVoice([a,b], 'a', -1), 'b')
  assert.equal(moveVoice([], null, 1), null)
  assert.deepEqual(mergeVoices([a], [a,b]).map(x=>x.quoteId), ['a','b'])
})
test('分享只携带公开定位参数', () => {
  assert.deepEqual(voiceShare(a), { title:'闪念间 · 一句公开的话', path:'/pages/flashback-voices/index?quoteId=a', query:'quoteId=a' })
  assert.equal(voiceShare(null).path, '/pages/flashback-voices/index')
  assert.equal(voiceShare(null).query, '')
})
test('冷启动不叠页；热启动换句；丢弃夹带 token', () => {
  const path='pages/flashback-voices/index'
  assert.equal(resolveEntry({path,query:{quoteId:'a'}}, []).navigate,false)
  const result=resolveEntry({path,query:{quoteId:'b',token:'private'}}, [{route:path,options:{quoteId:'a'}}])
  assert.equal(result.navigate,true)
  assert.equal(result.url,'/pages/flashback-voices/index?quoteId=b')
  assert.equal(resolveEntry({path,query:{quoteId:'a'}}, [{route:path,options:{quoteId:'a'}}]).url,null)
})
test('热启动整墙分享会离开原来的单句，不会留在旧内容', () => {
  const path='pages/flashback-voices/index'
  const result=resolveEntry({path,query:{}}, [{route:path,options:{quoteId:'a'}}])
  assert.equal(result.navigate,true)
  assert.equal(result.url,'/pages/flashback-voices/index')
})
test('从其他页面热启动整墙分享会进入金句墙', () => {
  const result = resolveEntry({ path: 'pages/flashback-voices/index', query: {} }, [{ route: 'pages/discover/index' }])
  assert.equal(result.navigate, true)
  assert.equal(result.url, '/pages/flashback-voices/index')
})
