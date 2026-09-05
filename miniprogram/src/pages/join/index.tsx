import { useEffect, useState } from 'react'
import { Button, Input, Text, View } from '@tarojs/components'
import Taro, { useRouter } from '@tarojs/taro'
import { api } from '@/api'
import { canManageMembers } from '@/domain/format'
import { takePendingScene } from '@/state/accountState'
import styles from './index.module.css'

// join 落地页（#355-8）：新入座 workspace 有 manage_members 能力者留工作台；
// 普通学员工作台只有「当前角色无审批权限」死胡同，落我的报名。裁剪端
// （tt/xhs）无工作台 Tab，一律我的报名。getSession 失败按学员处理（用户可自行切 Tab）。
const landingTabAfterJoin = async (workspaceId: string): Promise<string> => {
  if (process.env.TARO_ENV === 'tt' || process.env.TARO_ENV === 'xhs') {
    return '/pages/my-enrollments/index'
  }
  try {
    const session = await api.getSession()
    const joined = session.workspaces.find((workspace) => workspace.id === workspaceId)
    return joined && canManageMembers(joined.abilities)
      ? '/pages/workspace/index'
      : '/pages/my-enrollments/index'
  } catch {
    return '/pages/my-enrollments/index'
  }
}

export default function JoinPage() {
  const router = useRouter()
  const [scene, setScene] = useState(() => takePendingScene(router.params.scene))
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
      const nextTab = await landingTabAfterJoin(result.workspaceId)
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
        <Input className={styles.input} defaultValue={scene} placeholder='请输入邀请码' onInput={(event) => setScene(event.detail.value)} />
      </View>
      {error && <Text className={styles.error}>{error}</Text>}
      <Button className={styles.primaryButton} loading={loading || submitting} disabled={loading || submitting || !scene.trim()} onClick={admit}>确认加入</Button>
    </View>
  )
}
