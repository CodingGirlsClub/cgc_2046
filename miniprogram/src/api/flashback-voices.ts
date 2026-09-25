import { graphqlRequest } from './client'
import {
  FlashbackVoicesQueryDocument, FlashbackVoiceQueryDocument,
  FlashbackRandomVoicesQueryDocument, FlashbackLikeVoiceMutationDocument,
  FlashbackVoiceCitiesQueryDocument
} from './operations'
import type {
  FlashbackVoicesQuery, FlashbackVoicesQueryVariables,
  FlashbackVoiceQuery, FlashbackVoiceQueryVariables,
  FlashbackRandomVoicesQuery, FlashbackRandomVoicesQueryVariables,
  FlashbackLikeVoiceMutation, FlashbackLikeVoiceMutationVariables,
  FlashbackVoiceCitiesQuery, FlashbackVoiceCitiesQueryVariables
} from './generated/graphql'
import type { PublicVoice, VoiceCity } from '@/domain/flashback-voices'

export async function getVoices(voterKey: string, city: string | null): Promise<PublicVoice[]> {
  const data = await graphqlRequest<FlashbackVoicesQuery, FlashbackVoicesQueryVariables>(FlashbackVoicesQueryDocument, { voterKey, city })
  return data.flashbackPublicQuotes
}
export async function getVoice(quoteId: string, voterKey: string): Promise<PublicVoice | null> {
  const data = await graphqlRequest<FlashbackVoiceQuery, FlashbackVoiceQueryVariables>(FlashbackVoiceQueryDocument, { quoteId, voterKey })
  return data.flashbackPublicQuote ?? null
}
export async function getRandomVoices(voterKey: string): Promise<PublicVoice[]> {
  const data = await graphqlRequest<FlashbackRandomVoicesQuery, FlashbackRandomVoicesQueryVariables>(FlashbackRandomVoicesQueryDocument, { voterKey, limit: 12 })
  return data.flashbackRandomQuotes
}
export async function likeVoice(quoteId: string, voterKey: string, liked: boolean): Promise<number> {
  const data = await graphqlRequest<FlashbackLikeVoiceMutation, FlashbackLikeVoiceMutationVariables>(FlashbackLikeVoiceMutationDocument, { quoteId, voterKey, liked })
  if (!data.flashbackLikeQuote) throw new Error('点赞暂未完成，请重试')
  return data.flashbackLikeQuote.likeCount
}
export async function getVoiceCities(): Promise<VoiceCity[]> {
  const data = await graphqlRequest<FlashbackVoiceCitiesQuery, FlashbackVoiceCitiesQueryVariables>(FlashbackVoiceCitiesQueryDocument, {})
  return data.flashbackVoiceCities
}
