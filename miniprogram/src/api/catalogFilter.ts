import type { CourseFilterInput, EventFilterInput } from './generated/graphql'

/** CatalogSearch 查询的 filter 变量（#355 P2-10）。
 * - 钉死 status=open / visibility=public（与无关键词的 Catalog 文档同口径）
 * - keyword trim 后为空 → null：调用方退回无 filter 的 CatalogQueryDocument
 * - 非空 → title ilike `%kw%`（AshGraphql 自动暴露的 title 过滤器；venue 是
 *   jsonb map 无 ilike，地点搜索不做） */
export interface CatalogSearchVariables {
  eventFilter: EventFilterInput
  courseFilter: CourseFilterInput
}

export function catalogSearchVariables(keyword?: string): CatalogSearchVariables | null {
  const trimmed = keyword?.trim() ?? ''
  if (!trimmed) return null
  const pattern = `%${trimmed}%`
  return {
    eventFilter: {
      status: { eq: 'open' },
      visibility: { eq: 'public' },
      title: { ilike: pattern }
    },
    courseFilter: {
      status: { eq: 'open' },
      visibility: { eq: 'public' },
      title: { ilike: pattern }
    }
  }
}
