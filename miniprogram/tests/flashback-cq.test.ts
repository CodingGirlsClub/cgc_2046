import test from 'node:test'
import assert from 'node:assert/strict'
import { adoptableCqToken } from '../src/domain/flashback-cq.ts'

// #770 URL Link cq 承接：明文 token 字符集 [A-Za-z0-9_-]（后端 43 字符
// base64url；找回邮件 fb_ 前缀同集）。启动参数在字符集外/非字符串 → 弃，
// 防 storage 污染（flashbackEntry 同款纪律）。

test('合法明文 token（43 字符 base64url）原样采纳', () => {
  const token = 'TESTTESTTESTTESTTESTTESTTESTTESTTESTTESTTES'
  assert.equal(adoptableCqToken(token), token)
})

test('找回邮件形态（fb_ 前缀）同属允许集，原样采纳', () => {
  const token = 'fb_TESTTESTTESTTESTTESTTESTTESTTESTTESTTEST'
  assert.equal(adoptableCqToken(token), token)
})

test('空串/缺省/非字符串 → 不采纳（不碰 storage）', () => {
  assert.equal(adoptableCqToken(''), null)
  assert.equal(adoptableCqToken(undefined), null)
  assert.equal(adoptableCqToken(null), null)
  assert.equal(adoptableCqToken(123), null)
  assert.equal(adoptableCqToken({ evil: true }), null)
})

test('字符集外（query 残片/注入尝试）→ 拒收', () => {
  assert.equal(adoptableCqToken('abc%20def'), null)
  assert.equal(adoptableCqToken('a=b&c=d'), null)
  assert.equal(adoptableCqToken('token with space'), null)
  assert.equal(adoptableCqToken('带中文的参数'), null)
  assert.equal(adoptableCqToken('<script>'), null)
})
