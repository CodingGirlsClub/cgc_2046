// 隐私政策平台变体内容测试（P0-5）。
// 判据下沉 domain（骨架 src/domain/privacy.ts + 两份变体文件）后用 node --test 钉住三条铁律：
// 1. xhs 变体净身——源文件与组装结果都不含 diversion 词表任一词（与 CI check:diversion 同词表；
//    源文件级断言覆盖「构建期 alias 选错文件」的回归）；
// 2. wechat 变体不回归——保留「微信」相关原文，差异仅限平台名枚举处；
// 3. 骨架自身净身（三端产物共享注入）。
import assert from 'node:assert/strict'
import { readFileSync } from 'node:fs'
import { describe, test } from 'node:test'

import { BANNED_TERMS } from '../scripts/diversion-policy.mjs'
import { PRIVACY_META, type PrivacySection, type PrivacySpec } from '../src/domain/privacy.ts'
import { PRIVACY_INTRO as WECHAT_INTRO, PRIVACY_SECTIONS as WECHAT_SECTIONS } from '../src/domain/privacy-content-wechat.ts'
import { PRIVACY_INTRO as XHS_INTRO, PRIVACY_SECTIONS as XHS_SECTIONS } from '../src/domain/privacy-content-xhs.ts'

function textsOf(sections: PrivacySection[]): string[] {
  const out: string[] = []
  for (const section of sections) {
    out.push(section.title)
    for (const block of section.blocks) {
      if (block.title) out.push(block.title)
      if (block.kind === 'p') out.push(block.text)
      else out.push(...block.items)
    }
  }
  return out
}

describe('xhs 变体净身（D7 候选文本的机械门）', () => {
  test('源文件不含 diversion 词表任一词（anti-alias-选错回归）', () => {
    const raw = readFileSync(new URL('../src/domain/privacy-content-xhs.ts', import.meta.url), 'utf8')
    for (const term of BANNED_TERMS as string[]) {
      assert.ok(!raw.includes(term), `xhs 变体源文件命中禁用词「${term}」`)
    }
  })

  test('组装文本（intro/meta/全节）不含 diversion 词表任一词', () => {
    const corpus = [XHS_INTRO, ...PRIVACY_META, ...textsOf(XHS_SECTIONS)]
    for (const term of BANNED_TERMS as string[]) {
      for (const line of corpus) {
        assert.ok(!line.includes(term), `xhs 变体命中禁用词「${term}」：${line}`)
      }
    }
  })

  test('共享骨架与 meta 自身净身（三端产物共享注入）', () => {
    const raw = readFileSync(new URL('../src/domain/privacy.ts', import.meta.url), 'utf8')
    for (const term of BANNED_TERMS as string[]) {
      assert.ok(!raw.includes(term), `骨架源码命中禁用词「${term}」`)
      for (const line of PRIVACY_META) assert.ok(!line.includes(term), `meta 命中禁用词「${term}」`)
    }
  })

  test('第三方与支付表述改用平台名收窄措辞（合作支付机构/小红书等）', () => {
    const corpus = textsOf(XHS_SECTIONS)
    assert.ok(corpus.some((line) => line.includes('合作支付机构')))
    assert.ok(corpus.some((line) => line.startsWith('腾讯云（境内）')))
  })
})

describe('wechat 变体不回归（三方同步义务）', () => {
  test('保留微信/支付宝原文措辞（仅 xhs 收窄）', () => {
    const corpus = [WECHAT_INTRO, ...textsOf(WECHAT_SECTIONS)]
    assert.ok(corpus.some((line) => line.includes('微信/抖音/小红书小程序端')))
    assert.ok(corpus.some((line) => line.includes('微信开放平台/微信支付')))
    assert.ok(corpus.some((line) => line.includes('支付宝：支付')))
    assert.ok(corpus.some((line) => line.includes('由微信支付/支付宝处理')))
  })

  test('两变体章节标题序列一致（差异仅限平台名枚举处）', () => {
    assert.deepEqual(
      WECHAT_SECTIONS.map((s: PrivacySection) => s.title),
      XHS_SECTIONS.map((s: PrivacySection) => s.title)
    )
    assert.equal(PRIVACY_META.length, 3)
  })
})
