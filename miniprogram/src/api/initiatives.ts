import { graphqlRequest } from './client'
import type { PublicInitiative, PublicInitiativeCard } from '@/domain/models'

import { PublicInitiativesQueryDocument, PublicInitiativeQueryDocument } from './operations'

export async function getPublicInitiatives(): Promise<PublicInitiativeCard[]> {
  const data = await graphqlRequest<{ publicInitiatives: PublicInitiativeCard[] }, Record<string, never>>(PublicInitiativesQueryDocument, {})
  return data.publicInitiatives
}

export async function getPublicInitiative(slug: string): Promise<PublicInitiative | null> {
  const data = await graphqlRequest<{ publicInitiative: PublicInitiative | null }, { slug: string }>(PublicInitiativeQueryDocument, { slug })
  return data.publicInitiative
}
