import { useState } from 'react'
import { Button, Input, Text, View } from '@tarojs/components'
import Taro, { useDidShow } from '@tarojs/taro'
import { api } from '@/api'
import {
  accountIdentifier,
  passwordFormErrorCopy,
  passwordSubmitErrorCopy,
  validateNewPassword
} from '@/domain/password-center'
import styles from './index.module.css'

/**
 * 小程序密码中心（R1–R6）。
 *
 * 页面只负责渲染与调起；预检与文案在 `domain/password-center.ts`。
 * 免旧密码：能完成小程序微信登录本身就是身份凭证（范围已裁决）。
 */
export default function AccountPasswordPage() {
  const [phone, setPhone] = useState<string | null>(null)
  const [password, setPassword] = useState('')
  const [confirmation, setConfirmation] = useState('')
  const [error, setError] = useState('')
  const [done, setDone] = useState(false)
  const [busy, setBusy] = useState(false)
  const [mode, setMode] = useState<'set' | 'reset'>('set')

  const load = async () => {
    try {
      const session = await api.getSession()
      if (!session.user) {
        const target = '/pages/account-password/index'
        await Taro.navigateTo({
          url: `/pages/login/index?returnUrl=${encodeURIComponent(target)}`
        })
        return
      }
      setPhone(await api.getMyPhone())
    } catch {
      setError('暂时无法加载账号信息，请重试。')
    }
  }

  useDidShow(() => {
    void load()
  })

  const submit = async () => {
    const invalid = validateNewPassword(password, confirmation)
    if (invalid) {
      setError(passwordFormErrorCopy(invalid))
      return
    }
    setBusy(true)
    setError('')
    setDone(false)
    try {
      await api.setPassword(password)
      setPassword('')
      setConfirmation('')
      setDone(true)
      await Taro.showToast({ title: '密码已更新', icon: 'success' })
    } catch (reason) {
      setError(passwordSubmitErrorCopy(reason instanceof Error ? reason.message : null))
    } finally {
      setBusy(false)
    }
  }

  return (
    <View className={styles.page}>
      <View className={styles.card}>
        <Text className={styles.title}>登录密码</Text>
        <Text className={styles.subtitle}>
          设置后可在电脑或桌面客户端用手机号 + 密码登录。
        </Text>
        <Text className={styles.identifier}>{accountIdentifier(phone)}</Text>

        <View className={styles.field}>
          <Text className={styles.label}>新密码（至少 8 位）</Text>
          <Input
            className={styles.input}
            password
            placeholder='输入新密码'
            onInput={(event) => setPassword(event.detail.value)}
          />
        </View>

        <View className={styles.field}>
          <Text className={styles.label}>再次输入</Text>
          <Input
            className={styles.input}
            password
            placeholder='再输一次'
            onInput={(event) => setConfirmation(event.detail.value)}
          />
        </View>

        {error && <Text className={styles.error}>{error}</Text>}
        {done && <Text className={styles.success}>密码已更新；其他设备需要重新登录。</Text>}

        <Button
          className={styles.primary}
          loading={busy}
          disabled={busy}
          onClick={() => void submit()}
        >
          {mode === 'reset' ? '重设密码' : '设置 / 修改密码'}
        </Button>
        <Button
          className={styles.secondary}
          disabled={busy}
          onClick={() => {
            setMode('reset')
            setError('')
            setDone(false)
            void Taro.showToast({ title: '直接输入新密码即可', icon: 'none' })
          }}
        >
          忘记原密码，直接重设
        </Button>

        <Text className={styles.notice}>
          两种方式都无需输入原密码：能登录这个小程序，就足以证明这是你的账号。
        </Text>
      </View>
    </View>
  )
}
