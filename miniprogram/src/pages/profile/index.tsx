import { useCallback, useState } from 'react'
import { Button, Image, Input, ScrollView, Text, View } from '@tarojs/components'
import Taro, { useDidShow, useShareAppMessage } from '@tarojs/taro'
import { api } from '@/api'
import { AppTabBar } from '@/components/AppTabBar'
import { PageState } from '@/components/PageState'
import { canManageMembers } from '@/domain/format'
import { buildJoinSharePath } from '@/domain/share-route'
import type { MiniProgramCode, NotificationItem, SessionSnapshot, WorkspaceSummary } from '@/domain/models'
import styles from './index.module.css'

export default function ProfilePage() {
  const [session, setSession] = useState<SessionSnapshot | null>(null)
  const [notifications, setNotifications] = useState<NotificationItem[]>([])
  const [scene, setScene] = useState('')
  const [sceneInputKey, setSceneInputKey] = useState(0)
  const [code, setCode] = useState<MiniProgramCode | null>(null)
  const [codeWorkspaceName, setCodeWorkspaceName] = useState('')
  const [loading, setLoading] = useState(true)
  const [error, setError] = useState('')
  const [action, setAction] = useState('')

  const load = useCallback(async () => {
    setLoading(true)
    setError('')
    try {
      const [sessionValue, notificationValue] = await Promise.all([api.getSession(), api.getNotifications()])
      setSession(sessionValue)
      setNotifications(notificationValue)
    } catch (reason) {
      setError(reason instanceof Error ? reason.message : '个人中心加载失败')
    } finally {
      setLoading(false)
    }
  }, [])

  useDidShow(() => { void load() })

  const admit = async () => {
    if (!scene.trim()) return Taro.showToast({ title: '请输入邀请码', icon: 'none' })
    setAction('admit')
    try {
      const result = await api.admitMember(scene.trim())
      Taro.showToast({ title: `已加入${result.workspaceName}`, icon: 'success' })
      setScene('')
      // iOS 竞态纪律（见 register-form）：Input 不声明 defaultValue（初始为空），
      // 「成功后清空输入框」由换 key 强制重挂载兑现——状态清空不回写原生组件
      setSceneInputKey((k) => k + 1)
      await load()
    } catch (reason) {
      // 兜底文案与 join 页 admit 同款（#355-12：双入口文案统一）
      Taro.showToast({ title: reason instanceof Error ? reason.message : '邀请码无效或已过期', icon: 'none' })
    } finally {
      setAction('')
    }
  }

  const generateCode = async (workspace: WorkspaceSummary) => {
    setAction(`code-${workspace.id}`)
    try {
      setCode(await api.generateMiniProgramCode(workspace.id))
      setCodeWorkspaceName(workspace.name)
    } catch (reason) {
      Taro.showToast({ title: reason instanceof Error ? reason.message : '生成失败', icon: 'none' })
    } finally {
      setAction('')
    }
  }

  const logout = async () => {
    try {
      await api.signOut()
      Taro.showToast({ title: '已退出登录', icon: 'success' })
    } catch {
      Taro.showToast({ title: '已退出本机，服务端注销失败', icon: 'none' })
    } finally {
      setSession({ user: null, workspaces: [], approvals: [], authExpired: false })
      setNotifications([])
    }
  }

  const scanInvitation = async () => {
    try {
      const result = await Taro.scanCode({ scanType: ['qrCode'] })
      setScene(result.result)
    } catch {
      Taro.showToast({ title: '已取消扫码', icon: 'none' })
    }
  }

  // #415 分享出口：复制 scene 码，对方在 join 页粘贴入座
  const copyScene = async () => {
    if (!code) return
    try {
      await Taro.setClipboardData({ data: code.scene })
      Taro.showToast({ title: '已复制，对方在加入页粘贴即可', icon: 'none' })
    } catch {
      Taro.showToast({ title: '复制失败，请重试', icon: 'none' })
    }
  }

  // 页面级 hook 必须无条件注册（open-type='share' 转发卡片取这里）；
  // 分享按钮仅在 code 存在时渲染，无 code 的兜底仅防御
  useShareAppMessage(() =>
    code
      ? { title: `邀请你加入「${codeWorkspaceName}」`, path: buildJoinSharePath(code.scene) }
      : { title: 'CGC 2046 社区', path: '/pages/discover/index' }
  )

  // 管理级工作台：复用 canManageMembers 原语（能力下发），不硬编码角色名
  const manageableWorkspaces = session?.workspaces.filter(({ abilities }) =>
    canManageMembers(abilities)
  ) ?? []

  return (
    <View className={styles.page}>
      <ScrollView scrollY className={styles.scroll}>
        <View className={styles.header}>
          <Text className={styles.eyebrow}>PROFILE</Text>
          <Text className={styles.title}>我的</Text>
        </View>

        {loading ? (
          <PageState kind='loading' />
        ) : error ? (
          <PageState kind='error' message={error} onRetry={load} />
        ) : !session?.user ? (
          <View className={styles.loggedOut}>
            <Text className={styles.loggedOutTitle}>登录后管理报名与通知</Text>
            <Text className={styles.loggedOutText}>手机号一键登录，无需密码。</Text>
            <Button className={styles.primaryButton} onClick={() => Taro.navigateTo({ url: '/pages/login/index' })}>去登录</Button>
          </View>
        ) : (
          <View className={styles.content}>
            <View className={styles.userCard}>
              <View className={styles.avatar}>{session.user.displayName.slice(0, 1)}</View>
              <View className={styles.userMain}>
                <Text className={styles.userName}>{session.user.displayName}</Text>
                <Text className={styles.userMeta}>{session.user.memberNumber ?? session.user.email ?? '程序媛汇成员'}</Text>
              </View>
              <Button className={styles.logout} size='mini' onClick={logout}>退出</Button>
            </View>

            <Text className={styles.sectionTitle}>本机通知记录</Text>
            <View className={styles.panel} data-testid='notification-list'>
              {notifications.length === 0 ? (
                <PageState kind='empty' message='还没有本机记录' />
              ) : notifications.map((notification) => (
                <View key={notification.id} className={styles.notification}>
                  <View className={styles.dot} />
                  <View className={styles.notificationMain}>
                    <Text className={styles.notificationTitle}>{notification.title}</Text>
                    <Text className={styles.notificationBody}>{notification.body}</Text>
                  </View>
                </View>
              ))}
            </View>

            <Text className={styles.sectionTitle}>加入工作台</Text>
            <View className={styles.panel}>
              <Text className={styles.panelText}>输入组织者分享给你的邀请码，仅可使用一次，请确认来自你信任的组织者。</Text>
              <View className={styles.inlineForm}>
                <Input key={sceneInputKey} className={styles.codeInput} placeholder='邀请码' onInput={(event) => setScene(event.detail.value)} />
                <Button className={styles.inlineButton} size='mini' loading={action === 'admit'} onClick={admit}>确认加入</Button>
              </View>
              <Button className={styles.scanButton} size='mini' onClick={scanInvitation}>扫码加入</Button>
            </View>

            {manageableWorkspaces.length > 0 && (
              <>
                <Text className={styles.sectionTitle}>邀请新成员</Text>
                <View className={styles.panel}>
                  {manageableWorkspaces.map((workspace) => (
                    <View key={workspace.id} className={styles.codeRow}>
                      <Text>{workspace.name}</Text>
                      <Button className={styles.inlineButton} size='mini' loading={action === `code-${workspace.id}`} onClick={() => generateCode(workspace)}>生成</Button>
                    </View>
                  ))}
                  {code && (
                    <View className={styles.codeResult}>
                      {code.codeBase64 ? <Image className={styles.codeImage} src={`data:image/png;base64,${code.codeBase64}`} /> : null}
                      <Text className={styles.scene}>邀请码：{code.scene}</Text>
                      <Text className={styles.expires}>有效期至 {new Date(code.expiresAt).toLocaleString()}</Text>
                      <View className={styles.codeActions}>
                        <Button className={styles.shareButton} size='mini' openType='share'>转发给好友</Button>
                        <Button className={styles.copyButton} size='mini' onClick={copyScene}>复制邀请码</Button>
                      </View>
                    </View>
                  )}
                </View>
              </>
            )}

            <Text className={styles.sectionTitle}>继续学习</Text>
            <View className={styles.openclacky} onClick={() => Taro.navigateTo({ url: '/pages/openclacky/index' })}>
              <View>
                <Text className={styles.openclackyTitle}>去 OpenClacky</Text>
                <Text className={styles.openclackyText}>完整学习协作在你自己的 Agent 环境中继续。</Text>
              </View>
              <Text className={styles.openclackyArrow}>→</Text>
            </View>
          </View>
        )}

        <View className={styles.footer}>
          <Text className={styles.footerText}>京ICP备16008426号-6X</Text>
        </View>
      </ScrollView>
      <AppTabBar selected='profile' />
    </View>
  )
}
