import assert from 'node:assert/strict'
import { readFileSync } from 'node:fs'
import test from 'node:test'

// 安全收敛的 overrides 必须真的落进锁文件。pnpm 10（CI 钉的版本）只读
// package.json 的 "pnpm.overrides"，pnpm 11 只读 pnpm-workspace.yaml——
// 放错文件时安装照样成功，override 却静默失效（2026-11 因此退回 22 条
// Dependabot 告警）。锁文件的 overrides 段是 pnpm 实际生效配置的回执，
// 这里拿它对齐 package.json，把「安装成功」与「收敛生效」分开。
const pkg = JSON.parse(readFileSync(new URL('../package.json', import.meta.url), 'utf8'))
const pnpmWorkspace = readFileSync(new URL('../pnpm-workspace.yaml', import.meta.url), 'utf8')
const lock = readFileSync(new URL('../pnpm-lock.yaml', import.meta.url), 'utf8')

function lockOverrides(text) {
  const lines = text.split('\n')
  const start = lines.findIndex((line) => line === 'overrides:')
  const out = new Map()
  if (start === -1) return out
  for (const line of lines.slice(start + 1)) {
    const match = /^ {2}(.+?): (.+)$/.exec(line)
    if (!match) break // 后续为下一顶层键或空行
    out.set(match[1].replace(/^'|'$/g, ''), match[2])
  }
  return out
}

test('锁文件记录了 package.json 的全部 overrides', () => {
  const expected = pkg.pnpm?.overrides ?? {}
  assert.ok(
    Object.keys(expected).length > 0,
    'package.json 的 pnpm.overrides 为空——安全收敛会整批失效',
  )

  const actual = lockOverrides(lock)
  const missing = []
  const mismatched = []
  for (const [key, value] of Object.entries(expected)) {
    if (!actual.has(key)) missing.push(key)
    else if (actual.get(key) !== String(value)) {
      mismatched.push(`${key}: package.json ${value} / 锁文件 ${actual.get(key)}`)
    }
  }
  assert.deepEqual(
    missing,
    [],
    `锁文件缺少这些 overrides（当前 pnpm 未读取配置真源，或锁文件未重算）：\n${missing.join('\n')}`,
  )
  assert.deepEqual(mismatched, [], `overrides 取值不一致：\n${mismatched.join('\n')}`)
})

test('pnpm-workspace.yaml 不再持有 overrides（pnpm 10 忽略它）', () => {
  assert.doesNotMatch(
    pnpmWorkspace,
    /^overrides:/m,
    'overrides 出现在 pnpm-workspace.yaml：CI 的 pnpm 10 会静默忽略，统一放 package.json',
  )
})
