/**
 * 宿主存储（wx 形状）单源取用（#1123）。
 *
 * 抖音的模块包装器把 `globalThis` 等宿主名声明为形参却不传值——模块内
 * `globalThis` 为 undefined（微信/小红书运行时不遮蔽）。各处直接写
 * `globalThis.wx` 会在**模块求值期**抛 TypeError，经 require 同步异常连坐
 * `Page()` 注册 → 整页白屏（2026-10-16 抖音模拟器实测）。
 *
 * 取用一律经本模块：`typeof` 守卫 + 可选链，取不到回落 null——调用方按
 * 「存储不可用」降级（本会话有效 / mock 不落盘），不得抛错。tt/xhs 没有
 * 等价 wx 存储面，回落 null 即可。
 */

/** 宿主 wx 形状的同步存储（完整宿主面；取值方按需调用其中方法） */
export interface HostWxStorage {
  getStorageSync(key: string): unknown
  setStorageSync(key: string, value: string): void
  removeStorageSync(key: string): void
}

/** 从给定作用域取 wx 存储；作用域缺失（tt 遮蔽形状）或无 wx → null，不抛 */
export function wxStorageOf(scope: unknown): HostWxStorage | null {
  return (scope as { wx?: HostWxStorage } | null | undefined)?.wx ?? null
}

/** 当前模块作用域的宿主存储（tt 端 globalThis 被包装器遮蔽为 undefined → null） */
export function hostWxStorage(): HostWxStorage | null {
  return wxStorageOf(typeof globalThis === 'undefined' ? undefined : globalThis)
}
