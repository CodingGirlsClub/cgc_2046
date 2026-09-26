/**
 * 闪念间回访页(裁剪端 tt/xhs 载体,微信端主入口已归长廊 Tab)。
 * U2 完整化:卡面/圈选/授权全部在 components/MyCard 单源;本页只持
 * load/token 双入口状态机 + 分享 hooks + ShareSheet(微信端 corridor 共用)。
 * tt/xhs 未注册长廊(页面文案含微信专属词,过不了 diversion 词表)——
 * 裁剪端用户从「我的」入口与成场通知深链到这里。
 */
import { useCallback, useState } from 'react'
import { Button, Text, View } from '@tarojs/components'
import Taro, { useDidShow, useShareAppMessage, useShareTimeline } from '@tarojs/taro'
import { api, FlashbackNotBoundError, SessionExpiredError } from '@/api'
import { FlashbackTokenInvalidError } from '@/domain/models'
import { STORAGE_KEYS } from '@/state/storage'
import { PageState } from '@/components/PageState'
import { shareMessage } from '@/domain/flashback'
import { buildFlashbackEntryPath } from '@/domain/share-route'
import type { FlashbackCapsule } from '@/domain/models'
import MyCard from '@/components/MyCard'
import ShareSheet from '@/components/MyCard/ShareSheet'
import styles from '@/components/MyCard/index.module.css'

// 裁剪端（抖音/小红书）未注册闪念间旅程页——分享卡片回落回访页自身
const isCut = process.env.TARO_ENV === 'tt' || process.env.TARO_ENV === 'xhs'

type LoadState =
  | { kind: 'loading' }
  | { kind: 'ready'; capsule: FlashbackCapsule }
  | { kind: 'not_bound' }
  | { kind: 'need_login' }
  | { kind: 'error'; message: string }

export default function FlashbackPage() {
  const [state, setState] = useState<LoadState>({ kind: 'loading' })
  const [shareSheet, setShareSheet] = useState(false)

  const load = useCallback(async () => {
    setState({ kind: 'loading' })
    // 双入口 token:失效即清(claim 后链接作废),按会话腿/无 token 重载
    const token = Taro.getStorageSync<string>(STORAGE_KEYS.flashbackToken) || null
    try {
      const capsule = await api.getFlashbackCapsule(null, token)
      setState({ kind: 'ready', capsule })
    } catch (error) {
      if (error instanceof FlashbackTokenInvalidError) {
        Taro.removeStorageSync(STORAGE_KEYS.flashbackToken)
        void load()
        return
      }
      if (error instanceof FlashbackNotBoundError) {
        setState({ kind: 'not_bound' })
        return
      }
      if (error instanceof SessionExpiredError) {
        setState({ kind: 'need_login' })
        return
      }
      setState({ kind: 'error', message: error instanceof Error ? error.message : '加载失败' })
    }
  }, [])

  useDidShow(() => { void load() })

  // R14 分享(··· 胶囊菜单常驻):标题动态相对年数;卡片落闪念间 Tab(#929;裁剪端回落本页)
  useShareAppMessage(() => {
    const me = state.kind === 'ready' ? state.capsule.me : null
    return {
      title: me ? shareMessage(me).title : '闪念间 · 找回当年的自己',
      path: isCut ? '/pages/flashback/index' : buildFlashbackEntryPath()
    }
  })
  useShareTimeline(() => {
    const me = state.kind === 'ready' ? state.capsule.me : null
    return { title: me ? shareMessage(me).title : '闪念间 · 找回当年的自己' }
  })

  if (state.kind === 'loading') {
    return <PageState kind="loading" title="正在显影…" />
  }

  if (state.kind === 'need_login') {
    return (
      <View className={styles.page}>
        <View className={styles.stateBlock}>
          <Text className={styles.stateText}>登录后可以看到你的闪念间档案</Text>
          <Button className={styles.stateAction} onClick={() => Taro.navigateTo({ url: '/pages/login/index' })}>去登录</Button>
        </View>
      </View>
    )
  }

  if (state.kind === 'not_bound') {
    return (
      <View className={styles.page}>
        <View className={styles.stateBlock}>
          <Text className={styles.stateText}>
            {/* 本页只在裁剪端（tt/xhs）注册：零导流，不引导去其他端找回 */}
            你的账号还没有绑定闪念间档案。{'\n'}打开我们发给你的专属链接完成首程。
          </Text>
        </View>
      </View>
    )
  }

  if (state.kind === 'error') {
    return <PageState kind="error" message={state.message} onRetry={() => void load()} />
  }

  const { capsule } = state

  return (
    <View className={styles.page}>
      <View className={styles.board}>
        <MyCard
          capsule={capsule}
          token={Taro.getStorageSync<string>(STORAGE_KEYS.flashbackToken) || null}
          onWrite={() => void load()}
          onOpenShare={() => setShareSheet(true)}
        />
      </View>
      <ShareSheet
        open={shareSheet}
        title={shareMessage(capsule.me).title}
        me={capsule.me}
        onClose={() => setShareSheet(false)}
        onWrite={() => void load()}
      />
    </View>
  )
}
