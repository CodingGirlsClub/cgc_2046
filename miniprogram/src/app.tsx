import { PropsWithChildren } from 'react'
import Taro, { useDidShow } from '@tarojs/taro'
import { STORAGE_KEYS } from '@/state/storage'
import { applyEntry, type EntryTaro } from '@/domain/entry'
import './app.css'

function App({ children }: PropsWithChildren) {
  // App onShow runs on both cold launch and warm entry. One lifecycle avoids
  // routing the same launch twice through useLaunch and a separate wx listener.
  useDidShow((options: Taro.onAppShow.CallbackResult) => {
    setTimeout(
      () => applyEntry(Taro as unknown as EntryTaro, options, STORAGE_KEYS.pendingScene),
      0
    )
  })
  return children
}

export default App
