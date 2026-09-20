import assert from 'node:assert/strict'
import test from 'node:test'
import { toParagraphs } from '../src/domain/format.ts'

// 与 web 端 text-paragraphs（fix/description-paragraphs）逐字同语义：
// 空行切分、trim、过滤空段、null/空串 → []

test('null / undefined / 空串 → []', () => {
  assert.deepEqual(toParagraphs(null), [])
  assert.deepEqual(toParagraphs(undefined), [])
  assert.deepEqual(toParagraphs(''), [])
})

test('单段无空行 → 一段', () => {
  assert.deepEqual(toParagraphs('一段介绍。'), ['一段介绍。'])
})

test('空行切分为多段', () => {
  assert.deepEqual(toParagraphs('第一段\n\n第二段\n\n第三段'), ['第一段', '第二段', '第三段'])
})

test('连续空行（含空白行）折叠，不产生空段', () => {
  assert.deepEqual(toParagraphs('第一段\n\n\n   \n\n第二段'), ['第一段', '第二段'])
})

test('段内单换行保留（只有空行才分段）', () => {
  assert.deepEqual(toParagraphs('第一行\n第二行\n\n第三段'), ['第一行\n第二行', '第三段'])
})

test('段落首尾空白 trim；整体首尾空白不制造空段', () => {
  assert.deepEqual(toParagraphs('  第一段  \n\n  第二段  '), ['第一段', '第二段'])
  assert.deepEqual(toParagraphs('\n\n第一段\n\n'), ['第一段'])
})

test('纯空白串 → []', () => {
  assert.deepEqual(toParagraphs('   \n\n  '), [])
})
