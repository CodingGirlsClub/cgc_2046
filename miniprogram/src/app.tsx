import { PropsWithChildren, useEffect } from 'react'
import Taro, { useLaunch } from '@tarojs/taro'
import { STORAGE_KEYS } from '@/state/storage'
import { applyEntry, type EntryTaro } from '@/domain/entry'
import './app.css'

function App({ children }: PropsWithChildren) {
  // 冷启动：useLaunch 与 onAppShow 共用同一条落地路径——原实现只解 scene，
  // id/slug 深链（scheme / 小程序码，冷启动为主）被静默丢弃。
  // 决策与落地在 domain/entry（可测；页面栈每次现取，冷启动的重复导航抑制
  // 见 EntryDecision.navigate）。
  useLaunch((options) => {
    setTimeout(
      () => applyEntry(Taro as unknown as EntryTaro, options, STORAGE_KEYS.pendingScene),
      0
    )
  })

  // 热启动（F05 复发面闭合，plan 011 D-2）：小程序已打开再点 scheme/分享链接
  // → onAppShow query 路由，与冷启动同一判定。
  useEffect(() => {
    const handler = (options: Taro.onAppShow.CallbackResult) => {
      applyEntry(Taro as unknown as EntryTaro, options, STORAGE_KEYS.pendingScene)
    }
    Taro.onAppShow(handler)
    return () => Taro.offAppShow(handler)
  }, [])

  return children
}

export default App
