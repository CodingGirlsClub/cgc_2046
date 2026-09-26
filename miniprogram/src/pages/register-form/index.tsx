import { useCallback, useEffect, useState } from 'react'
import { Button, Input, Text, View } from '@tarojs/components'
import Taro, { useRouter } from '@tarojs/taro'
import { api } from '@/api'
import { PageState } from '@/components/PageState'
import type { CatalogItem, ContentKind } from '@/domain/models'
import { STORAGE_KEYS } from '@/state/storage'
import { enrollmentBlockedNotice } from '@/domain/format'
import { paymentLandingUrl, tierAmountText } from '@/domain/payment'
import { preSubmitTouchpoint, submitAfterConsent } from '@/domain/subscription'
import { currentPlatform, requestPlatformSubscriptions } from '@/platform'
import styles from './index.module.css'

// 构建期常量：本端平台（domain 门判据，P0 缴费门在小红书生效）
const platform = currentPlatform()

// 对齐 web 端一键报名：身份=登录账号（user_id），不再收集姓名/邮箱/理由
// （web 无此表单；submission_payload 三键经三端确认无任何读者）。
// 仅剩条件字段：收费选档（R5）与 invite_only 批次码——同 web 端条件渲染口径。
export default function RegisterFormPage() {
  const router = useRouter()
  const id = router.params.id ?? ''
  const kind = (router.params.kind === 'course' ? 'course' : 'event') as ContentKind
  const [target, setTarget] = useState<CatalogItem | null>(null)
  const [inviteCode, setInviteCode] = useState('')
  const [tierId, setTierId] = useState('')
  // #510 年龄门槛确认：minAge 非空的目标报名前须勾选（拦截 + 后端权威门控）
  const [ageConfirmed, setAgeConfirmed] = useState(false)
  const [loading, setLoading] = useState(true)
  const [submitting, setSubmitting] = useState(false)
  const [error, setError] = useState('')

  const load = useCallback(async () => {
    setLoading(true)
    setError('')
    try {
      const [content, session] = await Promise.all([api.getContent(kind, id), api.getSession()])
      setTarget(content)
      // 收费目标默认选中第一档（用户拍板:有档不该强制手点;可再点换档）；
      // #687：默认档跳过金额脏档（禁选档不可作为默认选择）
      if (content.pricingEnabled && content.priceTiers.length > 0) {
        setTierId(content.priceTiers.find((t) => t.amountCents !== null)?.id ?? '')
      }
      // 三门（status + badge + 缴费门）与详情页 CTA 同源：深链 / 登录期间
      // 被取消的场也会在此被挡（此前只看 badge，#574；缴费门 D1a 见 domain/format）
      if (enrollmentBlockedNotice(content, platform)) return
      if (!session.user) {
        const returnUrl = `/pages/register-form/index?id=${id}&kind=${kind}`
        await Taro.redirectTo({ url: `/pages/login/index?returnUrl=${encodeURIComponent(returnUrl)}` })
        return
      }
    } catch (reasonValue) {
      setError(reasonValue instanceof Error ? reasonValue.message : '报名信息加载失败')
    } finally {
      setLoading(false)
    }
  }, [id, kind])

  useEffect(() => { void load() }, [load])

  const submit = async () => {
    if (!target || submitting) return
    // 所选档（脏档禁选后的有效选择；undefined == null 涵盖未选）
    const selectedTier = target.priceTiers.find((t) => t.id === tierId)
    if (target.enrollmentPolicy === 'invite_only' && !inviteCode.trim()) {
      Taro.showToast({ title: '请输入批次码', icon: 'none' })
      return
    }
    // #687 加一层：所选档金额脏（金额待定、禁选）同样不可提交——金额待定的档不收钱
    if (target.pricingEnabled && selectedTier?.amountCents == null) {
      Taro.showToast({ title: '请选择价格档位', icon: 'none' })
      return
    }
    if (target.minAge != null && !ageConfirmed) {
      Taro.showToast({ title: '请先勾选年龄确认', icon: 'none' })
      return
    }

    setSubmitting(true)
    setError('')
    try {
      // #546/#664：报名先取得订阅授权**再**提交——一次性订阅只能覆盖提交之后的
      // 发送（open 免费场/课程 confirmed 与提交同事务落定，后置触点必然送不到）。
      // 上方前置拦截（批次码 / 档位 / 年龄勾选）全部先行：不满足条件时不弹授权；
      // 满足后仍是「授权先于提交」。拒绝授权 / 模板缺配 / 平台报错一律不阻断报名
      // （submitAfterConsent 内化）。场景按 kind 分派（活动=报名成功+核销码，
      // 课程=报名成功；判据见 domain/subscription.ts）。
      const enrollment = await submitAfterConsent(
        preSubmitTouchpoint(kind),
        {
          request: requestPlatformSubscriptions,
          grant: (scenario) => api.grantConsent(scenario)
        },
        () =>
          api.createEnrollment({
            target,
            inviteCode: inviteCode.trim() || undefined,
            tierId: target.pricingEnabled ? tierId : undefined,
            ageConfirmed: target.minAge != null ? true : undefined
          })
      )
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

  const blockedNotice = enrollmentBlockedNotice(target, platform)
  if (blockedNotice) return <PageState kind='empty' message={blockedNotice} />

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
        <Text className={styles.formTitle} data-testid='register-title'>确认报名</Text>
        <Text className={styles.formHint}>已登录账号即报名身份，无需重复填写姓名与邮箱。</Text>

        {target.pricingEnabled && (
          <View className={styles.field} data-testid='tier-field'>
            <Text className={styles.label}>价格档位</Text>
            {target.priceTiers.length === 0 ? (
              <Text className={styles.formHint}>当前无可售档位，请联系组织者。</Text>
            ) : target.priceTiers.map((tier) => (
              <View
                key={tier.id}
                className={`${styles.tierOption} ${tierId === tier.id ? styles.tierActive : ''} ${tier.amountCents === null ? styles.tierDisabled : ''}`}
                data-testid={`tier-option-${tier.id}`}
                onClick={() => { if (tier.amountCents !== null) setTierId(tier.id) }}
              >
                <Text className={styles.tierName}>{tier.name}</Text>
                {/* #687：脏金额不表态——「金额待定」，绝不 ¥0/¥0.00 */}
                <Text className={styles.tierPrice}>{tierAmountText(tier, '金额待定')}</Text>
              </View>
            ))}
          </View>
        )}

        {target.enrollmentPolicy === 'invite_only' && (
          <View className={styles.field}>
            <Text className={styles.label}>批次码</Text>
            {/* iOS 微信竞态纪律（#388 重修）：defaultValue 绑「随输入变化的 state」等于仍是受控，
                击键 setState→diff 回写原生框与用户输入竞争致显示重置。初始为空则不声明该属性，
                值只经 onInput 单向流出，输入框值属性永不参与 diff。 */}
            <Input className={styles.input} placeholder='请输入组织者提供的批次码' onInput={(event) => setInviteCode(event.detail.value)} />
          </View>
        )}

        {/* #510 年龄门槛：minAge 非空的目标须勾选（整行可点，与 order-pay 押金同意门同款行选择） */}
        {target.minAge != null && (
          <View
            className={styles.ackRow}
            data-testid='age-confirm-option'
            onClick={() => setAgeConfirmed((value) => !value)}
          >
            <View className={`${styles.ackBox} ${ageConfirmed ? styles.ackBoxChecked : ''}`} />
            <Text className={styles.ackLabel}>
              我确认已年满 {target.minAge} 周岁，符合本活动的年龄要求。
            </Text>
          </View>
        )}
      </View>

      {error && <Text className={styles.error}>{error}</Text>}
      <Button className={styles.primaryButton} data-testid='submit-enrollment' loading={submitting} disabled={submitting} onClick={submit}>
        {submitting ? '正在提交…' : '确认报名'}
      </Button>
    </View>
  )
}
