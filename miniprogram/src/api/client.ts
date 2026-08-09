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

export function isAuthenticationError(error: unknown): boolean {
  return error instanceof GraphQLRequestError && (
    error.statusCode === 401 ||
    error.errors.some(({ code, extensions }) =>
      ['unauthorized', 'unauthenticated', 'not_authenticated'].includes(code ?? extensions?.code ?? '')
    )
  )
}

function clearExpiredAuthentication(): void {
  setAuthToken(null)
  clearWorkspaceTab()
  clearAccountState({ clearPendingScene: true })
}

export function setAuthToken(token: string | null): void {
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
  options: { captureAuthCookie?: boolean } = {}
): Promise<TData> {
  if (__E2E_MOCK__) {
    if (options.captureAuthCookie) setAuthToken('e2e-mock-token')
    return mockGraphQLRequest<TData>(document, variables)
  }

  const header: Record<string, string> = { 'Content-Type': 'application/json' }
  if (authToken) header.Authorization = `Bearer ${authToken}`

  const response = await Taro.request<GraphQLResponse<TData>>({
    url: __GRAPHQL_ENDPOINT__,
    method: 'POST',
    timeout: 15_000,
    header,
    data: { query: String(document), variables }
  })

  // candidate token 只在 HTTP/GraphQL/data 三层校验全部通过后才提交（原子提交）
  const candidateToken = options.captureAuthCookie
    ? extractAuthToken(response.cookies, response.header as Record<string, unknown>)
    : null

  if (response.statusCode < 200 || response.statusCode >= 300) {
    const error = new GraphQLRequestError(`请求失败（HTTP ${response.statusCode}）`, response.statusCode)
    if (isAuthenticationError(error)) clearExpiredAuthentication()
    throw error
  }
  if (response.data.errors?.length) {
    const error = new GraphQLRequestError(
      response.data.errors.map(({ message }) => message).join('；'),
      response.statusCode,
      response.data.errors
    )
    if (isAuthenticationError(error)) clearExpiredAuthentication()
    throw error
  }
  if (!response.data.data) {
    throw new GraphQLRequestError('服务端未返回数据', response.statusCode)
  }
  if (candidateToken) setAuthToken(candidateToken)
  return response.data.data
}
