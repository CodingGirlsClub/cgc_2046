/**
 * 分享 sheet(R14 用户定稿 ③,从原独立页搬迁):遮罩+底部圆角面板+R37 opt-in+
 * 三入口(转发好友/朋友圈提示/保存卡片 canvas)。canvas 常驻渲染(保存时
 * createSelectorQuery 需节点已在),open 只控制遮罩显隐。
 *
 * corridor(微信端)与裁剪端薄壳共用;标题与保存动作由页面传入(页面持有
 * useShareAppMessage hook 与 capsule)。
 */
import { useState } from 'react'
import { Button, Canvas, Text, View } from '@tarojs/components'
import Taro from '@tarojs/taro'
import type { FlashbackMyCard } from '@/domain/models'
import { shareOptInState } from '@/domain/flashback'
import { SUMMARY_CARD_CANVAS_ID, saveFlashbackSummaryCard } from '@/platform/summary-card'
import styles from './index.module.css'
import { useQuoteLicense } from './useQuoteLicense'

export default function ShareSheet({
  open,
  title,
  me,
  onClose,
  onWrite
}: {
  open: boolean
  title: string
  me: FlashbackMyCard
  onClose: () => void
  onWrite: () => void
}) {
  const [saving, setSaving] = useState(false)
  const [shareOptIn, setShareOptIn] = useState(false)
  const { quoteBusy, submitLicense } = useQuoteLicense(onWrite)

  // R37 opt-in(判据 shareOptInState):勾选即开匿名档(span=卡片金句);取消勾选不动档位
  const optInMode = shareOptInState(me)

  const saveCard = async () => {
    if (saving) return
    setSaving(true)
    try {
      await saveFlashbackSummaryCard(me)
      onClose()
    } finally {
      setSaving(false)
    }
  }

  return (
    <>
      <Canvas id={SUMMARY_CARD_CANVAS_ID} canvasId={SUMMARY_CARD_CANVAS_ID} type="2d" className={styles.shareCanvas} />

      {open && (
        <View className={styles.shareMask} onClick={onClose}>
          <View className={styles.shareSheet} onClick={(event) => event.stopPropagation()}>
            <Text className={styles.shareSheetTitle}>{title}</Text>
            {optInMode !== 'hidden' && (
              <View
                className={`${styles.shareOptIn} ${optInMode === 'already' ? styles.shareOptInLocked : ''}`}
                data-testid="fb-share-optin"
                onClick={() => {
                  if (optInMode === 'already' || quoteBusy) return
                  const next = !shareOptIn
                  setShareOptIn(next)
                  if (!next) return
                  const span = me.quoteSpan && me.quoteQuestionKey
                    ? { questionKey: me.quoteQuestionKey, start: me.quoteSpan.start, len: me.quoteSpan.len }
                    : null
                  void submitLicense('anonymous', span).then((ok) => {
                    if (!ok) setShareOptIn(false)
                  })
                }}
              >
                <Text className={styles.shareOptInBox}>{shareOptIn ? '☑' : '☐'}</Text>
                <Text className={styles.shareOptInLabel}>
                  {optInMode === 'already'
                    ? '已允许闪念间把这句话展示在首页（档位可在上方调整）'
                    : '同时允许闪念间把这句话展示在首页'}
                </Text>
              </View>
            )}
            <View className={styles.shareEntries}>
              <Button className={styles.shareEntry} openType="share">
                <Text className={styles.shareEntryIcon}>💬</Text>
                <Text className={styles.shareEntryLabel}>转发给好友</Text>
              </Button>
              <View
                className={styles.shareEntry}
                onClick={() => Taro.showToast({ title: '朋友圈分享请点右上角「···」选择', icon: 'none' })}
              >
                <Text className={styles.shareEntryIcon}>📷</Text>
                <Text className={styles.shareEntryLabel}>朋友圈</Text>
              </View>
              <View className={styles.shareEntry} onClick={() => void saveCard()}>
                <Text className={styles.shareEntryIcon}>⬇️</Text>
                <Text className={styles.shareEntryLabel}>{saving ? '保存中…' : '保存卡片'}</Text>
              </View>
            </View>
            <Button className={styles.shareCancel} onClick={onClose}>
              取消
            </Button>
          </View>
        </View>
      )}
    </>
  )
}
