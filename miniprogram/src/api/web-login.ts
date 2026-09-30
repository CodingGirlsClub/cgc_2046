import { graphqlRequest } from './client'
import { WebLoginPreviewDocument, WebLoginConfirmDocument } from './operations'
import type { WebLoginPreviewQuery, WebLoginPreviewQueryVariables, WebLoginConfirmMutation, WebLoginConfirmMutationVariables } from './generated/graphql'
import type { WebLoginRequest } from '../domain/web-login'

export async function getWebLoginRequest(requestId: string): Promise<WebLoginRequest> {
  const data = await graphqlRequest<WebLoginPreviewQuery, WebLoginPreviewQueryVariables>(WebLoginPreviewDocument, { requestId })
  if (!data.wechatMiniWebLoginPreview) throw new Error('登录请求暂时不可用，请重试。')
  return data.wechatMiniWebLoginPreview
}
export async function confirmWebLogin(requestId: string): Promise<WebLoginRequest> {
  const data = await graphqlRequest<WebLoginConfirmMutation, WebLoginConfirmMutationVariables>(WebLoginConfirmDocument, { requestId })
  if (!data.wechatMiniWebLoginConfirm) throw new Error('登录确认失败，请重试。')
  return data.wechatMiniWebLoginConfirm
}
