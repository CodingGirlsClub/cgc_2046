import { describe, expect, it } from 'vitest'
import { readFileSync } from 'node:fs'
import { fileURLToPath } from 'node:url'
import { dirname, resolve } from 'node:path'
import { COPY } from '../src/domain/error-copy'

/**
 * 错误码 golden-file 契约守卫（#241 四清单机械联动，同 web 侧
 * error-codes.contract.test.ts / RBAC 模式）。
 *
 * 断言 error-copy.ts 文案表全部键 ⊆ backend/priv/error_codes_contract.json
 * （domain 单源经 `mix cgc2046.gen_error_codes_contract` 生成）。
 * 后端改名/删除 code 或本表拼错键 → 红灯。
 */

const CONTRACT_PATH = resolve(
  dirname(fileURLToPath(import.meta.url)),
  '../../backend/priv/error_codes_contract.json'
)

describe('error-copy 错误码契约', () => {
  const { codes } = JSON.parse(readFileSync(CONTRACT_PATH, 'utf8')) as {
    codes: string[]
  }
  const codeSet = new Set(codes)

  it('文案表全部键存在于后端契约工件', () => {
    const keys = Object.keys(COPY)
    expect(keys.length).toBeGreaterThan(0)
    for (const key of keys) {
      expect(
        codeSet.has(key),
        `error-copy.ts 键 ${key} 不在后端契约中（键拼错，或后端已改名/删除该 code）`
      ).toBe(true)
    }
  })

  it('database_error 有文案（#241 F4 回归钉：DB 故障不得英文直出）', () => {
    expect(COPY.database_error).toBeTruthy()
  })

  it('LLM 收银台与工作台派发错误码均有文案（#1297 回归钉）', () => {
    const llmCodes = [
      'llm_payment_order_invalid_kind',
      'llm_payment_order_invalid_provider',
      'llm_payment_order_invalid_amount',
      'llm_payment_order_invalid_workspace',
      'llm_payment_order_invalid_idempotency_key',
      'llm_payment_order_workspace_required',
      'llm_payment_order_forbidden',
      'llm_payment_order_provider_failed',
      'llm_payment_order_idempotency_conflict',
      'llm_payment_order_not_found',
      'llm_payment_order_database_error',
      'insufficient_workspace_pool',
      'no_workspace_members',
      'workspace_not_found'
    ]
    for (const code of llmCodes) {
      expect(COPY[code], `miniprogram error-copy.ts 缺少 ${code} 文案`).toBeTruthy()
    }
  })
})
