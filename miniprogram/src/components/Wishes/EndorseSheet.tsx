import { useRef, useState } from 'react'
import { Button, Text, Textarea, View } from '@tarojs/components'
import { api } from '@/api'
import { WISH_CONTRIBUTION_OPTIONS, WISH_ENDORSE_MESSAGE_MAX } from '@/domain/flashback'
import { wishEchoTouchpoint } from '@/domain/subscription'
import { endorseWithReminder, requestWishReminder, reminderReceipt, type WishReminderResult } from '@/domain/wish-reminder'
import { requestPlatformSubscriptions } from '@/platform'
import styles from './endorse-sheet.module.css'

type Props = { wish: { id: string; content: string }; onClose: () => void; onSaved: () => void; paper?: boolean }
export function EndorseWishSheet({ wish, onClose, onSaved, paper = false }: Props) {
  const [types, setTypes] = useState<string[]>([])
  const [message, setMessage] = useState('')
  const [notify, setNotify] = useState(true)
  const [busy, setBusy] = useState(false)
  const [error, setError] = useState('')
  const lock = useRef(false)
  const [saved, setSaved] = useState<WishReminderResult | null>(null)
  const receipt = saved ? reminderReceipt(saved) : null
  const close = () => { if (!busy) { if (saved) onSaved(); else onClose() } }
  const reminderDeps = { request: requestPlatformSubscriptions, grant: (scenario: Parameters<typeof api.grantConsent>[0]) => api.grantConsent(scenario) }
  const retryReminder = async () => {
    if (lock.current) return
    lock.current = true; setBusy(true)
    try { setSaved(await requestWishReminder(reminderDeps)) }
    finally { lock.current = false; setBusy(false) }
  }
  const submit = async () => {
    if (lock.current || saved || !types.length) return
    lock.current = true; setBusy(true); setError('')
    try {
      const result = await endorseWithReminder(notify, {
        ...reminderDeps,
        save: () => api.flashbackEndorseWish(wish.id, { contributionTypes: types, message: message.trim() || null, notify })
      })
      setSaved(result)
    } catch (reason) { setError(reason instanceof Error ? reason.message : '附议失败，请重试。') }
    finally { lock.current = false; setBusy(false) }
  }
  return <View className={`${styles.endorseMask} ${paper ? styles.paper : ''}`} catchMove onClick={close}>
    <View className={styles.sheet} onClick={event => event.stopPropagation()}>
      <View className={styles.heading}><Text className={styles.title}>我能出力</Text><Button className={styles.close} disabled={busy} onClick={close}>关闭</Button></View>
      <Text className={styles.preview}>{wish.content}</Text>
      {receipt ? <View className={styles.endorseReceipt}>
        <Text className={styles.receiptTitle}>感谢出力</Text>
        <Text className={styles.receiptCopy}>{receipt.copy}</Text>
        {receipt.canRetry && <Button className={styles.reminderRetry} disabled={busy} loading={busy} onClick={() => void retryReminder()}>重新订阅回响提醒</Button>}
        <Button className={styles.receiptDone} disabled={busy} onClick={close}>完成</Button>
      </View> : <>
      <View className={styles.types}>{WISH_CONTRIBUTION_OPTIONS.map(option => <Button key={option.type}
        className={`${styles.endorseChip} ${types.includes(option.type) ? styles.selected : ''}`} disabled={busy}
        onClick={() => setTypes(old => old.includes(option.type) ? old.filter(type => type !== option.type) : [...old, option.type])}>{option.label}</Button>)}</View>
      <Textarea className={styles.message} value={message} onInput={e => setMessage(e.detail.value)} disabled={busy} maxlength={WISH_ENDORSE_MESSAGE_MAX} placeholder='想对主办方说的（可选，500 字内）' />
      <Text className={styles.contact}>提交即同意主办方通过你账号绑定的手机号／邮箱与你联系对接，留言仅主办方可见。</Text>
      <Button className={styles.endorseNotify} disabled={busy} onClick={() => setNotify(!notify)}>{notify ? '☑' : '☐'} {wishEchoTouchpoint().label}</Button>
      {error && <Text className={styles.error}>{error}</Text>}
      <Button className={styles.endorseSubmit} disabled={busy || !types.length} loading={busy} onClick={() => void submit()}>{busy ? '提交中…' : '提交附议'}</Button>
      </>}
    </View>
  </View>
}
