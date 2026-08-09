import { useState } from 'react'
import { Button, Text, View } from '@tarojs/components'
import Taro, { useRouter } from '@tarojs/taro'
import { api } from '@/api'
import type { PlatformPhonePayload } from '@/domain/models'
import { preparePlatformLogin } from '@/platform'
import styles from './index.module.css'

export default function LoginPage() {
  const router = useRouter()
  const [submitting, setSubmitting] = useState(false)
  const [error, setError] = useState('')

  const login = async (payload: PlatformPhonePayload = {}) => {
    if (submitting) return
    setSubmitting(true)
    setError('')
    try {
      const prepared = await preparePlatformLogin(payload)
      await api.signIn(prepared)
      const returnUrl = router.params.returnUrl
      if (returnUrl) await Taro.redirectTo({ url: decodeURIComponent(returnUrl) })
      else if (Taro.getCurrentPages().length > 1) await Taro.navigateBack()
      else await Taro.switchTab({ url: '/pages/profile/index' })
    } catch (reason) {
      setError(reason instanceof Error ? reason.message : '登录失败，请重试')
    } finally {
      setSubmitting(false)
    }
  }

  return (
    <View className={styles.page}>
      <View className={styles.mark}>CGC</View>
      <Text className={styles.title} data-testid='login-title'>手机号一键登录</Text>
      <Text className={styles.description}>用于确认身份、同步报名状态和接收审批结果。CGC 不会向其他人公开你的手机号。</Text>

      <View className={styles.permissions}>
        <Text className={styles.permission}>✓ 创建或绑定你的 CGC 账号</Text>
        <Text className={styles.permission}>✓ 保存 7 天登录状态</Text>
        <Text className={styles.permission}>✓ 后续通知仍需你逐次授权</Text>
      </View>

      {error && <Text className={styles.error}>{error}</Text>}
      <Button
        className={styles.loginButton}
        data-testid='platform-login'
        openType={__E2E_MOCK__ ? undefined : 'getPhoneNumber'}
        loading={submitting}
        disabled={submitting}
        onClick={__E2E_MOCK__ ? () => login() : undefined}
        onGetPhoneNumber={(event) => login(event.detail)}
      >
        {submitting ? '正在登录…' : '微信手机号快捷登录'}
      </Button>
      <Text className={styles.agreement}>登录即表示你同意隐私授权说明；可在「我的」中退出。</Text>
    </View>
  )
}
