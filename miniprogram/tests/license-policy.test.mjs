import assert from 'node:assert/strict'
import test from 'node:test'
import {
  evaluateLicenseDeclaration,
  knownNoFieldLicense
} from '../scripts/license-policy.mjs'

const ctx = (name = 'fixture', version = '1.0.0') => ({ name, version })

test('单一允许项通过', () => {
  assert.equal(evaluateLicenseDeclaration('MIT', ctx()).allowed, true)
  assert.equal(evaluateLicenseDeclaration('Apache-2.0', ctx()).allowed, true)
  assert.equal(evaluateLicenseDeclaration('Zlib', ctx()).allowed, true)
})

test('允许 OR 禁止 → 允许', () => {
  const r = evaluateLicenseDeclaration('MIT OR GPL-2.0-only', ctx())
  assert.equal(r.allowed, true)
  assert.equal(r.reason, 'approved')
})

test('禁止 OR 未知 → 拒绝', () => {
  assert.equal(evaluateLicenseDeclaration('GPL-2.0-only OR GPL-3.0-only', ctx()).allowed, false)
})

test('MIT AND Zlib 与书面规则一致（Zlib 已由 human 裁定入白名单）', () => {
  const r = evaluateLicenseDeclaration('MIT AND Zlib', ctx())
  assert.equal(r.allowed, true)
  assert.equal(r.reason, 'approved')
})

test('MIT AND 未列项 → 拒绝', () => {
  assert.equal(evaluateLicenseDeclaration('MIT AND GPL-2.0-only', ctx()).allowed, false)
  assert.equal(evaluateLicenseDeclaration('MIT AND WTFPL', ctx()).allowed, false)
})

test('UNLICENSED / UNKNOWN / 空串 / 缺字段 → 拒绝', () => {
  assert.equal(evaluateLicenseDeclaration('UNLICENSED', ctx()).allowed, false)
  assert.equal(evaluateLicenseDeclaration('UNKNOWN', ctx()).allowed, false)
  assert.equal(evaluateLicenseDeclaration('', ctx()).allowed, false)
  assert.equal(evaluateLicenseDeclaration(undefined, ctx()).allowed, false)
  assert.equal(evaluateLicenseDeclaration(null, ctx()).allowed, false)
})

test('SEE LICENSE IN、自定义文本与语法错误 → 拒绝且不 crash', () => {
  assert.equal(evaluateLicenseDeclaration('SEE LICENSE IN LICENSE.txt', ctx()).allowed, false)
  assert.equal(evaluateLicenseDeclaration('some proprietary text', ctx()).allowed, false)
  assert.equal(evaluateLicenseDeclaration('MIT License (MIT)', ctx()).allowed, false)
})

test('object {type,url} 与数组多选形态', () => {
  assert.equal(evaluateLicenseDeclaration({ type: 'MIT', url: 'https://x' }, ctx()).allowed, true)
  assert.equal(evaluateLicenseDeclaration([{ type: 'GPL-2.0-only' }, { type: 'MIT' }], ctx()).allowed, true)
  assert.equal(evaluateLicenseDeclaration([{ type: 'GPL-2.0-only' }], ctx()).allowed, false)
  assert.equal(evaluateLicenseDeclaration([], ctx()).allowed, false)
})

test('known-no-field 按精确 name@version 命中，同名不同版本拒绝', () => {
  assert.equal(evaluateLicenseDeclaration(undefined, { name: 'exif-parser', version: '0.1.12' }).allowed, true)
  assert.equal(evaluateLicenseDeclaration(undefined, { name: 'exif-parser', version: '9.9.9' }).allowed, false)
  assert.equal(knownNoFieldLicense('dom-walk', '0.1.2'), 'MIT')
  assert.equal(knownNoFieldLicense('dom-walk', '0.0.1'), null)
})

test('(BSD-3-Clause OR GPL-2.0) 经允许分支通过', () => {
  assert.equal(evaluateLicenseDeclaration('(BSD-3-Clause OR GPL-2.0)', ctx()).allowed, true)
})

test('CC-BY 数据许可仅窄名单包允许', () => {
  const caniuse = { name: 'caniuse-lite', version: '1.0.30001809' }
  assert.equal(evaluateLicenseDeclaration('CC-BY-4.0', caniuse).allowed, true)
  assert.equal(evaluateLicenseDeclaration('CC-BY-4.0', ctx()).allowed, false)
})

test('spdx-exceptions 的 CC-BY-3.0 数据许可允许（orchestrator 裁定）', () => {
  const spdxExceptions = { name: 'spdx-exceptions', version: '2.5.0' }
  const r = evaluateLicenseDeclaration('CC-BY-3.0', spdxExceptions)
  assert.equal(r.allowed, true)
  assert.equal(r.reason, 'approved')
  // 同类声明放在任意非数据包名上仍拒绝
  assert.equal(evaluateLicenseDeclaration('CC-BY-3.0', ctx('some-lib', '1.0.0')).allowed, false)
})

test('WITH exception 与 LicenseRef-* 未列 → 拒绝', () => {
  assert.equal(evaluateLicenseDeclaration('MIT WITH LLVM-exception', ctx()).allowed, false)
  assert.equal(evaluateLicenseDeclaration('LicenseRef-Proprietary', ctx()).allowed, false)
})

test('嵌套 AND/OR 组合', () => {
  assert.equal(evaluateLicenseDeclaration('(MIT OR Apache-2.0) AND Zlib', ctx()).allowed, true)
  assert.equal(evaluateLicenseDeclaration('(MIT AND Zlib) OR GPL-2.0-only', ctx()).allowed, true)
  assert.equal(evaluateLicenseDeclaration('(MIT AND GPL-2.0-only) OR (Apache-2.0 AND WTFPL)', ctx()).allowed, false)
})
