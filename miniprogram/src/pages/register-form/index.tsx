import { useCallback, useEffect, useState } from 'react'
import { Button, Input, Text, Textarea, View } from '@tarojs/components'
import Taro, { useRouter } from '@tarojs/taro'
import { api } from '@/api'
import { PageState } from '@/components/PageState'
import type { CatalogItem, ContentKind } from '@/domain/models'
import { STORAGE_KEYS } from '@/state/storage'
import { formatAmount, paymentLandingUrl } from '@/domain/payment'
import styles from './index.module.css'

export default function RegisterFormPage() {
  const router = useRouter()
  const id = router.params.id ?? ''
  const kind = (router.params.kind === 'course' ? 'course' : 'event') as ContentKind
  const [target, setTarget] = useState<CatalogItem | null>(null)
  const [name, setName] = useState('')
  const [email, setEmail] = useState('')
  const [reason, setReason] = useState('')
  const [inviteCode, setInviteCode] = useState('')
  const [tierId, setTierId] = useState('')
  const [loading, setLoading] = useState(true)
  const [submitting, setSubmitting] = useState(false)
  const [error, setError] = useState('')

  const load = useCallback(async () => {
    setLoading(true)
    setError('')
    try {
      const [content, session] = await Promise.all([api.getContent(kind, id), api.getSession()])
      if (!session.user) {
        const returnUrl = `/pages/register-form/index?id=${id}&kind=${kind}`
        await Taro.redirectTo({ url: `/pages/login/index?returnUrl=${encodeURIComponent(returnUrl)}` })
        return
      }
      setTarget(content)
      setName(session.user.displayName)
      setEmail(session.user.email ?? '')
    } catch (reasonValue) {
      setError(reasonValue instanceof Error ? reasonValue.message : '报名信息加载失败')
    } finally {
      setLoading(false)
    }
  }, [id, kind])

  useEffect(() => { void load() }, [load])

  const submit = async () => {
    if (!target || submitting) return
    if (!name.trim() || !email.trim() || !reason.trim()) {
      Taro.showToast({ title: '请完整填写报名信息', icon: 'none' })
      return
    }
    if (target.enrollmentPolicy === 'invite_only' && !inviteCode.trim()) {
      Taro.showToast({ title: '请输入批次码', icon: 'none' })
      return
    }
    if (target.pricingEnabled && !tierId) {
      Taro.showToast({ title: '请选择价格档位', icon: 'none' })
      return
    }

    setSubmitting(true)
    setError('')
    try {
      const enrollment = await api.createEnrollment({
        target,
        name: name.trim(),
        email: email.trim(),
        reason: reason.trim(),
        inviteCode: inviteCode.trim() || undefined,
        tierId: target.pricingEnabled ? tierId : undefined
      })
      Taro.setStorageSync(STORAGE_KEYS.lastEnrollment, enrollment)
      if (enrollment.status === 'payment_pending') {
        // 收费报名：weapp 占位完成即进支付页(R5：2h 限时窗)；
        // 裁剪端无小程序内支付，回结果页引导网页端支付（同 my-enrollments 守卫语义）。
        await Taro.redirectTo({
          url: paymentLandingUrl(enrollment.id, process.env.TARO_ENV === 'weapp')
        })
        return
      }
      await Taro.redirectTo({ url: `/pages/enrollment-result/index?id=${enrollment.id}` })
    } catch (reasonValue) {
      setError(reasonValue instanceof Error ? reasonValue.message : '提交失败，请重试')
    } finally {
      setSubmitting(false)
    }
  }

  if (loading) return <PageState kind='loading' />
  if (!target && error) return <PageState kind='error' message={error} onRetry={load} />
  if (!target) return <PageState kind='empty' message='报名项目不存在' />

  return (
    <View className={styles.page}>
      <View className={styles.summary}>
        <Text className={styles.summaryKind}>{target.kind === 'event' ? '活动报名' : '课程报名'}</Text>
        <Text className={styles.summaryTitle}>{target.title}</Text>
        <Text className={styles.summaryPolicy}>
          {target.enrollmentPolicy === 'open' && '开放报名 · 提交后立即确认'}
          {target.enrollmentPolicy === 'request' && '申请报名 · 提交后等待审批'}
          {target.enrollmentPolicy === 'invite_only' && '邀请报名 · 需要批次码'}
        </Text>
      </View>

      <View className={styles.form}>
        <Text className={styles.formTitle} data-testid='register-title'>报名信息</Text>
        <Text className={styles.formHint}>信息仅用于本次报名与审批。</Text>

        {target.pricingEnabled && (
          <View className={styles.field} data-testid='tier-field'>
            <Text className={styles.label}>价格档位</Text>
            {target.priceTiers.length === 0 ? (
              <Text className={styles.formHint}>当前无可售档位，请联系组织者。</Text>
            ) : target.priceTiers.map((tier) => (
              <View
                key={tier.id}
                className={`${styles.tierOption} ${tierId === tier.id ? styles.tierActive : ''}`}
                data-testid={`tier-option-${tier.id}`}
                onClick={() => setTierId(tier.id)}
              >
                <Text className={styles.tierName}>{tier.name}</Text>
                <Text className={styles.tierPrice}>¥{formatAmount(tier.amountCents)}</Text>
              </View>
            ))}
          </View>
        )}

        {target.enrollmentPolicy === 'invite_only' && (
          <View className={styles.field}>
            <Text className={styles.label}>批次码</Text>
            <Input className={styles.input} placeholder='请输入组织者提供的批次码' value={inviteCode} onInput={(event) => setInviteCode(event.detail.value)} />
          </View>
        )}

        <View className={styles.field}>
          <Text className={styles.label}>姓名</Text>
          <Input className={styles.input} data-testid='name-input' placeholder='怎么称呼你' value={name} onInput={(event) => setName(event.detail.value)} />
        </View>
        <View className={styles.field}>
          <Text className={styles.label}>邮箱</Text>
          <Input className={styles.input} data-testid='email-input' type='text' placeholder='用于发送活动材料' value={email} onInput={(event) => setEmail(event.detail.value)} />
        </View>
        <View className={styles.field}>
          <Text className={styles.label}>为什么想来</Text>
          <Textarea className={styles.textarea} data-testid='reason-input' placeholder='简单介绍你的期待' value={reason} maxlength={300} onInput={(event) => setReason(event.detail.value)} />
        </View>
      </View>

      {error && <Text className={styles.error}>{error}</Text>}
      <Button className={styles.primaryButton} data-testid='submit-enrollment' loading={submitting} disabled={submitting} onClick={submit}>
        {submitting ? '正在提交…' : '确认提交'}
      </Button>
    </View>
  )
}
