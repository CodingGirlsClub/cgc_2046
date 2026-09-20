/**
 * 卡片页(今天格 lit 点击进入 / 长廊底部「把这一刻做成卡片」)：四态落版 +
 * 所见即所存。
 *
 * 四态 chip（顺序 = 用户价值序，`CARD_MODES` 单表）同时决定**预览**与**保存物**：
 *  - 合起来（默认：全貌，过去与现在并置，产品核心意象）
 *  - 当年的你 / 今天的你（两个拆解视图）
 *  - 摘要卡（金句版式，R14 分享默认物，固定 3:4）
 * 预览与 canvas 共用同一 model（domain 的 summaryCardModel / recordCardModel），
 * 换态即换存出来的东西。
 *
 * **两段都可点句切雾**（各自在被渲染时）——卡片页是寄出后全部内容唯一的
 * 雾化入口面（写入面不做雾化），不可回归。
 */
import { useCallback, useEffect, useState } from 'react'
import { Button, Canvas, Text, View } from '@tarojs/components'
import Taro, { useShareAppMessage } from '@tarojs/taro'
import { api } from '@/api'
import { PageState } from '@/components/PageState'
import { TodayReview } from '@/components/MyCard'
import QuoteOptIn from '@/components/MyCard/QuoteOptIn'
import { CARD_MODES, parseQuoteLevel, shareMessage, summaryCardModel, type FlashbackCardMode } from '@/domain/flashback'
import { CARD_CANVAS_ID, saveFlashbackCard } from '@/platform/flashback-card'
import { STORAGE_KEYS } from '@/state/storage'
import { FlashbackTokenInvalidError } from '@/domain/models'
import type { FlashbackCapsule } from '@/domain/models'
import styles from './index.module.css'

/** 摘要卡的 DOM 预览：与 canvas 同版式（居中、金句为主）。摘要卡口径不含
 *  雾句——`summaryCardModel` 已按此过滤，故预览与保存物一致。 */
function SummaryCardPreview({ me }: { me: FlashbackCapsule['me'] }) {
  const model = summaryCardModel(me)
  return (
    <View className={styles.summaryCard}>
      <Text className={styles.summaryKicker}>IN A FLASH · 闪念间</Text>
      <Text className={styles.summaryStamp}>{model.stamp || '当年'}</Text>
      <Text className={styles.summaryQuote}>“{model.quote}”</Text>
      {model.todayLine && <Text className={styles.summaryToday}>今天的我：{model.todayLine}</Text>}
      <Text className={styles.summaryFooter}>{model.footer}</Text>
    </View>
  )
}

export default function FlashbackTodayPage() {
  const [capsule, setCapsule] = useState<FlashbackCapsule | null>(null)
  const [error, setError] = useState('')
  const [mode, setMode] = useState<FlashbackCardMode>('both')
  const [saving, setSaving] = useState(false)

  useEffect(() => {
    void Taro.setNavigationBarTitle({ title: '卡片' }).catch(() => {})
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
    path: '/pages/flashback-journey/index'
  }))

  const saveCard = async () => {
    if (!capsule || saving) return
    setSaving(true)
    try {
      await saveFlashbackCard(capsule.me, mode)
    } catch (e) {
      Taro.showToast({ title: e instanceof Error ? e.message : '保存失败', icon: 'none' })
    } finally {
      setSaving(false)
    }
  }

  // 两段的点句切雾共用：读会话 token → 调对应 API → 重拉 capsule（雾态以服务端为准）
  const adjustFog = (call: (token: string | null) => Promise<void>) => {
    const token = Taro.getStorageSync<string>(STORAGE_KEYS.flashbackToken) || null
    void call(token)
      .then(() => load())
      .catch((error: unknown) =>
        Taro.showToast({
          title: error instanceof Error ? error.message : '雾面调整失败',
          icon: 'none'
        })
      )
  }

  // 首载失败可重试;token 失效清掉后按无 token 重拉(会话腿)
  if (error && !capsule) {
    return <PageState kind='error' message={error} onRetry={() => void load()} />
  }
  if (!capsule) {
    return <PageState kind='loading' title='正在显影…' />
  }

  return (
    <View className={styles.page}>
      <View className={styles.modeChips}>
        {CARD_MODES.map((item) => (
          <Text
            key={item.value}
            className={`${styles.modeChip} ${mode === item.value ? styles.modeChipActive : ''}`}
            data-testid={`card-mode-${item.value}`}
            onClick={() => setMode(item.value)}
          >
            {item.label}
          </Text>
        ))}
      </View>

      <View className={styles.cardWrap}>
        {mode === 'summary' ? (
          <SummaryCardPreview me={capsule.me} />
        ) : (
          <TodayReview
            me={capsule.me}
            level={parseQuoteLevel(capsule.me.quoteLevel)}
            mode={mode}
            onToggleTodayFog={(field, spans) => adjustFog((token) => api.flashbackAdjustTodayFog(field, spans, token))}
            onTogglePastFog={(answerId, spans) => adjustFog((token) => api.flashbackAdjustFog(answerId, spans, token))}
          />
        )}
      </View>

      <View className={styles.actions}>
        <Button
          className={styles.actionPrimary}
          data-testid='card-save'
          disabled={saving}
          onClick={() => void saveCard()}
        >
          {saving ? '保存中…' : '保存图片'}
        </Button>
        <Button className={styles.actionSecondary} data-testid='card-share' openType='share'>
          分享给朋友
        </Button>
      </View>

      {/* R37：授权引导只在「圈了金句但还没授权」时出现（判据在组件内）。
          放在按钮之后：勾是分享时的选项，紧贴分享按钮；tip 讲的是卡片本身，留在最底。
          plain 变体 = 去白底、字号更小——不让它读起来像分享的必填项。 */}
      <QuoteOptIn me={capsule.me} onWrite={() => void load()} variant='plain' />

      <Text className={styles.tip}>
        {mode === 'summary'
          ? '摘要卡只含未雾的句子 · 原文不会进卡片'
          : '点句子可切换雾面 · 雾面句对外不可见'}
      </Text>

      {/* 离屏画布（保存时节点需已在）——四态共用，尺寸由 domain 版式算出 */}
      <Canvas id={CARD_CANVAS_ID} canvasId={CARD_CANVAS_ID} type='2d' className={styles.cardCanvas} />
    </View>
  )
}
