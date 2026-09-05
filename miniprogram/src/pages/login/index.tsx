import { useState } from 'react'
import { Button, Image, Text, View } from '@tarojs/components'
import Taro, { useRouter } from '@tarojs/taro'
import { api } from '@/api'
import type { PlatformPhonePayload } from '@/domain/models'
import { preparePlatformLogin } from '@/platform'
import styles from './index.module.css'
import flameLogo from '@/assets/brand/cgc-flame.png'

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
      // 裁剪端（抖音/小红书）未注册「我的」页，fallback 落回已注册的「我的报名」
      else {
        const fallbackTab = process.env.TARO_ENV === 'tt' || process.env.TARO_ENV === 'xhs'
          ? '/pages/my-enrollments/index'
          : '/pages/profile/index'
        await Taro.switchTab({ url: fallbackTab })
      }
    } catch (reason) {
      setError(reason instanceof Error ? reason.message : '登录失败，请重试')
    } finally {
      setSubmitting(false)
    }
  }

  return (
    <View className={styles.page}>
      <Image className={styles.mark} src={flameLogo} mode='aspectFit' />
      <Text className={styles.brandName}>程序媛汇 <Text className={styles.brandYear}>2046</Text></Text>
      <Text className={styles.title} data-testid='login-title'>手机号一键登录</Text>
      <Text className={styles.description}>用于确认身份、同步报名状态和接收审批结果。程序媛汇不会向其他人公开你的手机号。</Text>

      <View className={styles.permissions}>
        <Text className={styles.permission}>✓ 创建或绑定你的程序媛汇账号</Text>
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
        {submitting ? '正在登录…' : `${__PLATFORM_NAME__}手机号快捷登录`}
      </Button>
      <Text className={styles.agreement}>
        登录即表示你同意隐私授权说明
        {process.env.TARO_ENV !== 'tt' && process.env.TARO_ENV !== 'xhs' ? '；可在「我的」中退出' : ''}。
      </Text>
      <Text className={styles.tagline}>Coding Girls Club · 程序媛汇 — 2016 → 2046</Text>
    </View>
  )
}
