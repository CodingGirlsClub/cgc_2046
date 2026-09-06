import { useState } from 'react'
import { Button, Image, Text, View } from '@tarojs/components'
import Taro, { useRouter } from '@tarojs/taro'
import { api } from '@/api'
import type { PlatformPhonePayload } from '@/domain/models'
import { preparePlatformLogin } from '@/platform'
import styles from './index.module.css'
import flameLogo from '@/assets/brand/cgc-flame.png'

// 裁剪端（抖音/小红书）不注册 privacy 页（政策原文含「微信」等词，
// 过不了 CI check:diversion 词表）——协议文案在裁剪端保持纯文本
const isCut = process.env.TARO_ENV === 'tt' || process.env.TARO_ENV === 'xhs'

export default function LoginPage() {
  const router = useRouter()
  const [dialogVisible, setDialogVisible] = useState(false)
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
      <Text className={styles.title} data-testid='login-title'>手机号快捷登录</Text>

      <View className={styles.permissions}>
        <Text className={styles.permission}>✓ 创建或绑定你的程序媛汇账号</Text>
        <Text className={styles.permission}>✓ 保存 7 天登录状态</Text>
        <Text className={styles.permission}>✓ 后续通知仍需你逐次授权</Text>
      </View>

      {error && <Text className={styles.error} data-testid='login-error'>{error}</Text>}
      <Button
        className={styles.loginButton}
        data-testid='platform-login'
        onClick={() => setDialogVisible(true)}
      >
        手机号快捷登录
      </Button>
      {dialogVisible && (
        <View className={styles.dialogMask} data-testid='agree-dialog' onClick={() => setDialogVisible(false)}>
          <View className={styles.dialog} onClick={(event) => event.stopPropagation()}>
            <Text className={styles.dialogTitle}>隐私授权说明</Text>
            <Text className={styles.dialogBody}>
              请阅读并同意
              {isCut ? (
                '《隐私授权说明》'
              ) : (
                <Text className={styles.agreementLink} onClick={() => Taro.navigateTo({ url: '/pages/privacy/index' })}>《隐私授权说明》</Text>
              )}
              。同意后我们将通过手机号创建或绑定你的程序媛汇账号。
            </Text>
            <View className={styles.dialogActions}>
              <Button
                className={`${styles.dialogButton} ${styles.dialogSecondary}`}
                onClick={() => setDialogVisible(false)}
              >
                不同意
              </Button>
              <Button
                className={`${styles.dialogButton} ${styles.dialogPrimary}`}
                data-testid='agree-login'
                openType={__E2E_MOCK__ ? undefined : 'getPhoneNumber'}
                loading={submitting}
                disabled={submitting}
                onClick={__E2E_MOCK__ ? () => { setDialogVisible(false); void login() } : undefined}
                onGetPhoneNumber={(event) => { setDialogVisible(false); void login(event.detail) }}
              >
                {submitting ? '正在登录…' : '同意并登录'}
              </Button>
            </View>
          </View>
        </View>
      )}
      <Text className={styles.tagline}>Coding Girls Club · 程序媛汇 — 2016 → 2046</Text>
    </View>
  )
}
