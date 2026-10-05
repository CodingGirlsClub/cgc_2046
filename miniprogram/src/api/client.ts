import Taro from '@tarojs/taro'
import type { RequestDocument } from 'graphql-request'
import { mockGraphQLRequest } from './mockTransport'
import { clearWorkspaceTab } from '@/state/workspaceTab'
import { clearAccountState } from '@/state/accountState'

const AUTH_TOKEN_KEY = 'cgc.auth_token'

let authToken: string | null = Taro.getStorageSync<string>(AUTH_TOKEN_KEY) || null

export interface GraphQLErrorPayload {
  message: string
  code?: string
  extensions?: { code?: string } & Record<string, unknown>
}

interface GraphQLResponse<T> {
  data?: T
  errors?: GraphQLErrorPayload[]
}

export class GraphQLRequestError extends Error {
  constructor(
    message: string,
    public readonly statusCode: number,
    public readonly errors: GraphQLErrorPayload[] = []
  ) {
    super(message)
    this.name = 'GraphQLRequestError'
  }
}

export class GraphQLTransportError extends Error {
  constructor(public readonly cause: unknown) {
    super('网络请求失败，请稍后重试')
    this.name = 'GraphQLTransportError'
  }
}


export function isAuthenticationError(error: unknown): boolean {
  return error instanceof GraphQLRequestError && (
    error.statusCode === 401 ||
    error.errors.some(({ code, extensions }) =>
      ['unauthorized', 'unauthenticated', 'not_authenticated'].includes(code ?? extensions?.code ?? '')
    )
  )
}

export function clearExpiredAuthentication(): void {
  setAuthToken(null)
  clearWorkspaceTab()
  clearAccountState({ clearPendingScene: true })
}

// 迟到的认证错误只作废它自己带的 token：请求在飞时用户已重新登录（authToken 已换新），
// 旧请求回 401 不得清掉新会话（#929–#933 同类「刚登录又掉线」）
function clearIfStillCurrent(sentToken: string | null): void {
  if (authToken === sentToken) clearExpiredAuthentication()
}

export function setAuthToken(token: string | null): void {
  // A replacement credential has no verified account until Session hydration.
  if (authToken !== token) clearAccountState()
  authToken = token
  if (token) Taro.setStorageSync(AUTH_TOKEN_KEY, token)
  else Taro.removeStorageSync(AUTH_TOKEN_KEY)
}

export function getAuthToken(): string | null {
  return authToken
}

function extractAuthToken(cookies: string[] | undefined, header: Record<string, unknown>): string | null {
  const headerCookie = header['set-cookie'] ?? header['Set-Cookie']
  const candidates = [
    ...(cookies ?? []),
    ...(Array.isArray(headerCookie) ? headerCookie : [headerCookie])
  ].filter((value): value is string => typeof value === 'string')

  for (const cookie of candidates) {
    const match = cookie.match(/(?:^|[,;]\s*)cgc_token=([^;,]+)/)
    if (match?.[1]) return decodeURIComponent(match[1])
  }
  return null
}

export async function graphqlRequest<TData, TVariables extends object>(
  document: RequestDocument,
  variables: TVariables,
  options: { captureAuthCookie?: boolean; timeoutMs?: number } = {}
): Promise<TData> {
  if (__E2E_MOCK__) {
    if (options.captureAuthCookie) setAuthToken('e2e-mock-token')
    // 与真实路径同规则：顶层 errors（如未登录 flashback_auth_required）必须抛
    // GraphQLRequestError 而非被当 data 吞掉——否则 mock 的所有 errors 腿
    // （未登录拒绝、会话失效）都走不进页面的登录引导/错误分支（P1）。
    const body = mockGraphQLRequest<TData & { errors?: GraphQLErrorPayload[] }>(document, variables)
    if (body?.errors?.length) {
      const error = new GraphQLRequestError(
        body.errors.map(({ message }) => message).join('；'),
        200,
        body.errors
      )
      if (isAuthenticationError(error)) clearExpiredAuthentication()
      throw error
    }
    return body
  }

  const sentToken = authToken
  const header: Record<string, string> = { 'Content-Type': 'application/json' }
  if (sentToken) header.Authorization = `Bearer ${sentToken}`

  const response = await Taro.request<unknown>({
    url: __GRAPHQL_ENDPOINT__,
    method: 'POST',
    // 默认 15s；大载荷（简历上传 base64 ~6.7MB）由调用方显式放宽（R20/U2）
    timeout: options.timeoutMs ?? 15_000,
    header,
    data: { query: String(document), variables }
  }).catch((cause: unknown) => { throw new GraphQLTransportError(cause) })

  if (response.statusCode < 200 || response.statusCode >= 300) {
    const error = new GraphQLRequestError(`请求失败（HTTP ${response.statusCode}）`, response.statusCode)
    if (isAuthenticationError(error)) clearIfStillCurrent(sentToken)
    throw error
  }
  const envelope = response.data
  if (envelope === null || typeof envelope !== 'object' || Array.isArray(envelope)) {
    throw new GraphQLRequestError('服务端响应格式错误（GraphQL envelope）', response.statusCode)
  }
  const body = envelope as GraphQLResponse<TData>
  const errors: unknown = body.errors
  if (errors !== undefined && (!Array.isArray(errors) || errors.some(error =>
    error === null || typeof error !== 'object' || Array.isArray(error) || typeof error.message !== 'string'
  ))) {
    throw new GraphQLRequestError('服务端响应格式错误（GraphQL errors）', response.statusCode)
  }
  if (body.errors?.length) {
    const error = new GraphQLRequestError(
      body.errors.map(({ message }) => message).join('；'),
      response.statusCode,
      body.errors
    )
    if (isAuthenticationError(error)) clearIfStillCurrent(sentToken)
    throw error
  }
  if (body.data === null || typeof body.data !== 'object' || Array.isArray(body.data)) {
    throw new GraphQLRequestError('服务端未返回数据', response.statusCode)
  }
  // Commit a candidate login cookie only after the HTTP and GraphQL contract holds.
  const candidateToken = options.captureAuthCookie
    ? extractAuthToken(response.cookies, response.header as Record<string, unknown>)
    : null
  if (candidateToken) setAuthToken(candidateToken)
  return body.data
}
