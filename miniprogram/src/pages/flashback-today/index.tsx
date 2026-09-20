/**
 * 今天回看页(今天格 lit 点击进入,F 摘要卡形态):「这张卡在别人眼里的
 * 样子」——今天的你三行(只读)+当年答案按句渲染(雾句=雾块示意对外
 * 隐藏,已授权金句浅金高亮)+署名;分享 CTA 接页面级 ShareSheet;
 * 底部隐私提示(原文不进卡/雾句不出现)降低授权焦虑。
 */
import { useCallback, useEffect, useState } from 'react'
import { Button, Text, View } from '@tarojs/components'
import Taro, { useShareAppMessage } from '@tarojs/taro'
import { api } from '@/api'
import { PageState } from '@/components/PageState'
import { TodayReview } from '@/components/MyCard'
import ShareSheet from '@/components/MyCard/ShareSheet'
import { parseQuoteLevel, shareMessage } from '@/domain/flashback'
import { STORAGE_KEYS } from '@/state/storage'
import { FlashbackTokenInvalidError } from '@/domain/models'
import type { FlashbackCapsule } from '@/domain/models'
import styles from './index.module.css'

export default function FlashbackTodayPage() {
  const [capsule, setCapsule] = useState<FlashbackCapsule | null>(null)
  const [error, setError] = useState('')
  const [shareSheet, setShareSheet] = useState(false)

  useEffect(() => {
    void Taro.setNavigationBarTitle({ title: '摘要卡' }).catch(() => {})
    void load()
    // eslint-disable-next-line react-hooks/exhaustive-deps -- 进页一次性加载
  }, [])

  const load = useCallback(async () => {
    setError('')
    try {
      const token = Taro.getStorageSync<string>(STORAGE_KEYS.flashbackToken) || null
      setCapsule(await api.getFlashbackCapsule(null, token))
    } catch (e) {
      if (e instanceof FlashbackTokenInvalidError) {
        Taro.removeStorageSync(STORAGE_KEYS.flashbackToken)
      }
      setError(e instanceof Error ? e.message : '加载失败')
    }
  }, [])

  useShareAppMessage(() => ({
    title: capsule ? shareMessage(capsule.me).title : '闪念间 · 找回当年的自己',
    path: '/pages/flashback-journey/index',
  }))

  // 首载失败可重试;token 失效清掉后按无 token 重拉(会话腿)
  if (error && !capsule) {
    return <PageState kind='error' message={error} onRetry={() => void load()} />
  }
  if (!capsule) {
    return <PageState kind='loading' title='正在显影…' />
  }

  return (
    <View className={styles.page}>
      <Text className={styles.head}>你的摘要卡 · 保存或分享</Text>
      <View className={styles.cardWrap}>
        <TodayReview
          me={capsule.me}
          level={parseQuoteLevel(capsule.me.quoteLevel)}
          onToggleTodayFog={(field, spans) => {
            const token = Taro.getStorageSync<string>(STORAGE_KEYS.flashbackToken) || null
            void api
              .flashbackAdjustTodayFog(field, spans, token)
              .then(() => load())
              .catch((error: unknown) =>
                Taro.showToast({
                  title: error instanceof Error ? error.message : '雾面调整失败',
                  icon: 'none'
                }),
              )
          }}
        />
      </View>
      <Button className={styles.cta} onClick={() => setShareSheet(true)}>
        分享 · 转发给朋友
      </Button>
      <Text className={styles.tip}>原文不会进卡片 · 你标记过雾面的句子不会出现</Text>
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
