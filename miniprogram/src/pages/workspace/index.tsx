import { useCallback, useEffect, useMemo, useState } from 'react'
import { Button, ScrollView, Text, View } from '@tarojs/components'
import Taro, { useDidShow } from '@tarojs/taro'
import { api } from '@/api'
import { AppTabBar } from '@/components/AppTabBar'
import { PageState } from '@/components/PageState'
import { canManageMembers, isUrgent, remainingLabel } from '@/domain/format'
import type { SessionSnapshot } from '@/domain/models'
import { requestPlatformSubscription } from '@/platform'
import styles from './index.module.css'

const roleText: Record<string, string> = {
  owner: 'Owner', admin: 'Admin', member: '成员', tutor: 'Tutor', volunteer: '志愿者', learner: 'Learner'
}

export default function WorkspacePage() {
  const [session, setSession] = useState<SessionSnapshot | null>(null)
  const [loading, setLoading] = useState(true)
  const [error, setError] = useState('')
  const [actingId, setActingId] = useState('')
  const [now, setNow] = useState(Date.now)

  const load = useCallback(async () => {
    setLoading(true)
    setError('')
    try {
      setSession(await api.getSession())
    } catch (reason) {
      setError(reason instanceof Error ? reason.message : '工作台加载失败')
    } finally {
      setLoading(false)
    }
  }, [])

  useDidShow(() => { void load() })

  const subscribeReminder = async () => {
    try {
      if (await requestPlatformSubscription('approval_reminder')) {
        await api.grantConsent('approval_reminder')
        Taro.showToast({ title: '已订阅审批提醒', icon: 'success' })
      }
    } catch (reason) {
      Taro.showToast({ title: reason instanceof Error ? reason.message : '订阅失败', icon: 'none' })
    }
  }

  const decide = async (approval: SessionSnapshot['approvals'][number], decision: 'approve' | 'reject') => {
    setActingId(approval.id)
    try {
      if (decision === 'approve') await api.approvePending(approval)
      else await api.rejectPending(approval)
      await load()
      Taro.showToast({ title: decision === 'approve' ? '已通过' : '已拒绝', icon: 'success' })
    } catch (reason) {
      Taro.showToast({ title: reason instanceof Error ? reason.message : '操作失败', icon: 'none' })
    } finally {
      setActingId('')
    }
  }

  const approvals = useMemo(() => [...(session?.approvals ?? [])].sort((left, right) => {
    if (!left.approvalDeadline) return 1
    if (!right.approvalDeadline) return -1
    return new Date(left.approvalDeadline).getTime() - new Date(right.approvalDeadline).getTime()
  }), [session?.approvals])
  const urgentCount = useMemo(
    () => approvals.filter(({ approvalDeadline }) => isUrgent(approvalDeadline, now)).length,
    [approvals, now]
  )
  const manageable = session?.workspaces.some(({ abilities }) => canManageMembers(abilities)) ?? false

  useEffect(() => {
    if (approvals.length === 0) return undefined
    const timer = setInterval(() => setNow(Date.now()), 60_000)
    return () => clearInterval(timer)
  }, [approvals.length])

  return (
    <View className={styles.page}>
      <ScrollView scrollY className={styles.scroll}>
        <View className={styles.header}>
          <Text className={styles.eyebrow}>WORKSPACE</Text>
          <Text className={styles.title}>工作台</Text>
          <Text className={styles.subtitle}>跨社区处理待办，快速回到自己的角色。</Text>
        </View>

        {loading ? (
          <PageState kind='loading' />
        ) : error ? (
          <PageState kind='error' message={error} onRetry={load} />
        ) : !session?.user ? (
          <PageState kind='empty' message='登录后查看你的工作台' />
        ) : (
          <View className={styles.content}>
            {manageable ? (
              <>
                <View className={styles.approvalHeader}>
                  <View>
                    <Text className={styles.sectionTitle}>待审批</Text>
                    <Text className={`${styles.approvalSummary} ${urgentCount ? styles.urgentText : ''}`} data-testid='urgent-summary'>
                      {approvals.length} 条待审批 · {urgentCount} 条 24 小时内过期
                    </Text>
                  </View>
                  {approvals.length > 0 && (
                    <Button className={styles.subscribe} size='mini' onClick={subscribeReminder}>订阅提醒</Button>
                  )}
                </View>

                {approvals.length === 0 ? (
                  <PageState kind='empty' message='暂无待审批' testId='approval-empty' />
                ) : approvals.map((approval) => {
                  const urgent = isUrgent(approval.approvalDeadline, now)
                  return (
                    <View key={approval.id} className={`${styles.approvalCard} ${urgent ? styles.urgentCard : ''}`}>
                      <View className={styles.tags}>
                        <Text className={styles.workspaceTag}>{approval.workspaceName}</Text>
                        <Text className={styles.kindTag}>{approval.kind === 'enrollment' ? '报名' : approval.kind}</Text>
                      </View>
                      <Text className={styles.approvalTitle}>新的报名申请</Text>
                      <Text className={`${styles.deadline} ${urgent ? styles.urgentText : ''}`}>
                        剩余 {remainingLabel(approval.approvalDeadline, now)}
                      </Text>
                      <View className={styles.actions}>
                        <Button className={styles.reject} size='mini' disabled={actingId === approval.id} onClick={() => decide(approval, 'reject')}>拒绝</Button>
                        <Button className={styles.approve} size='mini' data-testid={`approve-${approval.id}`} loading={actingId === approval.id} onClick={() => decide(approval, 'approve')}>通过</Button>
                      </View>
                    </View>
                  )
                })}
              </>
            ) : (
              <View>
                <Text className={styles.sectionTitle}>待审批</Text>
                <PageState kind='empty' message='当前角色无审批权限' />
              </View>
            )}

            <Text className={styles.sectionTitle}>我的 Workspace</Text>
            {session.workspaces.map((workspace) => (
              <View key={workspace.id} className={styles.workspaceCard}>
                <View>
                  <Text className={styles.workspaceName}>{workspace.name}</Text>
                  <Text className={styles.workspaceMeta}>{workspace.memberCount ?? '—'} 名成员 · {workspace.slug}</Text>
                </View>
                <View className={styles.roleList}>
                  {workspace.roleNames.map((role) => <Text key={role} className={styles.role}>{roleText[role] ?? role}</Text>)}
                </View>
              </View>
            ))}
          </View>
        )}
      </ScrollView>
      <AppTabBar selected='workspace' />
    </View>
  )
}
