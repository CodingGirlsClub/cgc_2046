import { useEffect, useState } from 'react'
import { Text, View } from '@tarojs/components'
import Taro, { useDidShow } from '@tarojs/taro'
import { hasWorkspaceTab, subscribeWorkspaceTab } from '@/state/workspaceTab'
import {
  CUT_TABS,
  FULL_HEAD_TABS,
  FULL_TAIL_TABS,
  WORKSPACE_TAB,
  type TabDef,
  type TabKey
} from '@/domain/tab-routes'
import styles from './index.module.css'

interface Props { selected: TabKey }

// 裁剪端（抖音/小红书）：固定 2 Tab 漏斗，无工作台/我的
const isCut = process.env.TARO_ENV === 'tt' || process.env.TARO_ENV === 'xhs'

export function AppTabBar({ selected }: Props) {
  const [showWorkspace, setShowWorkspace] = useState(hasWorkspaceTab)

  // 藏原生 TabBar：本组件是自绘实现，原生那层必须藏掉，否则两层叠加。
  // 调用点要两个——useDidShow 在**组件内**会错过页面首帧（页面 onShow 早于
  // 组件挂载，实测 corridor 首次进入时仅靠它不生效，且 .catch 把失败吞了），
  // mount 后补一次；每次切回本页微信会重新显示原生栏，故 onShow 侧保留。
  const hideNativeTabBar = () => {
    Taro.hideTabBar({ animation: false }).catch(() => undefined)
  }

  useDidShow(() => {
    hideNativeTabBar()
    setShowWorkspace(hasWorkspaceTab())
  })

  useEffect(() => {
    hideNativeTabBar()
  }, [])

  useEffect(() => (isCut ? undefined : subscribeWorkspaceTab(setShowWorkspace)), [])

  // Tab 清单单源在 domain/tab-routes；本组件只负责渲染与「能力条件段」的增减
  const tabs: readonly TabDef[] = isCut
    ? CUT_TABS
    : [...FULL_HEAD_TABS, ...(showWorkspace ? [WORKSPACE_TAB] : []), ...FULL_TAIL_TABS]

  return (
    <View className={styles.bar}>
      {tabs.map((tab) => (
        <View
          key={tab.key}
          className={`${styles.item} ${selected === tab.key ? styles.selected : ''}`}
          data-testid={`tab-${tab.key}`}
          onClick={() => Taro.switchTab({ url: tab.path })}
        >
          <View className={`${styles.icon} ${styles[`icon_${tab.key}`]}`} />
          <Text className={styles.text}>{tab.text}</Text>
        </View>
      ))}
    </View>
  )
}
