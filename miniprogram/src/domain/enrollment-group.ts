import type { EnrollmentSummary } from './models'

/**
 * #411 我的报名——同活动多条记录折叠（纯展示层，不删历史、不改状态机）。
 *
 * 同一 (kind, targetId) 反复拒绝/重报产生多条记录；列表按组折叠：
 * 最新条原样渲染（全部操作按钮只属于它），其余进「历史记录」只读区。
 *
 * 组内按 insertedAt desc 排（首条为 latest）；组间顺序 = 各组最新条的
 * insertedAt desc。服务端列表已按 inserted_at desc 排序（enrollment.ex
 * read/my_enrollments 显式 sort），这里仅按 target 聚合并二次确认组内序。
 */
export interface EnrollmentGroup {
  /** 组内最新一条（卡片主体） */
  latest: EnrollmentSummary
  /** 除最新外的历史记录，insertedAt desc（只读，无操作按钮） */
  history: EnrollmentSummary[]
}

export function groupEnrollmentsByTarget(items: EnrollmentSummary[]): EnrollmentGroup[] {
  const byTarget = new Map<string, EnrollmentSummary[]>()
  for (const item of items) {
    const key = `${item.kind}:${item.targetId}`
    const bucket = byTarget.get(key)
    if (bucket) bucket.push(item)
    else byTarget.set(key, [item])
  }

  const groups = [...byTarget.values()].map((records) => {
    const sorted = [...records].sort((a, b) => b.insertedAt.localeCompare(a.insertedAt))
    return { latest: sorted[0], history: sorted.slice(1) }
  })

  // 组间按各组最新条 insertedAt desc（与整体时间线一致的阅读顺序）
  groups.sort((a, b) => b.latest.insertedAt.localeCompare(a.latest.insertedAt))
  return groups
}
