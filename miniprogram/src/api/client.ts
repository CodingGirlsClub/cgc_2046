import Taro from '@tarojs/taro'

/**
 * GraphQL 薄客户端（graphql-request 级别）
 *
 * 仅做一件事：把 query + variables POST 到后端 /api/graphql。
 * Bearer token 为占位——N1 一键登录落地前，调用方可 setAuthToken 注入。
 *
 * 端点不走环境变量：小程序构建期 defineConstants 注入成本高于收益，
 * v1 前由 Plan Phase 3 决定配置化方案。
 */
const GRAPHQL_ENDPOINT = 'http://localhost:4000/api/graphql'

let authToken: string | null = null

/** 注入 / 清除 Bearer token（占位，登录链路接通后由 auth 模块调用） */
export function setAuthToken(token: string | null): void {
  authToken = token
}

export interface GraphQLError {
  message: string
  extensions?: Record<string, unknown>
}

export interface GraphQLResponse<T> {
  data?: T
  errors?: GraphQLError[]
}

export class GraphQLRequestError extends Error {
  constructor(
    message: string,
    public readonly statusCode: number,
    public readonly errors?: GraphQLError[]
  ) {
    super(message)
    this.name = 'GraphQLRequestError'
  }
}

/**
 * 执行 GraphQL 请求。
 *
 * - HTTP 非 2xx（如 401 鉴权拒绝）→ throw GraphQLRequestError
 * - 响应含 errors → throw GraphQLRequestError（调用方按需捕获）
 * - 网络层失败（域名未白名单、后端未启动）→ Taro.request reject 原样上抛
 */
export async function graphqlRequest<TData = Record<string, unknown>>(
  query: string,
  variables?: Record<string, unknown>
): Promise<TData> {
  const header: Record<string, string> = {
    'Content-Type': 'application/json'
  }
  if (authToken) {
    header.Authorization = `Bearer ${authToken}`
  }

  const res = await Taro.request<GraphQLResponse<TData>>({
    url: GRAPHQL_ENDPOINT,
    method: 'POST',
    header,
    data: { query, variables }
  })

  if (res.statusCode < 200 || res.statusCode >= 300) {
    throw new GraphQLRequestError(`GraphQL HTTP ${res.statusCode}`, res.statusCode)
  }
  if (res.data?.errors?.length) {
    throw new GraphQLRequestError(
      res.data.errors.map((e) => e.message).join('; '),
      res.statusCode,
      res.data.errors
    )
  }
  return res.data?.data as TData
}
