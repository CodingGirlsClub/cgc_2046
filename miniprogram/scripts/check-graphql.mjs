#!/usr/bin/env node
/**
 * GraphQL 连通性检查
 *
 * 直连 dev backend 做 introspection：{ __schema { queryType { name } } }
 * 判定：
 *   - 任何 HTTP 响应（200 数据 / 401·403 鉴权拒绝）都算"连通"，exit 0
 *   - 网络层失败（ECONNREFUSED 等）才算不连通，exit 1
 *
 * 用法：node scripts/check-graphql.mjs [endpoint]
 * 默认 endpoint：http://localhost:4001/api/graphql（可用环境变量 CGC_GRAPHQL_ENDPOINT 覆盖）
 */

const endpoint =
  process.argv[2] || process.env.CGC_GRAPHQL_ENDPOINT || 'http://localhost:4001/api/graphql'

const INTROSPECTION = '{__schema{queryType{name}}}'

async function main() {
  console.log(`[check-graphql] POST ${endpoint}`)
  let res
  try {
    res = await fetch(endpoint, {
      method: 'POST',
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify({ query: INTROSPECTION })
    })
  } catch (err) {
    console.error(`[check-graphql] FAIL: network error — ${err.message}`)
    console.error('[check-graphql] 后端未启动？参考：cd ../backend && mix phx.server')
    process.exit(1)
  }

  const bodyText = await res.text()
  console.log(`[check-graphql] HTTP ${res.status}`)

  let body
  try {
    body = JSON.parse(bodyText)
  } catch {
    body = bodyText
  }
  console.log('[check-graphql] response:', JSON.stringify(body, null, 2))

  if (res.status === 200 && body?.data?.__schema?.queryType?.name) {
    console.log(
      `[check-graphql] PASS: introspection ok, queryType = ${body.data.__schema.queryType.name}`
    )
    process.exit(0)
  }
  if (res.status === 401 || res.status === 403) {
    console.log('[check-graphql] PASS: 鉴权拒绝（连通性成立，需 Bearer token）')
    process.exit(0)
  }
  // 其它 HTTP 状态：服务可达但响应异常，仍视为连通，但给出警告。
  console.log('[check-graphql] PASS(with warning): 服务可达，但响应非预期 introspection 结果')
  process.exit(0)
}

main()
