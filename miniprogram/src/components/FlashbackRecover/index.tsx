/**
 * 小程序内找回（#932）：已登录但没匹配到档案的人（当年用别的号码报名）凭当年的手机号 /
 * 邮箱找回——手机号验证后绑定到当前账号；邮箱走找回邮件里的网页入口。发起命中与未命中
 * 同形（防枚举），面板照同一条路走。判据与文案单源在 domain/flashback-recover。
 */
import { useEffect, useRef, useState } from 'react'
import { Button, Input, Text, View } from '@tarojs/components'
import { api } from '@/api'
import { BusinessError } from '@/api/business-error'
import { RECOVER_COPY, canSendRecover, canVerifyRecover, recoverChannel, recoverDoneText } from '@/domain/flashback-recover'
import styles from './index.module.css'

type Step = 'identifier' | 'code' | 'email' | 'done'

export function FlashbackRecoverSheet({ onClose, onRecovered }: { onClose: () => void; onRecovered: () => void }) {
  const [step, setStep] = useState<Step>('identifier')
  const [identifier, setIdentifier] = useState('')
  const [code, setCode] = useState('')
  const [count, setCount] = useState(0)
  const [busy, setBusy] = useState(false)
  const [error, setError] = useState('')
  const alive = useRef(true)
  useEffect(() => () => { alive.current = false }, [])

  const run = async (action: () => Promise<void>) => {
    setBusy(true)
    setError('')
    try {
      await action()
    } catch (reason) {
      // 业务码已映射中文（错码 / 号码属于另一个账号 / 限流）；其余不透出英文原文
      if (alive.current) setError(reason instanceof BusinessError ? reason.message : RECOVER_COPY.errorRetry)
    } finally {
      if (alive.current) setBusy(false)
    }
  }

  const send = () => run(async () => {
    await api.flashbackRecover(identifier.trim())
    if (alive.current) setStep(recoverChannel(identifier) === 'email' ? 'email' : 'code')
  })

  const verify = () => run(async () => {
    const result = await api.flashbackRecoverVerifyForAccount(identifier.trim(), code.trim())
    if (!alive.current) return
    setCount(result.count)
    setStep('done')
  })

  return (
    <View className={styles.recoverMask} catchMove onClick={() => { if (!busy && step !== 'done') onClose() }}>
      <View className={styles.recoverSheet} onClick={(event) => event.stopPropagation()}>
        <Text className={styles.recoverTitle}>{RECOVER_COPY.title}</Text>
        {step === 'identifier' && (
          <>
            <Text className={styles.recoverBody}>{RECOVER_COPY.lead}</Text>
            <Input
              className={styles.recoverInput}
              value={identifier}
              placeholder={RECOVER_COPY.identifierPlaceholder}
              disabled={busy}
              onInput={(event) => setIdentifier(event.detail.value)}
            />
          </>
        )}
        {step === 'code' && (
          <>
            <Text className={styles.recoverBody}>{RECOVER_COPY.codeHint}</Text>
            <Input
              className={styles.recoverCodeInput}
              type='number'
              value={code}
              placeholder={RECOVER_COPY.codePlaceholder}
              disabled={busy}
              onInput={(event) => setCode(event.detail.value)}
            />
          </>
        )}
        {step === 'email' && <Text className={styles.recoverBody}>{RECOVER_COPY.emailHint}</Text>}
        {step === 'done' && <Text className={styles.recoverBody}>{recoverDoneText(count)}</Text>}
        {error ? <Text className={styles.recoverError}>{error}</Text> : null}
        {step === 'identifier' && (
          <Button className={styles.recoverSubmit} disabled={!canSendRecover(identifier, busy)} loading={busy} onClick={() => void send()}>
            {RECOVER_COPY.send}
          </Button>
        )}
        {step === 'code' && (
          <Button className={styles.recoverSubmit} disabled={!canVerifyRecover(code, busy)} loading={busy} onClick={() => void verify()}>
            {RECOVER_COPY.verify}
          </Button>
        )}
        {step === 'done' ? (
          <Button className={styles.recoverSubmit} onClick={onRecovered}>{RECOVER_COPY.back}</Button>
        ) : (
          <Button className={styles.recoverCancel} disabled={busy} onClick={onClose}>{RECOVER_COPY.close}</Button>
        )}
      </View>
    </View>
  )
}
