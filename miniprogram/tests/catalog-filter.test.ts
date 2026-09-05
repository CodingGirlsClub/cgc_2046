import assert from 'node:assert/strict'
import test from 'node:test'
import { catalogSearchVariables } from '../src/api/catalogFilter.ts'

test('catalogSearchVariables: 空关键词（缺省/空串/纯空格）→ null，退回无 filter 查询', () => {
  assert.equal(catalogSearchVariables(undefined), null)
  assert.equal(catalogSearchVariables(''), null)
  assert.equal(catalogSearchVariables('   '), null)
})

test('catalogSearchVariables: 非空关键词 → title ilike `%kw%`，并钉住 status=open / visibility=public', () => {
  assert.deepEqual(catalogSearchVariables('  Python 入门 '), {
    eventFilter: {
      status: { eq: 'open' },
      visibility: { eq: 'public' },
      title: { ilike: '%Python 入门%' }
    },
    courseFilter: {
      status: { eq: 'open' },
      visibility: { eq: 'public' },
      title: { ilike: '%Python 入门%' }
    }
  })
})
