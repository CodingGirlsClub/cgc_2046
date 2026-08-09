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
    __GRAPHQL_ENDPOINT__: JSON.stringify('https://example.invalid/graphql')
  },
  test: {
    environment: 'node',
    include: ['tests/api-client.test.ts'],
    clearMocks: true,
    restoreMocks: true
  }
})
