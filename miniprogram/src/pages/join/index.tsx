import { useEffect, useState } from 'react'
import { Button, Input, Text, View } from '@tarojs/components'
import Taro, { useRouter } from '@tarojs/taro'
import { api } from '@/api'
import { takePendingScene } from '@/state/accountState'
import styles from './index.module.css'

export default function JoinPage() {
  const router = useRouter()
  // 路由带入的初始邀请码：mount 后定死，供 defaultValue 绑定（iOS 竞态纪律见 register-form）
  const [initialScene] = useState(() => takePendingScene(router.params.scene))
  const [scene, setScene] = useState(initialScene)
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
      // takePendingScene 已在页面初始化时消费并删除持久 scene，这里无需再 remove
      Taro.showToast({ title: `已加入${result.workspaceName}`, icon: 'success' })
      // 裁剪端（抖音/小红书）无工作台 Tab，入座后回落我的报名
      const nextTab = process.env.TARO_ENV === 'tt' || process.env.TARO_ENV === 'xhs'
        ? '/pages/my-enrollments/index'
        : '/pages/workspace/index'
      setTimeout(() => Taro.switchTab({ url: nextTab }), 500)
    } catch (reason) {
      setError(reason instanceof Error ? reason.message : '邀请码无效或已过期')
    } finally {
      setSubmitting(false)
    }
  }

  return (
    <View className={styles.page}>
      <View className={styles.icon}>＋</View>
      <Text className={styles.title}>加入工作台</Text>
      <Text className={styles.subtitle}>邀请码仅可使用一次，请确认来自你信任的组织者。</Text>
      <View className={styles.card}>
        <Text className={styles.label}>邀请码</Text>
        <Input className={styles.input} defaultValue={initialScene} placeholder='请输入邀请码' onInput={(event) => setScene(event.detail.value)} />
      </View>
      {error && <Text className={styles.error}>{error}</Text>}
      <Button className={styles.primaryButton} loading={loading || submitting} disabled={loading || submitting || !scene.trim()} onClick={admit}>确认加入</Button>
    </View>
  )
}
