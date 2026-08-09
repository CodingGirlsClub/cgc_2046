import { useEffect, useState } from 'react'
import { Button, Input, Text, View } from '@tarojs/components'
import Taro, { useRouter } from '@tarojs/taro'
import { api } from '@/api'
import { STORAGE_KEYS } from '@/state/storage'
import styles from './index.module.css'

export default function JoinPage() {
  const router = useRouter()
  const [scene, setScene] = useState(
    () => router.params.scene ?? Taro.getStorageSync<string>(STORAGE_KEYS.pendingScene) ?? ''
  )
  const [loading, setLoading] = useState(true)
  const [submitting, setSubmitting] = useState(false)
  const [error, setError] = useState('')

  useEffect(() => {
    api.getSession().then((session) => {
      if (!session.user) {
        const returnUrl = `/pages/join/index?scene=${encodeURIComponent(scene)}`
        return Taro.redirectTo({ url: `/pages/login/index?returnUrl=${encodeURIComponent(returnUrl)}` })
      }
    }).catch((reason) => setError(reason instanceof Error ? reason.message : '登录状态校验失败'))
      .finally(() => setLoading(false))
  }, [])

  const admit = async () => {
    if (!scene.trim() || submitting) return
    setSubmitting(true)
    setError('')
    try {
      const result = await api.admitMember(scene.trim())
      Taro.removeStorageSync(STORAGE_KEYS.pendingScene)
      Taro.showToast({ title: `已加入${result.workspaceName}`, icon: 'success' })
      setTimeout(() => Taro.switchTab({ url: '/pages/workspace/index' }), 500)
    } catch (reason) {
      setError(reason instanceof Error ? reason.message : '邀请码无效或已过期')
    } finally {
      setSubmitting(false)
    }
  }

  return (
    <View className={styles.page}>
      <View className={styles.icon}>＋</View>
      <Text className={styles.title}>加入 Workspace</Text>
      <Text className={styles.subtitle}>确认邀请码来自你信任的组织者；scene 一次使用后即失效。</Text>
      <View className={styles.card}>
        <Text className={styles.label}>邀请 scene</Text>
        <Input className={styles.input} value={scene} placeholder='请输入或扫码带入' onInput={(event) => setScene(event.detail.value)} />
      </View>
      {error && <Text className={styles.error}>{error}</Text>}
      <Button className={styles.primaryButton} loading={loading || submitting} disabled={loading || submitting || !scene.trim()} onClick={admit}>确认加入</Button>
    </View>
  )
}
