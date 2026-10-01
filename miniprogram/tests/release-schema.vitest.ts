import { describe, expect, it } from 'vitest'
import { findIncompatibleOperations, parseDeployedSha } from '../scripts/release-schema.mjs'

const SDL = `
  type Query { me: User, ping: String }
  type User { id: ID!, name: String }
`

describe('findIncompatibleOperations', () => {
  it('全部兼容 → 空列表', () => {
    const ops = { MeDocument: 'query Me { me { id name } }', PingDocument: 'query Ping { ping }' }
    expect(findIncompatibleOperations(SDL, ops)).toEqual([])
  })

  it('未知字段 → 报出 operation 名与错误', () => {
    const ops = { MeDocument: 'query Me { me { id quota } }' }
    const result = findIncompatibleOperations(SDL, ops)
    expect(result).toHaveLength(1)
    expect(result[0].name).toBe('MeDocument')
    expect(result[0].errors.join('\n')).toContain('quota')
  })

  it('部分不兼容 → 只列不兼容的', () => {
    const ops = {
      MeDocument: 'query Me { me { id } }',
      BadDocument: 'query Bad { nope }',
      PingDocument: 'query Ping { ping }'
    }
    expect(findIncompatibleOperations(SDL, ops).map((r) => r.name)).toEqual(['BadDocument'])
  })

  it('operation 自身语法错误 → 同样算不兼容，不静默放过', () => {
    const result = findIncompatibleOperations(SDL, { BrokenDocument: 'query { me {' })
    expect(result.map((r) => r.name)).toEqual(['BrokenDocument'])
  })

  it('SDL 非法 → 抛错而不是当作通过', () => {
    expect(() => findIncompatibleOperations('type Query {', { A: 'query A { ping }' })).toThrow()
  })
})

describe('parseDeployedSha', () => {
  const SHA = '0a6a3d7b9c1e2f405162738495a6b7c8d9e0f1a2'

  it('去掉 -pb<hash> 后缀', () => {
    expect(parseDeployedSha(`${SHA}-pbdeadbeef`)).toBe(SHA)
  })

  it('无后缀也接受', () => {
    expect(parseDeployedSha(SHA)).toBe(SHA)
  })

  it.each([null, undefined, '', 'latest', 'not-a-sha-pbdeadbeef', '0a6a3d7b-', `${SHA}-xx`])(
    '无法解析 %j → 抛错',
    (value) => {
      expect(() => parseDeployedSha(value)).toThrow()
    }
  )
})
