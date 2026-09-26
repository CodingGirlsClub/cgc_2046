import { describe, expect, it, vi } from 'vitest'

// 一键收好（R27）遇到已属于另一个账号的档案：后端报 flashback_recover_account_conflict（2026-09-26
// 起全部绑定路径不悄悄挪档案）。旅程页把 error.message 直接 toast 出来——必须是中文说明，不能是英文原文。

const mocks = vi.hoisted(() => ({
  graphqlRequest: vi.fn(),
  isAuthenticationError: vi.fn(() => false)
}))

vi.mock('../src/api/client', () => ({
  getAuthToken: vi.fn(),
  setAuthToken: vi.fn(),
  graphqlRequest: mocks.graphqlRequest,
  isAuthenticationError: mocks.isAuthenticationError,
  GraphQLRequestError: class GraphQLRequestError extends Error {
    constructor(
      message: string,
      public statusCode: number,
      public errors: Array<{ message: string; code?: string }> = []
    ) {
      super(message)
    }
  }
}))

vi.mock('../src/api/operations', () => ({ FlashbackClaimMutationDocument: 'FLASHBACK_CLAIM' }))
vi.mock('../src/state/workspaceTab', () => ({ clearWorkspaceTab: vi.fn(), rememberWorkspaceTab: vi.fn() }))
// real.ts 引用的 state 模块都 import @tarojs/taro（vitest 里缺构建期全局量）：整块 mock
vi.mock('../src/state/silentLogin', () => ({ silentLoginAllowed: () => true, setSilentLoginAllowed: () => undefined }))
vi.mock('../src/state/accountState', () => ({
  activateAccount: vi.fn(),
  clearAccountState: vi.fn(),
  appendLocalNotification: vi.fn(),
  readLocalNotifications: vi.fn()
}))
vi.mock('../src/platform', () => ({ currentPlatform: () => 'wechat' }))

import { GraphQLRequestError } from '../src/api/client'
import { RealMiniProgramApi } from '../src/api/real'

describe('flashbackClaim（一键收好）', () => {
  it('档案已属于另一个账号 → 中文冲突说明（BusinessError，保留 code），不透出英文原文', async () => {
    mocks.graphqlRequest.mockRejectedValue(
      new GraphQLRequestError('GraphQL error', 200, [
        { message: 'This phone or archive already belongs to another account', code: 'flashback_recover_account_conflict' }
      ])
    )

    await expect(new RealMiniProgramApi().flashbackClaim('token-1')).rejects.toMatchObject({
      name: 'BusinessError',
      code: 'flashback_recover_account_conflict',
      message: expect.stringContaining('另一个账号')
    })
  })
})
