import { useEffect, useState } from 'react'
import { Text, View } from '@tarojs/components'
import Taro, { useDidShow } from '@tarojs/taro'
import { hasWorkspaceTab, subscribeWorkspaceTab } from '@/state/workspaceTab'
import styles from './index.module.css'

type TabKey = 'discover' | 'flashback' | 'enrollments' | 'workspace' | 'profile'

interface Props { selected: TabKey }

/** 微信全量端基础 Tab（我的报名已降为「我的」页内入口，见 profile） */
const fullBaseTabs = [
  { key: 'discover' as const, text: '发现', icon: '⌕', path: '/pages/discover/index' },
  { key: 'flashback' as const, text: '闪念间', icon: '⚡', path: '/pages/flashback-corridor/index' }
]

/** 裁剪端（抖音/小红书）：2 Tab 漏斗——未注册长廊，故无闪念间；无「我的」页，
 *  故我的报名仍是 Tab（与 app.config cutTabList 同步） */
const cutTabs = [
  { key: 'discover' as const, text: '发现', icon: '⌕', path: '/pages/discover/index' },
  { key: 'enrollments' as const, text: '我的报名', icon: '✓', path: '/pages/my-enrollments/index' }
]

const workspaceTab = { key: 'workspace' as const, text: '工作台', icon: '◇', path: '/pages/workspace/index' }
const profileTab = { key: 'profile' as const, text: '我的', icon: '○', path: '/pages/profile/index' }

// 裁剪端（抖音/小红书）：固定 2 Tab 漏斗，无工作台/我的
const isCut = process.env.TARO_ENV === 'tt' || process.env.TARO_ENV === 'xhs'

export function AppTabBar({ selected }: Props) {
  const [showWorkspace, setShowWorkspace] = useState(hasWorkspaceTab)

  useDidShow(() => {
    Taro.hideTabBar({ animation: false }).catch(() => undefined)
    setShowWorkspace(hasWorkspaceTab())
  })

  useEffect(() => (isCut ? undefined : subscribeWorkspaceTab(setShowWorkspace)), [])

  const tabs = isCut
    ? cutTabs
    : [
        ...fullBaseTabs,
        ...(showWorkspace ? [workspaceTab] : []),
        profileTab
      ]

  return (
    <View className={styles.bar}>
      {tabs.map((tab) => (
        <View
          key={tab.key}
          className={`${styles.item} ${selected === tab.key ? styles.selected : ''}`}
          data-testid={`tab-${tab.key}`}
          onClick={() => Taro.switchTab({ url: tab.path })}
        >
          <Text className={styles.icon}>{tab.icon}</Text>
          <Text className={styles.text}>{tab.text}</Text>
        </View>
      ))}
    </View>
  )
}
