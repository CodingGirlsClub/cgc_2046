import { useReducer, useState } from 'react'
import { Button, Input, Text, View } from '@tarojs/components'
import Taro, { useDidShow } from '@tarojs/taro'
import { api } from '@/api'
import {
  accountIdentifier,
  initialPasswordCenterState,
  passwordFormErrorCopy,
  passwordSubmitErrorCopy,
  reducePasswordCenter,
  validateNewPassword
} from '@/domain/password-center'
import styles from './index.module.css'

/**
 * 小程序密码中心（R1–R6）。
 *
 * 页面只做两件事：调起 API 与 dispatch；所有状态转移在
 * `domain/password-center.ts` 的 `reducePasswordCenter` 里，由
 * node --test 覆盖（本项目没有页面渲染测试）。
 * 免旧密码：能完成小程序微信登录本身就是身份凭证（范围已裁决）。
 */
export default function AccountPasswordPage() {
  const [phone, setPhone] = useState<string | null>(null)
  const [state, dispatch] = useReducer(reducePasswordCenter, initialPasswordCenterState)

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
      dispatch({ type: 'load_failed', message: '暂时无法加载账号信息，请重试。' })
    }
  }

  useDidShow(() => {
    void load()
  })

  const submit = async () => {
    const invalid = validateNewPassword(state.password, state.confirmation)
    if (invalid) {
      dispatch({ type: 'submit_failed', message: passwordFormErrorCopy(invalid) })
      return
    }
    dispatch({ type: 'submit_started' })
    try {
      await api.setPassword(state.password)
      dispatch({ type: 'submit_succeeded' })
      await Taro.showToast({ title: '密码已更新', icon: 'success' })
    } catch (reason) {
      dispatch({
        type: 'submit_failed',
        message: passwordSubmitErrorCopy(reason instanceof Error ? reason.message : null)
      })
    }
  }

  const requestReset = () => {
    dispatch({ type: 'reset_requested' })
    void Taro.showToast({ title: '直接输入新密码即可', icon: 'none' })
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
            key={`password-${state.formKey}`}
            className={styles.input}
            password
            placeholder='输入新密码'
            onInput={(event) => dispatch({ type: 'password_changed', value: event.detail.value })}
          />
        </View>

        <View className={styles.field}>
          <Text className={styles.label}>再次输入</Text>
          <Input
            key={`confirm-${state.formKey}`}
            className={styles.input}
            password
            placeholder='再输一次'
            onInput={(event) => dispatch({ type: 'confirmation_changed', value: event.detail.value })}
          />
        </View>

        {state.error && <Text className={styles.error}>{state.error}</Text>}
        {state.done && <Text className={styles.success}>密码已更新；其他设备需要重新登录。</Text>}

        <Button
          className={styles.primary}
          loading={state.busy}
          disabled={state.busy}
          onClick={() => void submit()}
        >
          {state.mode === 'reset' ? '重设密码' : '设置 / 修改密码'}
        </Button>
        <Button className={styles.secondary} disabled={state.busy} onClick={requestReset}>
          忘记原密码，直接重设
        </Button>

        <Text className={styles.notice}>
          两种方式都无需输入原密码：能登录这个小程序，就足以证明这是你的账号。
        </Text>
      </View>
    </View>
  )
}
