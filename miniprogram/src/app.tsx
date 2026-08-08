import { PropsWithChildren } from 'react'
import { useLaunch } from '@tarojs/taro'
import './app.css'

function App({ children }: PropsWithChildren) {
  useLaunch(() => {
    console.log(`App launched, platform = ${process.env.TARO_ENV}`)
  })

  // children 是将要渲染的页面
  return children
}

export default App
