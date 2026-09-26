import { useState } from 'react'
import { Button, Image, Text, View } from '@tarojs/components'
import Taro, { useRouter } from '@tarojs/taro'
import { api } from '@/api'
import type { PlatformPhonePayload } from '@/domain/models'
import { CUT_TAB_PATHS, FULL_TAB_PATHS, XHS_TAB_PATHS, isTabPath } from '@/domain/tab-routes'
import { platformLoginCode, preparePlatformLogin } from '@/platform'
import styles from './index.module.css'
import flameLogo from '@/assets/brand/cgc-flame.png'

// 《隐私授权说明》可点开 = 本端注册了 privacy 页：微信全量端（原文）与小红书
// （P0-5 起注册，正文为 D7 变体）；抖音端政策原文含「微信」等词过不了
// check:diversion 词表，保持纯文本。
const env = process.env.TARO_ENV
const isCut = env === 'tt' || env === 'xhs'
const privacyLinkable = env === 'weapp' || env === 'xhs'

/** Tab 页清单（单源 domain/tab-routes）：回跳目标若是 Tab 页须 switchTab */
const TAB_PATHS = env === 'xhs' ? XHS_TAB_PATHS : isCut ? CUT_TAB_PATHS : FULL_TAB_PATHS

export default function LoginPage() {
  const router = useRouter()
  const [dialogVisible, setDialogVisible] = useState(false)
  const [submitting, setSubmitting] = useState(false)
  const [error, setError] = useState('')

  // 登录成功后的去向（手机号登录与回访静默登录共用）
  const finish = async () => {
    const returnUrl = router.params.returnUrl
    if (returnUrl) {
      const target = decodeURIComponent(returnUrl)
      // 回跳目标可能是 tabBar 页面（如长廊）：redirectTo 跳 Tab 页会失败，
      // 必须 switchTab——清单单源在 domain/tab-routes
      if (isTabPath(target, TAB_PATHS)) await Taro.switchTab({ url: target })
      else await Taro.redirectTo({ url: target })
    } else if (Taro.getCurrentPages().length > 1) await Taro.navigateBack()
    // 登录成功后落「我的」Tab：抖音未注册「我的」页，落「我的报名」Tab；
    // 小红书（D2a）落精简「我的」（pages/profile-lite）；微信落全量「我的」
    else {
      await Taro.switchTab({
        url:
          process.env.TARO_ENV === 'xhs'
            ? '/pages/profile-lite/index'
            : isCut
              ? '/pages/my-enrollments/index'
              : '/pages/profile/index'
      })
    }
  }

  // #930 点「手机号快捷登录」先试回访静默登录：本平台已绑定身份的账号一步到位（不弹协议框、
  // 不走计费的手机号授权——协议在首次登录时已同意）；没绑定 / 主动退出后 / 任何失败 → 照旧弹协议框
  const startLogin = async () => {
    if (submitting) return
    setSubmitting(true)
    setError('')
    let signedIn = false
    try {
      signedIn = (await api.signInSilently(await platformLoginCode())) !== null
    } catch {
      // 静默失败不挡登录：退回手机号登录
    }
    try {
      if (signedIn) await finish()
    } finally {
      setSubmitting(false)
    }
    if (!signedIn) setDialogVisible(true)
  }

  const login = async (payload: PlatformPhonePayload = {}) => {
    if (submitting) return
    setSubmitting(true)
    setError('')
    try {
      const prepared = await preparePlatformLogin(payload)
      await api.signIn(prepared)
      await finish()
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
        loading={submitting && !dialogVisible}
        onClick={() => void startLogin()}
      >
        手机号快捷登录
      </Button>
      {dialogVisible && (
        <View className={styles.dialogMask} data-testid='agree-dialog' onClick={() => setDialogVisible(false)}>
          <View className={styles.dialog} onClick={(event) => event.stopPropagation()}>
            <Text className={styles.dialogTitle}>隐私授权说明</Text>
            <Text className={styles.dialogBody}>
              请阅读并同意
              {privacyLinkable ? (
                <Text className={styles.agreementLink} onClick={() => Taro.navigateTo({ url: '/pages/privacy/index' })}>《隐私授权说明》</Text>
              ) : (
                '《隐私授权说明》'
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
