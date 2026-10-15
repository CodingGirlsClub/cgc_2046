// ICP 备案号（#1079）。同一主体按小程序分别为不同备案记录：
// weapp -6X、xhs/tt -7X（抖音开放平台控制台 2026-10-15 由主控核实，
// AppID tt8792f12f19e9090101，状态「生效中」）。
// 判据：tt 已到展示阶段（非 null）；weapp/xhs 回归；三平台各自独立取值（改一处不误伤对端）。
import assert from 'node:assert/strict'
import { describe, test } from 'node:test'

import { filingNumber } from '../src/domain/filing.ts'

describe('ICP 备案号', () => {
  test('tt（2026-10-15 控制台实测）：京ICP备16008426号-7X，生效中', () => {
    assert.equal(filingNumber('tt'), '京ICP备16008426号-7X')
  })

  test('weapp/xhs 回归：各自备案记录独立取值', () => {
    assert.equal(filingNumber('weapp'), '京ICP备16008426号-6X')
    assert.equal(filingNumber('xhs'), '京ICP备16008426号-7X')
  })

  test('三平台取值两两独立（≠ 引用同一对象）', () => {
    const a = filingNumber('xhs')
    const b = filingNumber('tt')
    assert.equal(a, b) // 2026-10-15 同值——断言值而非实现；分叉时预期本测试失败并被显式更新
    assert.notEqual(filingNumber('weapp'), a)
  })
})
