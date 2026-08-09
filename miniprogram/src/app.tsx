import { PropsWithChildren } from 'react'
import Taro, { useLaunch } from '@tarojs/taro'
import { STORAGE_KEYS } from '@/state/storage'
import './app.css'

function App({ children }: PropsWithChildren) {
  useLaunch((options) => {
    const scene = options.query?.scene
    if (scene) {
      Taro.setStorageSync(STORAGE_KEYS.pendingScene, scene)
      setTimeout(() => Taro.navigateTo({ url: `/pages/join/index?scene=${encodeURIComponent(scene)}` }), 0)
    }
  })
  return children
}

export default App
