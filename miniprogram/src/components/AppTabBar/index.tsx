import { useEffect, useState } from 'react'
import { Text, View } from '@tarojs/components'
import Taro, { useDidShow } from '@tarojs/taro'
import { hasWorkspaceTab, subscribeWorkspaceTab } from '@/state/workspaceTab'
import styles from './index.module.css'

type TabKey = 'discover' | 'enrollments' | 'workspace' | 'profile'

interface Props { selected: TabKey }

const baseTabs = [
  { key: 'discover' as const, text: '发现', icon: '⌕', path: '/pages/discover/index' },
  { key: 'enrollments' as const, text: '我的报名', icon: '✓', path: '/pages/my-enrollments/index' }
]

export function AppTabBar({ selected }: Props) {
  const [showWorkspace, setShowWorkspace] = useState(hasWorkspaceTab)

  useDidShow(() => {
    Taro.hideTabBar({ animation: false }).catch(() => undefined)
    setShowWorkspace(hasWorkspaceTab())
  })

  useEffect(() => subscribeWorkspaceTab(setShowWorkspace), [])

  const tabs = [
    ...baseTabs,
    ...(showWorkspace
      ? [{ key: 'workspace' as const, text: '工作台', icon: '◇', path: '/pages/workspace/index' }]
      : []),
    { key: 'profile' as const, text: '我的', icon: '○', path: '/pages/profile/index' }
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
