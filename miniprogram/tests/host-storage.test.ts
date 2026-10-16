// 宿主存储安全取用（#1123）：tt 包装器把 globalThis 遮蔽为 undefined，
// 旧写法 `globalThis.wx` 在模块求值期抛 TypeError → 全页白屏。
// 变异验证：wxStorageOf 去掉 `?.` → 用例①转红（TypeError）；还原转绿。
import assert from 'node:assert/strict'
import { describe, test } from 'node:test'

import { hostWxStorage, wxStorageOf } from '../src/domain/host-storage.ts'

const fakeWx = {
  getStorageSync: () => 'v',
  setStorageSync: () => {},
  removeStorageSync: () => {}
}

describe('宿主存储取用（#1123）', () => {
  test('作用域缺失（tt 遮蔽形状）→ null，不抛', () => {
    assert.equal(wxStorageOf(undefined), null)
    assert.equal(wxStorageOf(null), null)
  })

  test('作用域无 wx（tt/xhs 宿主）→ null', () => {
    assert.equal(wxStorageOf({}), null)
  })

  test('有 wx（weapp 形状）→ 原样返回', () => {
    assert.equal(wxStorageOf({ wx: fakeWx }), fakeWx)
  })

  test('hostWxStorage：node 进程无 wx → null', () => {
    assert.equal(hostWxStorage(), null)
  })

  test('hostWxStorage：宿主 wx 可见时原样返回', () => {
    const runtime = globalThis as { wx?: unknown }
    runtime.wx = fakeWx
    try {
      assert.equal(hostWxStorage(), fakeWx)
    } finally {
      delete runtime.wx
    }
  })
})
