import assert from 'node:assert/strict'
import { mkdirSync, mkdtempSync, rmSync, writeFileSync } from 'node:fs'
import { tmpdir } from 'node:os'
import { join } from 'node:path'
import test from 'node:test'
import { decodeTextEscapes, scanArtifactTree } from '../scripts/diversion-policy.mjs'

const SANDBOX = mkdtempSync(join(tmpdir(), 'diversion-policy-'))
test.after(() => rmSync(SANDBOX, { recursive: true, force: true }))

// 每个用例独立子目录，互不干扰；fixture 仅存在于系统临时目录，不进入 repo。
function makeCase(name, files) {
  const root = join(SANDBOX, name)
  mkdirSync(root, { recursive: true })
  for (const [rel, content] of Object.entries(files)) {
    const full = join(root, rel)
    mkdirSync(join(full, '..'), { recursive: true })
    writeFileSync(full, content, 'utf8')
  }
  return root
}

test('decodeTextEscapes 单轮解码 \\uXXXX（ASCII 与中文）', () => {
  assert.equal(decodeTextEscapes('\\u0057\\u0065\\u0043\\u0068\\u0061\\u0074'), 'WeChat')
  assert.equal(decodeTextEscapes('\\u5fae\\u4fe1'), '微信')
})

test('decodeTextEscapes 解码 \\u{...} 与 \\xNN', () => {
  assert.equal(decodeTextEscapes('\\u{5fae}\\u{4fe1}'), '微信')
  assert.equal(decodeTextEscapes('\\x57\\x65\\x43\\x68\\x61\\x74'), 'WeChat')
})

test('decodeTextEscapes 两轮覆盖双重转义', () => {
  assert.equal(decodeTextEscapes('\\\\u0057\\\\u0065\\\\u0043\\\\u0068\\\\u0061\\\\u0074'), 'WeChat')
})

test('普通无禁词的 JS/JSON/模板/样式组合通过且 filesScanned > 0', () => {
  const root = makeCase('pass-clean', {
    'pages/index/index.js': 'export default {}',
    'pages/index/index.json': '{"navigationBarTitleText":"活动"}',
    'pages/index/index.ttml': '<view>你好</view>',
    'pages/index/index.ttss': '.a{color:red}'
  })
  const r = scanArtifactTree(root)
  assert.equal(r.error, null)
  assert.ok(r.filesScanned > 0)
  assert.deepEqual(r.hits, [])
})

test('中文原文命中且只报相对路径与 term', () => {
  const root = makeCase('hit-zh', { 'app.js': '欢迎加入微信群' })
  const r = scanArtifactTree(root)
  assert.equal(r.error, null)
  assert.deepEqual(r.hits, [{ file: 'app.js', term: '微信' }])
})

test('ASCII term 保持精确大小写合同', () => {
  const root = makeCase('hit-ascii-case', {
    'w.js': 'wechat',
    'w2.js': 'WeChat'
  })
  const r = scanArtifactTree(root)
  assert.deepEqual(r.hits, [{ file: 'w2.js', term: 'WeChat' }])
})

test('\\uXXXX 转义的中文与 ASCII 均命中', () => {
  const root = makeCase('hit-u-esc', {
    'e.js': '\\u5fae\\u4fe1',
    'e2.json': '\\u0057\\u0065\\u0043\\u0068\\u0061\\u0074'
  })
  const r = scanArtifactTree(root)
  const sorted = [...r.hits].sort((a, b) => a.file.localeCompare(b.file))
  assert.deepEqual(sorted, [
    { file: 'e.js', term: '微信' },
    { file: 'e2.json', term: 'WeChat' }
  ])
})

test('双重转义后仍命中', () => {
  const root = makeCase('hit-double-esc', {
    'd.js': '\\\\u0057\\\\u0065\\\\u0043\\\\u0068\\\\u0061\\\\u0074'
  })
  const r = scanArtifactTree(root)
  assert.deepEqual(r.hits, [{ file: 'd.js', term: 'WeChat' }])
})

test('禁词仅存在于 JSON/ttml/xhsml/css 时仍命中', () => {
  const root = makeCase('hit-nonjs', {
    'page.json': '{"tips":"扫码加我"}',
    'page.ttml': '<text>二维码</text>',
    'page.xhsml': '<view>口令</view>',
    'page.css': '.WeChat{display:none}'
  })
  const r = scanArtifactTree(root)
  const sorted = [...r.hits].sort((a, b) => a.file.localeCompare(b.file))
  assert.deepEqual(sorted, [
    { file: 'page.css', term: 'WeChat' },
    { file: 'page.json', term: '加我' },
    { file: 'page.ttml', term: '二维码' },
    { file: 'page.xhsml', term: '口令' }
  ])
})

test('目录不存在返回结构化错误', () => {
  const r = scanArtifactTree(join(SANDBOX, 'does-not-exist'))
  assert.ok(r.error)
  assert.equal(r.filesScanned, 0)
  assert.deepEqual(r.hits, [])
})

test('目录存在但没有合格文本文件返回错误', () => {
  const root = join(SANDBOX, 'only-binary')
  mkdirSync(root, { recursive: true })
  writeFileSync(join(root, 'asset.png'), 'not text', 'utf8')
  const r = scanArtifactTree(root)
  assert.ok(r.error)
  assert.equal(r.filesScanned, 0)
})

test('含 NUL 字节的文件按非文本跳过且不计入 filesScanned', () => {
  const root = makeCase('nul-skip', { 'ok.js': 'console.log(1)' })
  writeFileSync(join(root, 'bin.js'), Buffer.from([0x00, 0x00, 0x5b, 0x5d]))
  const r = scanArtifactTree(root)
  assert.equal(r.error, null)
  assert.equal(r.filesScanned, 1)
  assert.equal(r.skippedNonText, 1)
})

test('命中结果不回显文件正文', () => {
  const root = makeCase('hit-no-echo', {
    'a/x.ttml': '<view>加我</view>\n秘密内容不出现\n'
  })
  const r = scanArtifactTree(root)
  assert.equal(r.hits.length, 1)
  assert.deepEqual(r.hits[0], { file: 'a/x.ttml', term: '加我' })
  assert.ok(!JSON.stringify(r).includes('秘密内容不出现'))
})
