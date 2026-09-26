/**
 * 删除我的档案（#931，与 web components/flashback/delete-account.tsx 同两步）：
 * 先取摘要（将失去什么），逐字输入 DELETE 才能提交；不可逆。成功后清本机 token、
 * 展示终态，由页面决定去向。判据与文案单源在 domain/flashback-retract。
 */
import { useEffect, useRef, useState } from 'react'
import { Button, Input, Text, View } from '@tarojs/components'
import Taro from '@tarojs/taro'
import { api } from '@/api'
import { STORAGE_KEYS } from '@/state/storage'
import {
  DELETE_CONFIRM_WORD,
  DELETE_COPY,
  canSubmitDelete,
  deleteFacts,
  type FlashbackDeletePreview
} from '@/domain/flashback-retract'
import styles from './index.module.css'

export function FlashbackDeleteSheet({ onClose, onDeleted }: { onClose: () => void; onDeleted: () => void }) {
  const [preview, setPreview] = useState<FlashbackDeletePreview | null>(null)
  const [input, setInput] = useState('')
  const [busy, setBusy] = useState(false)
  const [error, setError] = useState('')
  const [done, setDone] = useState(false)
  const alive = useRef(true)
  useEffect(() => () => { alive.current = false }, [])

  const token = () => Taro.getStorageSync<string>(STORAGE_KEYS.flashbackToken) || null

  useEffect(() => {
    api.flashbackDeletePreview(token())
      .then((row) => { if (alive.current) setPreview(row) })
      .catch(() => { if (alive.current) setError(DELETE_COPY.error) })
  }, [])

  const submit = async () => {
    if (!canSubmitDelete(input, busy)) return
    setBusy(true)
    setError('')
    try {
      await api.flashbackDelete(token(), DELETE_CONFIRM_WORD)
      // 链接即身份：删除后本机 token 同步作废（与 web 清 sessionStorage 同语义）
      Taro.removeStorageSync(STORAGE_KEYS.flashbackToken)
      if (alive.current) setDone(true)
    } catch {
      if (alive.current) setError(DELETE_COPY.error)
    } finally {
      if (alive.current) setBusy(false)
    }
  }

  return (
    <View className={styles.deleteMask} catchMove onClick={() => { if (!busy && !done) onClose() }}>
      <View className={styles.deleteSheet} onClick={(event) => event.stopPropagation()}>
        {done ? (
          <>
            <Text className={styles.deleteTitle}>{DELETE_COPY.doneTitle}</Text>
            <Text className={styles.deleteBody}>{DELETE_COPY.doneBody}</Text>
            <Button className={styles.deleteBack} onClick={onDeleted}>回到闪念间</Button>
          </>
        ) : (
          <>
            <Text className={styles.deleteTitle}>{DELETE_COPY.title}</Text>
            <Text className={styles.deleteBody}>{DELETE_COPY.warning}</Text>
            {error ? <Text className={styles.deleteError}>{error}</Text> : null}
            {preview ? deleteFacts(preview).map((fact) => <Text key={fact} className={styles.deleteFact}>· {fact}</Text>) : null}
            <Text className={styles.deleteLabel}>{DELETE_COPY.confirmLabel}</Text>
            <Input
              className={styles.deleteInput}
              value={input}
              placeholder={DELETE_CONFIRM_WORD}
              disabled={busy}
              onInput={(event) => setInput(event.detail.value)}
            />
            <Button className={styles.deleteSubmit} disabled={!canSubmitDelete(input, busy)} loading={busy} onClick={() => void submit()}>
              {DELETE_COPY.submit}
            </Button>
            <Button className={styles.deleteCancel} disabled={busy} onClick={onClose}>{DELETE_COPY.cancel}</Button>
          </>
        )}
      </View>
    </View>
  )
}
