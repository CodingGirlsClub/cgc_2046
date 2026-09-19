/**
 * 金句授权写操作(MyCard 换档/圈选 与 分享 sheet opt-in 共用,U2 完整化)。
 * 档位 + 圈选区间一起发——只发档位会把已选区间覆盖成空(R31/R35 后端语义)。
 * 成功/失败都通知父级 reload(授权是白名单行为,UI 态必须与库一致)。
 */
import { useCallback, useState } from 'react'
import Taro from '@tarojs/taro'
import { api } from '@/api'
import type { QuoteLevel } from '@/domain/flashback'

export interface QuoteSpanPick {
  questionKey: string
  start: number
  len: number
}

export function useQuoteLicense(reload: () => void) {
  const [quoteBusy, setQuoteBusy] = useState(false)

  const submitLicense = useCallback(
    async (level: QuoteLevel, picks: QuoteSpanPick[]): Promise<boolean> => {
      if (quoteBusy) return false
      setQuoteBusy(true)
      try {
        await api.flashbackSetQuoteLicense(level, level === 'off' ? null : picks)
        Taro.showToast({ title: '授权已更新', icon: 'none' })
        reload()
        return true
      } catch (error) {
        Taro.showToast({ title: error instanceof Error ? error.message : '设置失败', icon: 'none' })
        reload()
        return false
      } finally {
        setQuoteBusy(false)
      }
    },
    [quoteBusy, reload]
  )

  return { quoteBusy, submitLicense }
}
