import { PropsWithChildren, useEffect } from 'react'
import Taro, { useLaunch } from '@tarojs/taro'
import { STORAGE_KEYS } from '@/state/storage'
import { resolveAppShowRoute } from '@/domain/share-route'
import './app.css'

function App({ children }: PropsWithChildren) {
  useLaunch((options) => {
    const scene = options.query?.scene
    if (scene) {
      Taro.setStorageSync(STORAGE_KEYS.pendingScene, scene)
      setTimeout(() => Taro.navigateTo({ url: `/pages/join/index?scene=${encodeURIComponent(scene)}` }), 0)
    }
  })

  // 热启动（F05 复发面闭合，plan 011 D-2）：小程序已打开再点 scheme/分享链接
  // → onAppShow query 路由（scene 优先 join；id+kind 且不在 event-detail 才跳详情）。
  useEffect(() => {
    const handler = (options: Taro.onAppShow.CallbackResult) => {
      const query = options?.query ?? {}
      const scene = query.scene
      if (scene) Taro.setStorageSync(STORAGE_KEYS.pendingScene, scene)

      const pages = Taro.getCurrentPages()
      const currentRoute = pages.length > 0 ? pages[pages.length - 1].route ?? '' : ''
      const url = resolveAppShowRoute(query, currentRoute)
      if (url) Taro.navigateTo({ url })
    }
    Taro.onAppShow(handler)
    return () => Taro.offAppShow(handler)
  }, [])

  return children
}

export default App
