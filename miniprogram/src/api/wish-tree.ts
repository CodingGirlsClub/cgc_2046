import { graphqlRequest } from './client'
import { FlashbackPublicWishesQueryDocument, FlashbackPublicWishQueryDocument, FlashbackWishCitiesQueryDocument } from './operations'
import type { FlashbackPublicWishesQuery, FlashbackPublicWishesQueryVariables, FlashbackPublicWishQuery, FlashbackPublicWishQueryVariables, FlashbackWishCitiesQuery } from './generated/graphql'
import { mapPublicWishEcho, type ViewerWish } from '@/domain/flashback'
import type { VoiceCity } from '@/domain/flashback-voices'
function mapWish(wish: FlashbackPublicWishesQuery['flashbackPublicWishes'][number]): ViewerWish {
  const echoes = (wish.echoes ?? []).map(mapPublicWishEcho).filter((echo): echo is NonNullable<typeof echo> => !!echo)
  return { ...wish, city: wish.city ?? null, echoes, latestEcho: wish.latestEcho ? mapPublicWishEcho(wish.latestEcho) : null, echoCount: echoes.length }
}
export async function getWishTree(variables: FlashbackPublicWishesQueryVariables): Promise<ViewerWish[]> {
  const data = await graphqlRequest<FlashbackPublicWishesQuery, FlashbackPublicWishesQueryVariables>(FlashbackPublicWishesQueryDocument, variables)
  return data.flashbackPublicWishes.map(mapWish)
}
export async function getPublicWish(wishId: string, voterKey: string): Promise<ViewerWish | null> {
  const data = await graphqlRequest<FlashbackPublicWishQuery, FlashbackPublicWishQueryVariables>(FlashbackPublicWishQueryDocument, { wishId, voterKey })
  return data.flashbackPublicWish ? mapWish(data.flashbackPublicWish) : null
}
export async function getWishCities(): Promise<VoiceCity[]> {
  const data = await graphqlRequest<FlashbackWishCitiesQuery, Record<string, never>>(FlashbackWishCitiesQueryDocument, {})
  return data.flashbackWishCities
}
