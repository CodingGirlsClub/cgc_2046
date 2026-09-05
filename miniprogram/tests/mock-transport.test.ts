import assert from 'node:assert/strict'
import test from 'node:test'
import { mockGraphQLRequest } from '../src/api/mockTransport.ts'
import { CatalogQueryDocument, CatalogSearchQueryDocument } from '../src/api/operations.ts'

interface CatalogResults {
  listEvents: { results: Array<{ id: string; title: string }> }
  listCourses: { results: Array<{ id: string; title: string }> }
}

function searchVariables(pattern: string) {
  return {
    first: 50,
    eventFilter: {
      status: { eq: 'open' },
      visibility: { eq: 'public' },
      title: { ilike: pattern }
    },
    courseFilter: {
      status: { eq: 'open' },
      visibility: { eq: 'public' },
      title: { ilike: pattern }
    }
  }
}

test('mock Catalog 无 filter 变量 → 全量目录（原行为不变）', () => {
  const data = mockGraphQLRequest<CatalogResults>(CatalogQueryDocument, { first: 50 })
  assert.equal(data.listEvents.results.length, 2)
  assert.equal(data.listCourses.results.length, 1)
})

test('mock CatalogSearch：title ilike 过滤，大小写不敏感', () => {
  const data = mockGraphQLRequest<CatalogResults>(CatalogSearchQueryDocument, searchVariables('%python%'))
  assert.deepEqual(data.listEvents.results.map(({ id }) => id), ['event-1'])
  assert.deepEqual(data.listCourses.results, [])
})

test('mock CatalogSearch：中文关键词命中课程', () => {
  const data = mockGraphQLRequest<CatalogResults>(CatalogSearchQueryDocument, searchVariables('%成长%'))
  assert.deepEqual(data.listEvents.results, [])
  assert.deepEqual(data.listCourses.results.map(({ id }) => id), ['course-1'])
})

test('mock CatalogSearch：无命中 → 空结果', () => {
  const data = mockGraphQLRequest<CatalogResults>(CatalogSearchQueryDocument, searchVariables('%不存在的词%'))
  assert.deepEqual(data.listEvents.results, [])
  assert.deepEqual(data.listCourses.results, [])
})
