import { fileURLToPath } from 'node:url'
import { defineConfig } from 'vitest/config'

export default defineConfig({
  resolve: {
    alias: {
      // 与 config/index.ts 的 alias 保持一致：@ → miniprogram/src
      '@': fileURLToPath(new URL('./src', import.meta.url))
    }
  },
  define: {
    // 测试态：不使用 mock transport（__E2E_MOCK__=false），走真实请求边界；
    // endpoint 用不可路由的 .invalid 地址，绝不读取真实 .env。
    __E2E_MOCK__: 'false',
    __GRAPHQL_ENDPOINT__: JSON.stringify('https://example.invalid/graphql'),
    __PLATFORM_NAME__: JSON.stringify('微信'),
    // 构建期注入的模板 ID 映射（config/index.ts 的 defineConstants 同款）。
    // 测试态模拟「一个都没配」的构建，与 CI（pnpm check:ci 无真实 ID）一致；
    // 用空对象而非逐键列举，避免在此处再造一份会漂移的场景清单——
    // 请求期读取一律走 `table[scenario] ?? ''`（domain/subscription.ts），
    // 缺键安全。键集守卫见 tests/subscription-build.test.mjs。
    __WECHAT_TEMPLATE_IDS__: JSON.stringify({}),
    __TT_TEMPLATE_IDS__: JSON.stringify({})
  },
  test: {
    environment: 'node',
    include: ['tests/api-client.test.ts', 'tests/account-state.test.ts', 'tests/wish-draft-state.test.ts', 'tests/real-auth.test.ts', 'tests/real-content.test.ts', 'tests/initiative.test.ts', 'tests/campaign.test.ts', 'tests/volunteer-apply.test.ts', 'tests/enrollment-payment-status.test.ts', 'tests/error-codes.contract.test.ts', 'tests/real-moderation.test.ts', 'tests/real-flashback-claim.test.ts'],
    clearMocks: true,
    restoreMocks: true
  }
})
