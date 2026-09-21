/**
 * 金句授权写操作(MyCard 换档/圈选 与 分享 sheet opt-in 共用,U2 完整化)。
 * 档位 + 圈选区间一起发——只发档位会把已选区间覆盖成空(R31/R35 后端语义)。
 * 成功/失败都通知父级 reload(授权是白名单行为,UI 态必须与库一致)。
 *
 * 关档(level='off')**不清圈选**:传现有 spans 即原值回写,用户的挑句劳动保留,
 * 撤回后可以立刻再开。`[]` 才是显式清空——档位选择器切到「关闭」沿用这条。
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
        // span 有值就带着发（**即使档位是 off**）：关档只关档，不清用户的圈选劳动，
        // 这样撤回后随时能再开（对称）。空数组 = 显式清空（档位选择器切档的既有语义）。
        await api.flashbackSetQuoteLicense(level, picks.length ? picks : null)
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
