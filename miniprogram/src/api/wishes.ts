import { graphqlRequest } from './client'
import { FlashbackMyWishesQueryDocument } from './operations'
import type { FlashbackMyWishesQuery, FlashbackMyWishesQueryVariables } from './generated/graphql'
import type { MyWishes } from '@/domain/wish-writing'
export async function getMyWishes(): Promise<MyWishes> {
  const data = await graphqlRequest<FlashbackMyWishesQuery, FlashbackMyWishesQueryVariables>(FlashbackMyWishesQueryDocument, {})
  const result = data.flashbackMyWishes
  if (!result) throw new Error('暂时无法读取我的愿望，请重试。')
  return { quotaRemaining: result.quotaRemaining, wishes: result.wishes.map(wish => ({ ...wish, city: wish.city ?? null })) }
}
