import { Button, Input, Text, Textarea, View } from '@tarojs/components'
import Taro, { useDidShow } from '@tarojs/taro'
import { useCallback, useState } from 'react'
import { api, SessionExpiredError } from '@/api'
import { PageState } from '@/components/PageState'
import { ResumeUpload } from '@/components/resume-upload'
import type {
  RecruitmentCohort,
  ResumeProfileSummary,
  UserSummary,
  VolunteerApplicationSummary,
  VolunteerPosition
} from '@/domain/models'
import {
  ALREADY_APPLIED_COPY,
  NO_OPEN_COHORT_COPY,
  NO_OPEN_COHORT_HINT,
  RESUME_SKILL_OPTIONS,
  VOLUNTEER_APPLY_PATH,
  VOLUNTEER_JOURNEY,
  VOLUNTEER_POSITIONS,
  applicationForCohort,
  cohortDeadlineText,
  cohortStatusText,
  cohortWindowText,
  hasResumeFile,
  positionTitle,
  recruitmentPageState,
  resumeProfileError,
  volunteerStageProgress,
  volunteerStatusText,
  weeklyHoursValue
} from '@/domain/recruitment'
import {
  submitAfterConsent,
  requestTouchpointConsent,
  volunteerApplyTouchpoint,
  volunteerFollowUpTouchpoint
} from '@/domain/subscription'
import { requestPlatformSubscriptions } from '@/platform'
import styles from './index.module.css'

/**
 * 志愿者招募流（R20/R21，**微信端专属**——裁剪端页清单不登记，见 src/app.config.ts）。
 *
 * 视觉按原型 weapp-host：批次卡（动态状态）+ 三职位 + 四段流程 + 两步网申 +
 * 我的申请；登录走小程序既有手机号登录（applicant 与 web 同源）。审核面板不进
 * 小程序（R13 的管理面在 web）。
 *
 * 与 web 申请页的**有意差异**：批次与档案的读面都带 workspace_id 租户，小程序
 * 没有 URL slug，入口工作台只能按 slug 解析且该查询需登录（getWorkspace，
 * actor_present 策略）——所以本页的分流是「先登录再看批次」，AE1（未登录 → 登录
 * 引导而非表单）即此。静态部分（hero / 三职位 / 四段流程）匿名可见；公网批次日历
 * 在 web 申请页与 campaign 页。判据与文案在 domain/recruitment.ts。
 *
 * 三态（批次读取）：加载中 / 读取失败（重试，**不显示无批次空态**）/ 无 open 批次
 * （空态 + 申请入口收起，AE12）。失败与空态是不同桶，不可合并渲染。
 *
 * 授权触点（R21）在 submitApplication：先 requestSubscribeMessage 再一次 grant、
 * 最后提交（镜像报名流 submitAfterConsent 的顺序判据）；补授权位在本页「我的申请」。
 */

/** 两步网申的表单态（一个对象承载，patch 式更新；判据全在 domain） */
export interface ApplyFormState {
  /** 1 = 简历档案；已有档案且有文件时初始即 2（跳过重传，AE5） */
  step: 1 | 2
  /** 第 1 步展开态：已有档案且有文件 → false（收起为一行摘要），点「更新简历」再展开 */
  editingResume: boolean
  fullName: string
  contactEmail: string
  hoursInput: string
  skills: string[]
  position: VolunteerPosition | ''
  city: string
  heardAboutUs: string
  hasInternalReferrer: boolean
  message: string
}

export const INITIAL_APPLY_FORM: ApplyFormState = {
  step: 1,
  editingResume: true,
  fullName: '',
  contactEmail: '',
  hoursInput: '',
  skills: [],
  position: '',
  city: '',
  heardAboutUs: '',
  hasInternalReferrer: false,
  message: ''
}

/** 第 1 步是否收起为摘要（已有档案 + 有简历文件 + 用户没点「更新简历」） */
export function resumeCollapsed(form: ApplyFormState, profile: ResumeProfileSummary | null): boolean {
  return hasResumeFile(profile) && !form.editingResume
}

// ── 展示件（导出供测试直接渲染：小程序无页面渲染测试，展示与判据一起钉） ──────

export function VolunteerHero() {
  return (
    <View className={styles.hero}>
      <Text className={styles.brand}>HACKER START 1024 · <Text className={styles.brandAccent}>VOLUNTEER CREW</Text></Text>
      <Text className={styles.title} data-testid='volunteer-title'>把 Hacker Start 1024 开到你的城市</Text>
      <Text className={styles.subtitle}>志愿者体系招募中：组织一场 3 小时的工作坊，或把课程写成教程。</Text>
    </View>
  )
}

/** 当前批次：有批次（动态状态卡）/ 无 open 批次（空态，AE12） */
export function CohortSection({ cohort }: { cohort: RecruitmentCohort | null }) {
  const window = cohort ? cohortWindowText(cohort) : null
  return (
    <View className={styles.body}>
      <Text className={styles.sectionTitle}>当前批次<Text className={styles.sectionEn}>COHORT</Text></Text>
      {cohort ? (
        <View className={styles.cohortCard} data-testid='cohort-card'>
          <Text className={styles.cohortChip}>{cohortStatusText(cohort.status)}</Text>
          <Text className={styles.cohortName}>{cohort.name}</Text>
          <Text className={styles.cohortMeta}>{cohortDeadlineText(cohort)}</Text>
          {window && <Text className={styles.cohortMeta}>{window}</Text>}
          <Text className={styles.cohortNote}>每批单独招募、单独排期——错过这批，下一批开放时可以再申请。</Text>
        </View>
      ) : (
        <View className={styles.card} data-testid='cohort-empty'>
          <Text className={styles.cardTitle}>{NO_OPEN_COHORT_COPY}</Text>
          <Text className={styles.cardDesc}>{NO_OPEN_COHORT_HINT}</Text>
        </View>
      )}
    </View>
  )
}

export function PositionSection() {
  return (
    <View className={styles.body}>
      <Text className={styles.sectionTitle}>选择你的职位<Text className={styles.sectionEn}>OPEN ROLES</Text></Text>
      {VOLUNTEER_POSITIONS.map((position) => (
        <View key={position.key} className={`${styles.card} ${styles.cardBorder}`} data-testid={`position-${position.key}`}>
          <View className={styles.cardTop}>
            <Text className={styles.kicker}>{position.kicker}</Text>
            {position.chip && <Text className={styles.chip}>{position.chip}</Text>}
          </View>
          <Text className={styles.cardTitle}>{position.title}</Text>
          <Text className={styles.cardDesc}>{position.desc}</Text>
        </View>
      ))}
      <Text className={styles.footnote}>同一批次只能申请一个职位 · 入职后职位不互斥</Text>
    </View>
  )
}

export function JourneySection() {
  return (
    <View className={styles.body}>
      <Text className={styles.sectionTitle}>从申请到上岗<Text className={styles.sectionEn}>THE JOURNEY</Text></Text>
      <View className={styles.card}>
        {VOLUNTEER_JOURNEY.map((stage, index) => (
          <View key={stage.title} className={styles.step} data-testid={`journey-${index + 1}`}>
            <Text className={styles.stepIndex}>{index + 1}</Text>
            <Text className={styles.stepText}><Text className={styles.stepTitle}>{stage.title}</Text> · {stage.detail}</Text>
          </View>
        ))}
      </View>
      {/* R21/AE10 文案侧：邮件是保底通道——未授权时不承诺小程序通知必达 */}
      <Text className={styles.footnote}>每段结果都会发到你的联系邮箱；小程序通知需你在提交时逐次授权。</Text>
    </View>
  )
}

/** 我的申请（段位进度 + 拒绝原因 + M10 补授权位） */
export function MyApplicationsSection({
  applications,
  subscribeCopy,
  onSubscribe
}: {
  applications: VolunteerApplicationSummary[]
  subscribeCopy: string
  onSubscribe: () => void
}) {
  const touchpoint = volunteerFollowUpTouchpoint()
  return (
    <View className={styles.body}>
      <Text className={styles.sectionTitle}>我的申请<Text className={styles.sectionEn}>MY APPLICATION</Text></Text>
      {applications.length === 0 ? (
        <View className={styles.card} data-testid='my-applications-empty'>
          <Text className={styles.cardDesc}>还没有申请记录——完成下面的两步网申即可提交。</Text>
        </View>
      ) : applications.map((application) => {
        const progress = volunteerStageProgress(application.status)
        return (
          <View key={application.id} className={styles.card} data-testid={`my-application-${application.id}`}>
            <View className={styles.cardTop}>
              <Text className={styles.kicker}>{positionTitle(application.position)}</Text>
              <Text className={styles.statusChip} data-testid='application-status'>{volunteerStatusText(application.status)}</Text>
            </View>
            {progress ? (
              <View className={styles.progress}>
                {progress.map((stage) => (
                  <View
                    key={stage.label}
                    className={`${styles.progressCell} ${stage.state === 'current' ? styles.progressCurrent : ''}`}
                    data-testid={`application-stage-${stage.label}`}
                  >
                    <Text className={styles.progressLabel}>{stage.label}</Text>
                    <Text className={styles.progressState}>
                      {stage.state === 'done' ? '已完成' : stage.state === 'current' ? '进行中' : '待进行'}
                    </Text>
                  </View>
                ))}
              </View>
            ) : (
              // 终态不假造进度（rejected 不知道停在哪一段，canceled 是管理员操作）
              <Text className={styles.cardDesc}>
                {application.status === 'canceled' ? '该申请已取消。' : '本次申请未通过。'}
              </Text>
            )}
            {application.rejectionReason && <Text className={styles.rejectReason}>原因：{application.rejectionReason}</Text>}
            {application.assignmentNote && <Text className={styles.cardDesc}>分配备注：{application.assignmentNote}</Text>}
          </View>
        )
      })}

      {/* M10（R21）：前进路径三键已用满 M9 的单次上限，分配 / 拒绝 / 取消在此补授权 */}
      <Button className={styles.secondaryButton} size='mini' data-testid='subscribe-follow-up' onClick={onSubscribe}>
        {touchpoint.label}
      </Button>
      {subscribeCopy !== '' && <Text className={styles.subscribeCopy} data-testid='subscribe-copy'>{subscribeCopy}</Text>}
    </View>
  )
}

interface ApplySectionProps {
  user: UserSummary | null
  cohort: RecruitmentCohort | null
  application: VolunteerApplicationSummary | null
  profile: ResumeProfileSummary | null
  form: ApplyFormState
  /** 账号带回的默认值（手机号建号无邮箱 → 空串，须自己填；只做首次填充） */
  prefill: { fullName: string; contactEmail: string }
  saving: boolean
  submitting: boolean
  formError: string
  onLogin: () => void
  onPatch: (patch: Partial<ApplyFormState>) => void
  onProfileError: (message: string) => void
  onSaveProfile: () => void
  onEnsureProfile: () => Promise<void>
  onProfileUploaded: (profile: ResumeProfileSummary) => void
  onSubmit: () => void
}

/** 申请区：未登录 → 登录引导；无批次 → 入口收起；本批已申请 → 状态位；否则两步网申 */
export function ApplySection(props: ApplySectionProps) {
  const { user, cohort, application, profile, form, prefill } = props

  if (!user) {
    return (
      <View className={styles.body}>
        <Text className={styles.sectionTitle}>申请<Text className={styles.sectionEn}>APPLY</Text></Text>
        <View className={styles.card} data-testid='apply-login-gate'>
          <Text className={styles.cardTitle}>登录后申请</Text>
          <Text className={styles.cardDesc}>用手机号快捷登录（与网页端同一个账号），登录后即可看到当前批次并填写两步网申。</Text>
          <Button className={styles.primaryButton} data-testid='apply-login' onClick={props.onLogin}>
            登录并申请（10 分钟）
          </Button>
          <Text className={styles.cardNote}>两步网申：先完善简历档案，再申请项目 · 简历仅招募团队可见（PIPL）</Text>
        </View>
      </View>
    )
  }

  if (!cohort) {
    // AE12：无 open 批次 → 申请入口收起（批次区空态已说明原因）
    return (
      <View className={styles.body}>
        <Text className={styles.sectionTitle}>申请<Text className={styles.sectionEn}>APPLY</Text></Text>
        <View className={styles.card} data-testid='apply-closed'>
          <Text className={styles.cardDesc}>本批申请入口未开放，{NO_OPEN_COHORT_HINT}</Text>
        </View>
      </View>
    )
  }

  if (application) {
    return (
      <View className={styles.body}>
        <Text className={styles.sectionTitle}>申请<Text className={styles.sectionEn}>APPLY</Text></Text>
        <View className={styles.card} data-testid='apply-already'>
          <Text className={styles.cardDesc}>{ALREADY_APPLIED_COPY}</Text>
        </View>
      </View>
    )
  }

  const collapsed = resumeCollapsed(form, profile)
  const skills = form.skills
  return (
    <View className={styles.body}>
      <Text className={styles.sectionTitle}>两步网申<Text className={styles.sectionEn}>APPLY IN TWO STEPS</Text></Text>

      {/* 第 1 步：简历档案（跨批复用） */}
      <View className={styles.card} data-testid='resume-step'>
        <View className={styles.cardTop}>
          <Text className={styles.stepBadge}>第 1 步 · 完善简历档案</Text>
          {collapsed && (
            <Button className={styles.linkButton} size='mini' data-testid='edit-resume' onClick={() => props.onPatch({ editingResume: true })}>
              更新简历
            </Button>
          )}
        </View>

        {collapsed ? (
          <Text className={styles.cardDesc} data-testid='resume-summary'>
            档案已完善（{profile?.fileName}）——跨批次复用，无需重传。
          </Text>
        ) : (
          <View>
            <View className={styles.field}>
              <Text className={styles.label}>姓名</Text>
              {/* iOS 微信竞态纪律（#388，同 register-form）：值属性只在「载入时一次性
                  声明」的 defaultValue 上出现，绝不绑击键变化的 state。 */}
              <Input className={styles.input} defaultValue={prefill.fullName} placeholder='你的姓名' onInput={(event) => props.onPatch({ fullName: event.detail.value })} />
            </View>
            <View className={styles.field}>
              <Text className={styles.label}>联系邮箱</Text>
              <Input className={styles.input} defaultValue={prefill.contactEmail} placeholder='阶段结果会发到这个邮箱' onInput={(event) => props.onPatch({ contactEmail: event.detail.value })} />
            </View>
            <View className={styles.field}>
              <Text className={styles.label}>每周可投入小时数（选填）</Text>
              <Input className={styles.input} type='number' placeholder='例如 8' onInput={(event) => props.onPatch({ hoursInput: event.detail.value })} />
            </View>
            <View className={styles.field}>
              <Text className={styles.label}>技能标签（多选，选填）</Text>
              <View className={styles.skillRow}>
                {RESUME_SKILL_OPTIONS.map((skill) => (
                  <View
                    key={skill}
                    className={`${styles.skill} ${skills.includes(skill) ? styles.skillActive : ''}`}
                    data-testid={`skill-${skill}`}
                    onClick={() => props.onPatch({
                      skills: skills.includes(skill) ? skills.filter((item) => item !== skill) : [...skills, skill]
                    })}
                  >
                    <Text className={styles.skillText}>{skill}</Text>
                  </View>
                ))}
              </View>
            </View>

            <ResumeUpload
              profile={profile}
              ensureProfile={props.onEnsureProfile}
              onUploaded={props.onProfileUploaded}
              onError={props.onProfileError}
            />

            <Button
              className={styles.primaryButton}
              loading={props.saving}
              disabled={props.saving}
              data-testid='save-resume-profile'
              onClick={props.onSaveProfile}
            >
              {props.saving ? '正在保存…' : '保存并继续'}
            </Button>
            <Text className={styles.cardNote}>姓名与联系邮箱必填；简历上传一次，后续批次不用重传。</Text>
          </View>
        )}
      </View>

      {/* 第 2 步：申请项 + 提交（授权触点前移到这里，R21） */}
      {form.step === 2 ? (
        <View className={styles.card} data-testid='volunteer-application-form'>
          <Text className={styles.stepBadge}>第 2 步 · 申请项目</Text>
          <View className={styles.field}>
            <Text className={styles.label}>申请职位（本批限一个）</Text>
            {VOLUNTEER_POSITIONS.map((position) => (
              <View
                key={position.key}
                className={`${styles.option} ${form.position === position.key ? styles.optionActive : ''}`}
                data-testid={`position-option-${position.key}`}
                onClick={() => props.onPatch({ position: position.key })}
              >
                <Text className={styles.optionTitle}>{position.title}</Text>
                <Text className={styles.optionNote}>{position.kicker}{position.chip ? ` · ${position.chip}` : ''}</Text>
              </View>
            ))}
          </View>
          <View className={styles.field}>
            <Text className={styles.label}>申请城市（教程研究员可填「远程」）</Text>
            <Input className={styles.input} placeholder='例如 杭州' onInput={(event) => props.onPatch({ city: event.detail.value })} />
          </View>
          <View className={styles.field}>
            <Text className={styles.label}>如何得知我们（选填）</Text>
            <Input className={styles.input} placeholder='朋友圈 / 社群 / 朋友推荐…' onInput={(event) => props.onPatch({ heardAboutUs: event.detail.value })} />
          </View>
          <View
            className={styles.ackRow}
            data-testid='internal-referrer-option'
            onClick={() => props.onPatch({ hasInternalReferrer: !form.hasInternalReferrer })}
          >
            <View className={`${styles.ackBox} ${form.hasInternalReferrer ? styles.ackBoxChecked : ''}`} />
            <Text className={styles.ackLabel}>有内部推荐人</Text>
          </View>
          <View className={styles.field}>
            <Text className={styles.label}>想对我们说的话（选填）</Text>
            <Textarea className={styles.textarea} maxlength={500} placeholder='你的期待、时间安排、想开的城市…' onInput={(event) => props.onPatch({ message: event.detail.value })} />
          </View>

          {props.formError !== '' && <Text className={styles.error} data-testid='apply-error'>{props.formError}</Text>}
          <Button
            className={styles.primaryButton}
            loading={props.submitting}
            disabled={props.submitting}
            data-testid='submit-volunteer-application'
            onClick={props.onSubmit}
          >
            {props.submitting ? '正在提交…' : '提交申请'}
          </Button>
          <Button className={styles.ghostButton} size='mini' data-testid='back-to-resume' onClick={() => props.onPatch({ step: 1 })}>
            上一步
          </Button>
        </View>
      ) : (
        <Text className={styles.footnote}>完成第 1 步后进入第 2 步：选择职位、城市并提交。</Text>
      )}
    </View>
  )
}

export default function VolunteerApplyPage() {
  const [user, setUser] = useState<UserSummary | null>(null)
  const [cohort, setCohort] = useState<RecruitmentCohort | null>(null)
  const [profile, setProfile] = useState<ResumeProfileSummary | null>(null)
  const [applications, setApplications] = useState<VolunteerApplicationSummary[]>([])
  const [form, setForm] = useState<ApplyFormState>(INITIAL_APPLY_FORM)
  const [prefill, setPrefill] = useState({ fullName: '', contactEmail: '' })
  const [loading, setLoading] = useState(true)
  const [error, setError] = useState('')
  const [expired, setExpired] = useState(false)
  const [saving, setSaving] = useState(false)
  const [submitting, setSubmitting] = useState(false)
  const [formError, setFormError] = useState('')
  const [subscribeCopy, setSubscribeCopy] = useState('')
  const [toast, setToast] = useState('')

  const patch = useCallback((part: Partial<ApplyFormState>) => {
    setForm((current) => ({ ...current, ...part }))
  }, [])

  const load = useCallback(async () => {
    setLoading(true)
    setError('')
    setExpired(false)
    try {
      const session = await api.getSession()
      setUser(session.user)
      if (!session.user) {
        // 未登录：静态内容照常渲染，批次与表单进登录引导（AE1）
        setCohort(null)
        setProfile(null)
        setApplications([])
        return
      }
      // 窄化后固定引用：闭包（setForm 回调）里 TS 无法延续 session.user 的非空窄化
      const user = session.user
      const [cohortData, profileData, applicationList] = await Promise.all([
        api.getCurrentRecruitmentCohort(),
        api.getMyResumeProfile(),
        api.getMyVolunteerApplications()
      ])
      setCohort(cohortData)
      setProfile(profileData)
      setApplications(applicationList)
      setPrefill({
        fullName: profileData?.fullName ?? user.displayName,
        contactEmail: profileData?.contactEmail ?? user.email ?? ''
      })
      setForm((current) => ({
        ...current,
        // 手机号建号用户没有邮箱 → 第 1 步必须自己填（R9/R14 邮件保底通道的收件地址）
        fullName: profileData?.fullName ?? user.displayName,
        contactEmail: profileData?.contactEmail ?? user.email ?? '',
        hoursInput: profileData?.weeklyHours != null ? String(profileData.weeklyHours) : '',
        skills: profileData?.skills ?? [],
        // AE5：已有档案且有简历文件 → 跳过重传，直接进第 2 步
        step: hasResumeFile(profileData) ? 2 : 1,
        editingResume: !hasResumeFile(profileData)
      }))
    } catch (reason) {
      // 掉线 ≠ 招募流不可用：分叉出重登空态（同 my-enrollments 口径）
      if (reason instanceof SessionExpiredError) setExpired(true)
      else setError(reason instanceof Error ? reason.message : '招募信息加载失败')
    } finally {
      setLoading(false)
    }
  }, [])

  useDidShow(() => { void load() })

  const goLogin = () => {
    // 带回跳（照公开面既有写法）：登录页 redirectTo 回本页
    void Taro.redirectTo({
      url: `/pages/login/index?returnUrl=${encodeURIComponent(VOLUNTEER_APPLY_PATH)}`
    })
  }

  /** 表单值 → 后端入参（判据在 domain：选填字段空串不传，小时数非法归 undefined） */
  const profileForm = useCallback(() => ({
    fullName: form.fullName,
    contactEmail: form.contactEmail,
    weeklyHours: weeklyHoursValue(form.hoursInput),
    skills: form.skills.length > 0 ? form.skills : undefined
  }), [form.fullName, form.contactEmail, form.hoursInput, form.skills])

  const showError = useCallback((message: string) => {
    setFormError(message)
    void Taro.showToast({ title: message, icon: 'none' })
  }, [])

  const onProfileError = useCallback((message: string) => {
    setToast(message)
    void Taro.showToast({ title: message, icon: 'none' })
  }, [])

  /** 上传前的建档动作（U2 契约：先建档再上传；闭包读当前表单值） */
  const ensureProfile = useCallback(async () => {
    const saved = await api.saveResumeProfile(profileForm())
    setProfile(saved)
  }, [profileForm])

  const saveProfile = async () => {
    if (saving) return
    const invalid = resumeProfileError(profileForm())
    if (invalid) {
      showError(invalid)
      return
    }
    setSaving(true)
    setFormError('')
    try {
      const saved = await api.saveResumeProfile(profileForm())
      setProfile(saved)
      patch({ step: 2, editingResume: false })
    } catch (reason) {
      showError(reason instanceof Error ? reason.message : '档案保存失败，请重试。')
    } finally {
      setSaving(false)
    }
  }

  const submitApplication = async () => {
    if (!cohort || submitting) return
    if (form.position === '') {
      showError('请选择申请职位。')
      return
    }
    setSubmitting(true)
    setFormError('')
    try {
      // R21：授权触点前移到提交按钮——一次 requestSubscribeMessage 后逐个 grant，
      // 最后提交（顺序判据 = submitAfterConsent）。拒绝授权 / 模板缺配 / 平台报错
      // 一律不阻断提交（AE10：未授权时邮件是唯一可达通道，页面不报错）。
      const application = await submitAfterConsent(
        volunteerApplyTouchpoint(),
        {
          request: requestPlatformSubscriptions,
          grant: (scenario) => api.grantConsent(scenario)
        },
        () => api.createVolunteerApplication({
          cohortId: cohort.id,
          position: form.position as VolunteerPosition,
          city: form.city.trim() || undefined,
          heardAboutUs: form.heardAboutUs.trim() || undefined,
          hasInternalReferrer: form.hasInternalReferrer,
          message: form.message.trim() || undefined
        })
      )
      setApplications((current) => [application, ...current])
      setToast('申请已提交，可在「我的申请」查看段位。')
      void Taro.showToast({ title: '申请已提交', icon: 'success' })
    } catch (reason) {
      // 业务错误（本批已申请 / 批次关闭）按 code 查中文文案（domain/error-copy）
      showError(reason instanceof Error ? reason.message : '提交失败，请重试。')
    } finally {
      setSubmitting(false)
    }
  }

  /** M10 补授权位：独立触点（无提交动作）。拒绝/缺配/平台报错一律只改文案不报错（AE10） */
  const subscribeFollowUp = async () => {
    const touchpoint = volunteerFollowUpTouchpoint()
    setSubscribeCopy(await requestTouchpointConsent(touchpoint, {
      request: requestPlatformSubscriptions,
      grant: (scenario) => api.grantConsent(scenario)
    }))
  }

  // 三态 + 登录分流：纯判据在 domain（失败态与「无 open 批次」是不可合并的两桶）
  const pageState = recruitmentPageState({
    loading,
    expired,
    error,
    loggedIn: user !== null,
    cohort
  })

  if (pageState === 'loading') return <PageState kind='loading' />
  if (pageState === 'expired') {
    return (
      <PageState
        kind='empty'
        title='登录已过期'
        message='请重新登录后查看你的申请进度。'
        action={{ label: '重新登录', onClick: goLogin }}
        testId='volunteer-expired'
      />
    )
  }
  if (pageState === 'error') return <PageState kind='error' message={error} onRetry={load} testId='volunteer-error' />

  const application = cohort ? applicationForCohort(applications, cohort.id) : null
  return (
    <View className={styles.page} data-testid='volunteer-apply'>
      <VolunteerHero />
      <CohortSection cohort={cohort} />
      <PositionSection />
      <JourneySection />
      <ApplySection
        user={user}
        cohort={cohort}
        application={application}
        profile={profile}
        form={form}
        prefill={prefill}
        saving={saving}
        submitting={submitting}
        formError={formError}
        onLogin={goLogin}
        onPatch={patch}
        onProfileError={onProfileError}
        onSaveProfile={saveProfile}
        onEnsureProfile={ensureProfile}
        onProfileUploaded={(saved) => { setProfile(saved); setToast('简历已上传。') }}
        onSubmit={submitApplication}
      />
      <MyApplicationsSection applications={applications} subscribeCopy={subscribeCopy} onSubscribe={subscribeFollowUp} />
      {toast !== '' && <Text className={styles.toast} data-testid='volunteer-toast'>{toast}</Text>}
    </View>
  )
}
