/**
 * 小红书端「我的」精简页（P0-5，D2a：Tab = 发现/我的，我的报名收进本页）。
 *
 * 能力清单（只保留学习者/校友面；组织者面留在微信端与 web，原则①）：
 * 退出登录、我的报名入口、手输邀请码加入（X-5：scene 扫码进入的传参方式
 * 平台未文档化，P0 只做手输）、闪念间入口（薄壳页）、隐私政策（D7 变体正文）。
 *
 * 备案号：小红书小程序 ICP 备案号（D8，2026-09-22 通过）——与微信端
 * `pages/profile` 的 -6X 分属不同小程序主体记录，不要互抄。
 */
import { useCallback, useState } from 'react'
import { Button, Input, ScrollView, Text, View } from '@tarojs/components'
import Taro, { useDidShow } from '@tarojs/taro'
import { api } from '@/api'
import { AppTabBar } from '@/components/AppTabBar'
import { PageState } from '@/components/PageState'
import type { SessionSnapshot } from '@/domain/models'
import styles from './index.module.css'

export default function ProfileLitePage() {
  const [session, setSession] = useState<SessionSnapshot | null>(null)
  const [scene, setScene] = useState('')
  const [sceneInputKey, setSceneInputKey] = useState(0)
  const [loading, setLoading] = useState(true)
  const [error, setError] = useState('')
  const [action, setAction] = useState('')

  const load = useCallback(async () => {
    setLoading(true)
    setError('')
    try {
      setSession(await api.getSession())
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
      // 兜底文案与 join/profile 页 admit 同款（#355-12：双入口文案统一）
      Taro.showToast({ title: reason instanceof Error ? reason.message : '邀请码无效或已过期', icon: 'none' })
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
    }
  }

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
            <Text className={styles.loggedOutTitle}>登录后查看报名与闪念间</Text>
            <Text className={styles.loggedOutText}>手机号快捷登录，无需密码。</Text>
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
              <Button className={styles.logout} size='mini' onClick={logout} data-testid='logout'>退出</Button>
            </View>

            <Text className={styles.sectionTitle}>我的报名</Text>
            <View
              className={styles.entry}
              data-testid='entry-my-enrollments'
              onClick={() => void Taro.navigateTo({ url: '/pages/my-enrollments/index' })}
            >
              <View>
                <Text className={styles.entryTitle}>查看报名与核销</Text>
                <Text className={styles.entryText}>报名的活动与课程、现场核销码、缴费状态。</Text>
              </View>
              <Text className={styles.entryArrow}>→</Text>
            </View>

            <Text className={styles.sectionTitle}>闪念间</Text>
            {/* 长廊是本端 Tab 页：switchTab 是唯一合法入口（navigateTo 会静默失败） */}
            <View
              className={styles.entry}
              data-testid='entry-flashback'
              onClick={() => void Taro.switchTab({ url: '/pages/flashback-corridor/index' })}
            >
              <View>
                <Text className={styles.entryTitle}>打开闪念间</Text>
                <Text className={styles.entryText}>找回当年的自己，看看那些年的回答。</Text>
              </View>
              <Text className={styles.entryArrow}>→</Text>
            </View>

            <Text className={styles.sectionTitle}>加入工作台</Text>
            <View className={styles.panel}>
              <Text className={styles.panelText}>输入组织者分享给你的邀请码，仅可使用一次，请确认来自你信任的组织者。</Text>
              <View className={styles.inlineForm}>
                <Input key={sceneInputKey} className={styles.codeInput} placeholder='邀请码' onInput={(event) => setScene(event.detail.value)} />
                <Button className={styles.inlineButton} size='mini' loading={action === 'admit'} onClick={admit}>确认加入</Button>
              </View>
            </View>

            <Text className={styles.sectionTitle}>隐私政策</Text>
            <View
              className={styles.entry}
              data-testid='entry-privacy'
              onClick={() => void Taro.navigateTo({ url: '/pages/privacy/index' })}
            >
              <View>
                <Text className={styles.entryTitle}>查看隐私政策</Text>
                <Text className={styles.entryText}>我们收集哪些信息、如何使用与保护、你的权利。</Text>
              </View>
              <Text className={styles.entryArrow}>→</Text>
            </View>

            <View className={styles.footer}>
              <Text className={styles.footerText}>京ICP备16008426号-7X</Text>
            </View>
          </View>
        )}
      </ScrollView>
      <AppTabBar selected='profile' />
    </View>
  )
}
