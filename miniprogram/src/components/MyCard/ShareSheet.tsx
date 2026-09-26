/**
 * 分享 sheet(R14 用户定稿 ③,从原独立页搬迁):遮罩+底部圆角面板+R37 opt-in
 * + 入口三件套(转发好友/朋友圈提示/保存卡片 canvas)。入口与 canvas 均按平台
 * 派生（P0-6：xhs 无朋友圈概念、无 Canvas 2D → 只保留转发，判据单源
 * domain/flashback.ts shareSheetEntries）；有保存入口时 canvas 常驻渲染
 * （保存时 createSelectorQuery 需节点已在）,open 只控制遮罩显隐。
 *
 * corridor(微信端)与裁剪端薄壳共用;标题与保存动作由页面传入(页面持有
 * useShareAppMessage hook 与 capsule)。
 *
 * R37 opt-in 只出现在「圈了金句但还没授权」这一个窗口（判据 shareOptInState）——
 * 那是授权意愿最高的时刻（刚亲手挑出一句想让别人看到的话）；已授权则显示
 * 锁定态告知，没有金句则整个不出现。
 */
import { useState } from 'react'
import { Button, Canvas, Text, View } from '@tarojs/components'
import Taro from '@tarojs/taro'
import type { FlashbackMyCard } from '@/domain/models'
import { shareSheetEntries, type FlashbackCardMode } from '@/domain/flashback'
import { currentPlatform } from '@/platform'
import { CARD_CANVAS_ID, saveFlashbackCard } from '@/platform/flashback-card'
import QuoteOptIn from './QuoteOptIn'
import styles from './index.module.css'

// 面板入口按平台派生（P0-6：xhs 无朋友圈概念、无 Canvas 2D——只保留转发；
// 判据单源 domain/flashback.ts shareSheetEntries）
const entries = shareSheetEntries(currentPlatform())

export default function ShareSheet({
  open,
  title,
  me,
  mode = 'summary',
  onClose,
  onWrite
}: {
  open: boolean
  title: string
  me: FlashbackMyCard
  /** 保存哪一态（裁剪端薄壳页固定摘要卡；卡片页按当前切换态传入） */
  mode?: FlashbackCardMode
  onClose: () => void
  /** opt-in 提交授权后通知页面 reload（档位以服务端为准） */
  onWrite: () => void
}) {
  const [saving, setSaving] = useState(false)

  const saveCard = async () => {
    if (saving) return
    setSaving(true)
    try {
      await saveFlashbackCard(me, mode)
      onClose()
    } finally {
      setSaving(false)
    }
  }

  return (
    <>
      {/* canvas 只服务于「保存卡片」入口；该入口被平台裁剪时（xhs 无 Canvas 2D）
          一并省掉节点，杜绝「画了但永远没人读」静默浪费 */}
      {entries.includes('saveCard') && (
        <Canvas id={CARD_CANVAS_ID} canvasId={CARD_CANVAS_ID} type="2d" className={styles.shareCanvas} />
      )}

      {open && (
        <View className={styles.shareMask} catchMove onClick={onClose}>
          <View className={styles.shareSheet} onClick={(event) => event.stopPropagation()}>
            <Text className={styles.shareSheetTitle}>{title}</Text>
            <QuoteOptIn me={me} onWrite={onWrite} />
            <View className={styles.shareEntries}>
              <Button className={styles.shareEntry} openType="share">
                <Text className={styles.shareEntryIcon}>💬</Text>
                <Text className={styles.shareEntryLabel}>转发给好友</Text>
              </Button>
              {entries.includes('timeline') && (
                <View
                  className={styles.shareEntry}
                  onClick={() => Taro.showToast({ title: '朋友圈分享请点右上角「···」选择', icon: 'none' })}
                >
                  <Text className={styles.shareEntryIcon}>📷</Text>
                  <Text className={styles.shareEntryLabel}>朋友圈</Text>
                </View>
              )}
              {entries.includes('saveCard') && (
                <View className={styles.shareEntry} onClick={() => void saveCard()}>
                  <Text className={styles.shareEntryIcon}>⬇️</Text>
                  <Text className={styles.shareEntryLabel}>{saving ? '保存中…' : '保存卡片'}</Text>
                </View>
              )}
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
