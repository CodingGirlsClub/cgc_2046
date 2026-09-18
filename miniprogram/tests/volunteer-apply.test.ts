/**
 * 小程序招募流测试（R20/R21，plan U10）。
 *
 * 覆盖面（对应 plan U10 的 Test scenarios）：
 * 1. 未登录 → 登录引导而非表单（Covers AE1）；登录后批次/职位渲染。
 * 2. 三态：批次读取失败 → 失败文案 + 重试（**不显示无批次空态**）；无 open 批次 →
 *    空态 + 申请入口收起（Covers AE12 小程序侧）。
 * 3. 简历文件选择上传：前置校验（扩展名 / ≤5MB）→ 建档 → base64 → U2 单入口；
 *    二次进入已有档案 → 跳过上传（Covers AE5 小程序侧）。
 * 4. 提交成功 → 我的申请显示段位；本批已申请 → 入口收起。
 * 5. 订阅授权：M9 提交前（顺序由 subscription-domain 钉住）+ M10 补授权位；
 *    拒绝授权 → 只出文案不报错（Covers AE10 文案侧）。
 * 6. 零导流：页面文案不含 BANNED_TERMS（裁剪端页清单不登记本页，但仍按红线写）。
 *
 * 渲染用 renderToStaticMarkup 打展示件（同 tests/initiative.test.ts 的先例）；
 * 判据/文案全部来自 domain（小程序无页面渲染测试，AGENTS.md）。
 */

import { beforeEach, describe, expect, it, vi } from 'vitest'
import { createElement } from 'react'
import { renderToStaticMarkup } from 'react-dom/server'
import { BANNED_TERMS } from '../scripts/diversion-policy.mjs'
import type {
  RecruitmentCohort,
  ResumeProfileSummary,
  VolunteerApplicationSummary
} from '../src/domain/models'

const mocks = vi.hoisted(() => ({
  graphqlRequest: vi.fn(),
  getAuthToken: vi.fn(),
  setAuthToken: vi.fn(),
  isAuthenticationError: vi.fn(),
  redirectTo: vi.fn(),
  showToast: vi.fn(),
  chooseMessageFile: vi.fn(),
  readFileSync: vi.fn()
}))

vi.mock('../src/api/client', () => ({
  graphqlRequest: mocks.graphqlRequest,
  getAuthToken: mocks.getAuthToken,
  setAuthToken: mocks.setAuthToken,
  isAuthenticationError: mocks.isAuthenticationError,
  // real.ts 的 getSession 用 instanceof 做「服务端错误 → 清 token」判定，需真类
  GraphQLRequestError: class GraphQLRequestError extends Error {
    constructor(message: string, public readonly statusCode = 200, public readonly errors: unknown[] = []) {
      super(message)
    }
  }
}))
vi.mock('@tarojs/components', () => ({ Button: 'button', Input: 'input', Text: 'span', Textarea: 'textarea', View: 'div' }))
vi.mock('@tarojs/taro', () => ({
  default: {
    redirectTo: mocks.redirectTo,
    showToast: mocks.showToast,
    chooseMessageFile: mocks.chooseMessageFile,
    getFileSystemManager: () => ({ readFileSync: mocks.readFileSync }),
    // state/* 在 real.ts 的会话/账号态路径上读缓存（同 campaign.test.ts 的 Taro 假实现）
    getStorageSync: () => undefined,
    setStorageSync: () => undefined,
    removeStorageSync: () => undefined
  },
  useDidShow: vi.fn(),
  useRouter: () => ({ params: {} })
}))

import { RealMiniProgramApi, SessionExpiredError } from '../src/api/real'
import {
  ApplySection,
  CohortSection,
  INITIAL_APPLY_FORM,
  JourneySection,
  MyApplicationsSection,
  PositionSection,
  VolunteerHero,
  resumeCollapsed
} from '../src/pages/volunteer-apply'
import {
  chooseResumeFile,
  pickAndUploadResume,
  readResumeBase64,
  type ResumePickerTaro
} from '../src/components/resume-upload'
import {
  RESUME_FILE_MAX_BYTES,
  VOLUNTEER_POSITIONS,
  cohortDeadlineText,
  cohortStatusText,
  cohortWindowText,
  hasResumeFile,
  parseCohortStatus,
  parseVolunteerPosition,
  parseVolunteerStatus,
  positionTitle,
  recruitmentPageState,
  resumeContentTypeFor,
  resumeProfileError,
  resumeFileError,
  volunteerStageProgress,
  volunteerStatusText,
  weeklyHoursValue
} from '../src/domain/recruitment'
import { requestTouchpointConsent, volunteerApplyTouchpoint, volunteerFollowUpTouchpoint } from '../src/domain/subscription'

beforeEach(() => {
  vi.clearAllMocks()
})

// ── 夹具 ────────────────────────────────────────────────────────────────────

const cohort: RecruitmentCohort = {
  id: 'cohort-1',
  name: '第 1 批 · 首批志愿者招募',
  applyDeadlineAt: '2026-10-10T15:59:00Z',
  startsAt: '2026-10-24T02:00:00Z',
  endsAt: null,
  status: 'open'
}

const profile: ResumeProfileSummary = {
  id: 'resume-1',
  fullName: '小程',
  contactEmail: 'cheng@example.com',
  weeklyHours: 8,
  skills: ['组织'],
  fileName: 'resume.pdf',
  fileContentType: 'application/pdf',
  fileSize: 2048,
  uploadedAt: '2026-09-18T03:00:00Z'
}

const application: VolunteerApplicationSummary = {
  id: 'application-1',
  cohortId: cohort.id,
  position: 'event_moderator',
  city: '杭州',
  heardAboutUs: null,
  hasInternalReferrer: false,
  message: null,
  status: 'interview',
  rejectionReason: null,
  assignedEventId: null,
  assignmentNote: null,
  assignedAt: null
}

function applySectionHtml(overrides: Partial<Parameters<typeof ApplySection>[0]> = {}) {
  return renderToStaticMarkup(createElement(ApplySection, {
    user: { id: 'user-1', displayName: '小程', email: 'cheng@example.com', memberNumber: 'CGC-000001' },
    cohort,
    application: null,
    profile: null,
    form: INITIAL_APPLY_FORM,
    prefill: { fullName: '小程', contactEmail: 'cheng@example.com' },
    saving: false,
    submitting: false,
    formError: '',
    onLogin: vi.fn(),
    onPatch: vi.fn(),
    onProfileError: vi.fn(),
    onSaveProfile: vi.fn(),
    onEnsureProfile: async () => {},
    onProfileUploaded: vi.fn(),
    onSubmit: vi.fn(),
    ...overrides
  }))
}

function fakeTaro(overrides: Partial<ResumePickerTaro> = {}): ResumePickerTaro {
  return {
    chooseMessageFile: vi.fn().mockResolvedValue({ tempFiles: [{ name: 'resume.pdf', path: 'wxfile://tmp_1', size: 2048 }] }),
    getFileSystemManager: () => ({ readFileSync: () => 'JVBERi0xLjQK' }),
    showToast: vi.fn(),
    ...overrides
  }
}

// ── AE1：登录分流与内容渲染 ─────────────────────────────────────────────────

describe('登录分流（AE1）', () => {
  it('未登录 → 登录引导卡 + 登录按钮，不渲染网申表单', () => {
    const html = applySectionHtml({ user: null })
    expect(html).toContain('data-testid="apply-login-gate"')
    expect(html).toContain('登录并申请（10 分钟）')
    expect(html).not.toContain('data-testid="volunteer-application-form"')
    expect(html).not.toContain('data-testid="resume-step"')
  })

  it('登录 + 有批次 → 两步网申表单与第 1 步字段齐全', () => {
    const html = applySectionHtml()
    expect(html).toContain('data-testid="resume-step"')
    for (const field of ['姓名', '联系邮箱', '每周可投入小时数（选填）', '技能标签（多选，选填）']) {
      expect(html).toContain(field)
    }
    expect(html).toContain('data-testid="resume-upload"')
    expect(html).toContain('data-testid="save-resume-profile"')
    // 第 1 步未完成时第 2 步不渲染（两步网申的顺序）
    expect(html).not.toContain('data-testid="volunteer-application-form"')
  })

  it('第 2 步：三职位单选 + 城市/来源/推荐人/留言 + 提交按钮', () => {
    const html = applySectionHtml({ form: { ...INITIAL_APPLY_FORM, step: 2, editingResume: false }, profile })
    expect(html).toContain('data-testid="volunteer-application-form"')
    for (const { key, title } of VOLUNTEER_POSITIONS) {
      expect(html).toContain(`data-testid="position-option-${key}"`)
      expect(html).toContain(title)
    }
    expect(html).toContain('data-testid="internal-referrer-option"')
    expect(html).toContain('data-testid="submit-volunteer-application"')
    expect(html).toContain('本批限一个')
  })

  it('登录后的静态区：批次卡 / 三职位 / 四段流程（R20）', () => {
    const html = [
      renderToStaticMarkup(createElement(VolunteerHero)),
      renderToStaticMarkup(createElement(CohortSection, { cohort })),
      renderToStaticMarkup(createElement(PositionSection)),
      renderToStaticMarkup(createElement(JourneySection))
    ].join('')
    expect(html).toContain('把 Hacker Start 1024 开到你的城市')
    expect(html).toContain('第 1 批 · 首批志愿者招募')
    expect(html).toContain(cohortStatusText('open'))
    expect(html).toContain('申请截止')
    for (const { key } of VOLUNTEER_POSITIONS) expect(html).toContain(`data-testid="position-${key}"`)
    expect(html).toContain('首批最需要')
    for (const stage of ['网申', '面试', '训练营', '项目分配']) expect(html).toContain(stage)
    expect(html).toContain('data-testid="journey-4"')
  })
})

// ── 三态与空态（AE12 小程序侧） ──────────────────────────────────────────────

describe('页面三态（AE12 小程序侧）', () => {
  it('批次读取失败 → 错误态，绝不落到「无开放批次」空态', () => {
    expect(recruitmentPageState({ loading: false, expired: false, error: '招募信息加载失败', loggedIn: true, cohort: null }))
      .toBe('error')
  })

  it('无 open 批次（读取成功但为 null）→ 空态', () => {
    expect(recruitmentPageState({ loading: false, expired: false, error: '', loggedIn: true, cohort: null }))
      .toBe('empty')
  })

  it('判定优先级：加载中 → 掉线重登 → 失败 → 未登录 → 空态 → 就绪', () => {
    const base = { loading: false, expired: false, error: '', loggedIn: true, cohort }
    expect(recruitmentPageState({ ...base, loading: true, error: 'x', cohort: null })).toBe('loading')
    expect(recruitmentPageState({ ...base, expired: true, error: 'x', cohort: null })).toBe('expired')
    expect(recruitmentPageState({ ...base, error: 'x', cohort: null })).toBe('error')
    expect(recruitmentPageState({ ...base, loggedIn: false, cohort: null })).toBe('anonymous')
    expect(recruitmentPageState({ ...base, cohort: null })).toBe('empty')
    expect(recruitmentPageState(base)).toBe('ready')
  })

  it('空态渲染「当前无开放批次」且申请入口收起（不出现表单/登录卡）', () => {
    const html = [
      renderToStaticMarkup(createElement(CohortSection, { cohort: null })),
      applySectionHtml({ cohort: null })
    ].join('')
    expect(html).toContain('data-testid="cohort-empty"')
    expect(html).toContain('当前无开放批次')
    expect(html).toContain('data-testid="apply-closed"')
    expect(html).not.toContain('data-testid="volunteer-application-form"')
    expect(html).not.toContain('data-testid="apply-login-gate"')
  })

  it('批次卡动态状态：名称 / 状态 chip / 截止 / 执行周期', () => {
    expect(cohortStatusText('open')).toBe('进行中')
    expect(cohortStatusText('draft')).toBe('筹备中')
    expect(cohortStatusText('closed')).toBe('已结束')
    expect(cohortDeadlineText(cohort)).toContain('申请截止')
    expect(cohortWindowText(cohort)).toContain('执行周期')
    expect(cohortWindowText({ ...cohort, startsAt: null, endsAt: null })).toBeNull()
  })
})

// ── 档案与简历上传（AE5 小程序侧） ───────────────────────────────────────────

describe('简历文件选择上传（R9/U2）', () => {
  it('扩展名白名单与大小上限（前置校验，真判据在后端）', () => {
    expect(resumeFileError({ name: 'resume.pdf', size: 1024 })).toBeNull()
    expect(resumeFileError({ name: 'resume.DOC', size: 1024 })).toBeNull()
    expect(resumeFileError({ name: 'resume.docx', size: RESUME_FILE_MAX_BYTES })).toBeNull()
    expect(resumeFileError({ name: 'resume.zip', size: 1024 })).toContain('PDF')
    expect(resumeFileError({ name: 'resume.pdf.exe', size: 1024 })).toContain('PDF')
    expect(resumeFileError({ name: 'resume.pdf', size: 0 })).toContain('为空')
    expect(resumeFileError({ name: 'resume.pdf', size: RESUME_FILE_MAX_BYTES + 1 })).toContain('5MB')
  })

  it('声明 MIME 按扩展名给同族类型（后端三者一致才收）', () => {
    expect(resumeContentTypeFor('a.pdf')).toBe('application/pdf')
    expect(resumeContentTypeFor('a.doc')).toBe('application/msword')
    expect(resumeContentTypeFor('a.docx')).toBe('application/vnd.openxmlformats-officedocument.wordprocessingml.document')
    expect(resumeContentTypeFor('a.txt')).toBeNull()
  })

  it('选择文件：用户取消 → null 且不提示', async () => {
    const taro = fakeTaro({ chooseMessageFile: vi.fn().mockRejectedValue(new Error('chooseMessageFile:fail cancel')) })
    expect(await chooseResumeFile(taro)).toBeNull()
    expect(taro.showToast).not.toHaveBeenCalled()
  })

  it('选择文件：不合法 → 提示 + null；合法 → 带同族 MIME 的选择结果', async () => {
    const invalid = fakeTaro({
      chooseMessageFile: vi.fn().mockResolvedValue({ tempFiles: [{ name: 'resume.zip', path: 'wxfile://tmp_2', size: 1024 }] })
    })
    expect(await chooseResumeFile(invalid)).toBeNull()
    expect(invalid.showToast).toHaveBeenCalledWith({ title: expect.stringContaining('PDF'), icon: 'none' })

    const valid = fakeTaro()
    expect(await chooseResumeFile(valid)).toEqual({
      name: 'resume.pdf',
      path: 'wxfile://tmp_1',
      size: 2048,
      contentType: 'application/pdf'
    })
  })

  it('上传编排：建档先于上传，base64 原样进 U2 请求体（不重编码）', async () => {
    const calls: string[] = []
    const taro = fakeTaro({ getFileSystemManager: () => ({ readFileSync: (path) => { calls.push(`read:${path}`); return 'JVBERi0xLjQK' } }) })
    const uploaded = await pickAndUploadResume({
      taro,
      ensureProfile: async () => { calls.push('ensureProfile') },
      upload: async (input) => {
        calls.push(`upload:${input.fileName}:${input.contentType}:${input.contentBase64}`)
        return profile
      }
    })

    expect(uploaded).toEqual(profile)
    // 顺序 = 契约：U2 要求先建档再上传（档案缺失会被 resume_profile_not_found 拒）
    expect(calls).toEqual([
      'read:wxfile://tmp_1',
      'ensureProfile',
      'upload:resume.pdf:application/pdf:JVBERi0xLjQK'
    ])
  })

  it('上传编排：选择被取消 → 不建档、不上传（不留半成品档案）', async () => {
    const calls: string[] = []
    const uploaded = await pickAndUploadResume({
      taro: fakeTaro({ chooseMessageFile: vi.fn().mockRejectedValue(new Error('cancel')) }),
      ensureProfile: async () => { calls.push('ensureProfile') },
      upload: async () => { calls.push('upload'); return profile }
    })
    expect(uploaded).toBeNull()
    expect(calls).toEqual([])
  })

  it('读取失败（空内容）→ 抛可读错误，页面据此提示重试', () => {
    const taro = fakeTaro({ getFileSystemManager: () => ({ readFileSync: () => '' }) })
    expect(() => readResumeBase64(taro, 'wxfile://tmp_1')).toThrow('简历文件读取失败')
  })

  it('AE5：已有档案 + 有文件 → 跳过重传，直接进第 2 步', () => {
    expect(hasResumeFile(profile)).toBe(true)
    expect(hasResumeFile({ ...profile, fileName: null })).toBe(false)
    expect(hasResumeFile(null)).toBe(false)

    // 页面的初始态推导（load 里的同一判据）：有文件 → step 2 + 收起第 1 步
    const collapsed = resumeCollapsed({ ...INITIAL_APPLY_FORM, step: 2, editingResume: false }, profile)
    expect(collapsed).toBe(true)
    expect(resumeCollapsed({ ...INITIAL_APPLY_FORM, editingResume: true }, profile)).toBe(false)
    expect(resumeCollapsed({ ...INITIAL_APPLY_FORM, step: 2, editingResume: false }, null)).toBe(false)
  })

  it('第 1 步收起态渲染档案摘要 + 「更新简历」入口', () => {
    const html = applySectionHtml({
      form: { ...INITIAL_APPLY_FORM, step: 2, editingResume: false },
      profile
    })
    expect(html).toContain('data-testid="resume-summary"')
    expect(html).toContain('resume.pdf')
    expect(html).toContain('跨批次复用')
    expect(html).toContain('data-testid="edit-resume"')
    expect(html).not.toContain('data-testid="resume-upload"')
  })
})

// ── 我的申请（段位）与提交 ──────────────────────────────────────────────────

describe('我的申请与申请入口（AE2/AE5 小程序侧）', () => {
  it('提交成功 → 我的申请显示段位（四段进度 + 当前段）', () => {
    const html = renderToStaticMarkup(createElement(MyApplicationsSection, {
      applications: [application],
      subscribeCopy: '',
      onSubscribe: vi.fn()
    }))
    expect(html).toContain('data-testid="my-application-application-1"')
    expect(html).toContain(positionTitle('event_moderator'))
    expect(html).toContain(volunteerStatusText('interview'))
    expect(html).toContain('data-testid="application-stage-面试"')
    expect(html).toContain('进行中')
    expect(html).toContain('已完成')
  })

  it('段位 → 进度：前进路径下标正确，终态不画进度', () => {
    expect(volunteerStageProgress('submitted')?.map(({ state }) => state)).toEqual(['current', 'todo', 'todo', 'todo'])
    expect(volunteerStageProgress('assigned')?.map(({ state }) => state)).toEqual(['done', 'done', 'done', 'current'])
    expect(volunteerStageProgress('rejected')).toBeNull()
    expect(volunteerStageProgress('canceled')).toBeNull()
  })

  it('rejected 显示拒绝原因，canceled 显示取消文案（不假造进度）', () => {
    const rejected = renderToStaticMarkup(createElement(MyApplicationsSection, {
      applications: [{ ...application, status: 'rejected', rejectionReason: '本批名额有限' }],
      subscribeCopy: '',
      onSubscribe: vi.fn()
    }))
    expect(rejected).toContain('本次申请未通过')
    expect(rejected).toContain('原因：本批名额有限')
    expect(rejected).not.toContain('data-testid="application-stage-网申"')

    const canceled = renderToStaticMarkup(createElement(MyApplicationsSection, {
      applications: [{ ...application, status: 'canceled' }],
      subscribeCopy: '',
      onSubscribe: vi.fn()
    }))
    expect(canceled).toContain('该申请已取消')
  })

  it('本批已申请 → 申请入口收起为状态位（同批一份）', () => {
    const html = applySectionHtml({ application })
    expect(html).toContain('data-testid="apply-already"')
    expect(html).toContain('本批次你已提交申请')
    expect(html).not.toContain('data-testid="volunteer-application-form"')
    expect(html).not.toContain('data-testid="resume-step"')
  })

  it('必填校验与选填入参归一（邮箱是 R14 邮件保底通道收件地址）', () => {
    expect(resumeProfileError({ fullName: '  ', contactEmail: 'a@b.com' })).toContain('姓名')
    expect(resumeProfileError({ fullName: '小程', contactEmail: ' ' })).toContain('邮箱')
    expect(resumeProfileError({ fullName: '小程', contactEmail: 'a@b.com' })).toBeNull()
    expect(weeklyHoursValue('8')).toBe(8)
    expect(weeklyHoursValue('')).toBeUndefined()
    expect(weeklyHoursValue('0')).toBeUndefined()
    expect(weeklyHoursValue('-3')).toBeUndefined()
    expect(weeklyHoursValue('abc')).toBeUndefined()
  })

  it('段位/职位/批次状态解析：未知值 fail-closed（不冒充合法值）', () => {
    expect(parseVolunteerStatus('training')).toBe('training')
    expect(() => parseVolunteerStatus('hired')).toThrow('未知申请段位')
    expect(parseVolunteerPosition('tutor')).toBe('tutor')
    expect(() => parseVolunteerPosition('organizer')).toThrow('未知志愿者职位')
    expect(parseCohortStatus('open')).toBe('open')
    expect(() => parseCohortStatus('paused')).toThrow('未知批次状态')
  })
})

// ── 订阅（R21 / AE10 文案侧） ───────────────────────────────────────────────

describe('订阅授权（R21/AE10）', () => {
  it('M9 提交前：六键里取前进路径三键（恰 3，微信单次上限）', () => {
    const touchpoint = volunteerApplyTouchpoint()
    expect(touchpoint.scenarios).toEqual([
      'volunteer_application_submitted',
      'volunteer_application_interview',
      'volunteer_application_training'
    ])
    expect(touchpoint.page).toContain('第 2 步')
  })

  it('M10 补授权位：分配 + 拒绝 + 取消（与 M9 不重叠，合计覆盖六键）', () => {
    const followUp = volunteerFollowUpTouchpoint()
    expect(followUp.scenarios).toEqual([
      'volunteer_application_assigned',
      'volunteer_application_rejected',
      'volunteer_application_canceled'
    ])
    const overlap = followUp.scenarios.filter((scenario) => volunteerApplyTouchpoint().scenarios.includes(scenario))
    expect(overlap).toEqual([])
    expect([...volunteerApplyTouchpoint().scenarios, ...followUp.scenarios]).toHaveLength(6)
  })

  it('AE10 文案侧：未授权不承诺小程序通知，指向联系邮箱（不写「不可再订阅」）', () => {
    for (const touchpoint of [volunteerApplyTouchpoint(), volunteerFollowUpTouchpoint()]) {
      expect(touchpoint.deniedCopy).toContain('邮箱')
      expect(touchpoint.deniedCopy).not.toMatch(/一定|必然|必达/)
      expect(touchpoint.deniedCopy).toMatch(/再/)
      expect(touchpoint.acceptedCopy).not.toContain('微信')
    }
    // 页面静态文案同样只承诺邮件（R21 文案侧）
    expect(renderToStaticMarkup(createElement(JourneySection))).toContain('联系邮箱')
  })

  it('M10 授权被拒 → 只返回拒绝文案（不抛错、不阻断页面）', async () => {
    const copy = await requestTouchpointConsent(volunteerFollowUpTouchpoint(), {
      request: async () => [],
      grant: async () => {}
    })
    expect(copy).toBe(volunteerFollowUpTouchpoint().deniedCopy)
  })

  it('M10 请求抛错（模板缺配 / 平台拒绝）→ 同样回落拒绝文案', async () => {
    const copy = await requestTouchpointConsent(volunteerFollowUpTouchpoint(), {
      request: async () => { throw new Error('缺少微信订阅消息模板 ID') },
      grant: async () => {}
    })
    expect(copy).toBe(volunteerFollowUpTouchpoint().deniedCopy)
  })

  it('M10 被接受 → 逐个 grant 后返回接受文案', async () => {
    const granted: string[] = []
    const copy = await requestTouchpointConsent(volunteerFollowUpTouchpoint(), {
      request: async () => ['volunteer_application_assigned', 'volunteer_application_rejected'],
      grant: async (scenario) => { granted.push(scenario) }
    })
    expect(granted).toEqual(['volunteer_application_assigned', 'volunteer_application_rejected'])
    expect(copy).toBe(volunteerFollowUpTouchpoint().acceptedCopy)
  })

  it('补授权位渲染在「我的申请」区（提交完成页的落点）', () => {
    const html = renderToStaticMarkup(createElement(MyApplicationsSection, {
      applications: [application],
      subscribeCopy: volunteerFollowUpTouchpoint().deniedCopy,
      onSubscribe: vi.fn()
    }))
    expect(html).toContain('data-testid="subscribe-follow-up"')
    expect(html).toContain(volunteerFollowUpTouchpoint().label)
    expect(html).toContain('data-testid="subscribe-copy"')
    expect(html).toContain(volunteerFollowUpTouchpoint().deniedCopy)
  })
})

// ── API 契约（real.ts：selection / 入参 / 错误桶） ──────────────────────────

describe('招募 API 契约（real.ts）', () => {
  const session = {
    me: { id: 'user-1', email: 'cheng@example.com', displayName: '小程', memberNumber: null, joinedAt: null, isPlatformAdmin: false },
    meWorkspaces: [],
    myPendingApprovals: []
  }

  // 本组每个用例自带 mock 链：先 reset（外层 clearAllMocks 不清实现，残留的
  // mockResolvedValue 会串到下一个用例），再给带 token 的会话夹具（fetchSession
  // 无 token 早退，不算掉线）。
  beforeEach(() => {
    mocks.graphqlRequest.mockReset()
    mocks.isAuthenticationError.mockReset().mockReturnValue(false)
    mocks.getAuthToken.mockReset().mockReturnValue('token-1')
  })

  /**
   * 读面的调用序（新实例）：getMyVolunteerApplications 自身先 getSession 一次，
   * resolveRecruitmentWorkspaceId 再 getSession 一次（缓存后不再查 slug）。
   * 链里因此出现两次 session 记录。
   */
  function prime(...payloads: unknown[]) {
    for (const payload of payloads) mocks.graphqlRequest.mockResolvedValueOnce(payload)
  }

  const applicationRecord = {
    id: 'application-1',
    cohortId: 'cohort-1',
    position: 'tutor',
    city: null,
    heardAboutUs: null,
    hasInternalReferrer: false,
    message: null,
    status: 'submitted',
    rejectionReason: null,
    assignedEventId: null,
    assignmentNote: null,
    assignedAt: null
  }

  it('入口 workspace 按 slug 解析一次并复用（三读面共用，不重复查 slug）', async () => {
    prime(
      session,
      { getWorkspace: { id: 'ws-2046', name: '2046 社区' } },
      { currentRecruitmentCohort: null },
      { myResumeProfile: null }
    )

    const api = new RealMiniProgramApi()
    expect(await api.getCurrentRecruitmentCohort()).toBeNull()
    expect(await api.getMyResumeProfile()).toBeNull()

    expect(mocks.graphqlRequest).toHaveBeenCalledTimes(4)
    expect(String(mocks.graphqlRequest.mock.calls[1]?.[0])).toContain('query RecruitmentWorkspace')
    expect(mocks.graphqlRequest.mock.calls[1]?.[1]).toEqual({ slug: '2046' })
    // 后两次都用缓存下来的 workspaceId（不再查 slug）
    expect(mocks.graphqlRequest.mock.calls[2]?.[1]).toEqual({ workspaceId: 'ws-2046' })
    expect(mocks.graphqlRequest.mock.calls[3]?.[1]).toEqual({ workspaceId: 'ws-2046' })
  })

  it('未登录：不发招聘请求（getWorkspace 需登录），给出可读提示', async () => {
    prime({ me: null, meWorkspaces: [], myPendingApprovals: [] })
    await expect(new RealMiniProgramApi().getCurrentRecruitmentCohort()).rejects.toThrow('请先登录')
    expect(mocks.graphqlRequest).toHaveBeenCalledTimes(1)
  })

  it('申请列表：掉线 → SessionExpiredError；未登录 → 空列表', async () => {
    prime({ me: null, meWorkspaces: [], myPendingApprovals: [] })
    expect(await new RealMiniProgramApi().getMyVolunteerApplications()).toEqual([])

    mocks.isAuthenticationError.mockReturnValue(true)
    mocks.graphqlRequest.mockRejectedValueOnce(Object.assign(new Error('unauthorized'), { errors: [{ code: 'unauthorized' }] }))
    await expect(new RealMiniProgramApi().getMyVolunteerApplications()).rejects.toBeInstanceOf(SessionExpiredError)
  })

  it('段位映射透传 + 未知段位 fail-closed（不静默显示成「已提交」）', async () => {
    prime(session, session, { getWorkspace: { id: 'ws-2046', name: '2046 社区' } }, { myVolunteerApplications: [applicationRecord] })
    const [row] = await new RealMiniProgramApi().getMyVolunteerApplications()
    expect(row?.position).toBe('tutor')
    expect(row?.status).toBe('submitted')

    prime(session, session, { getWorkspace: { id: 'ws-2046', name: '2046 社区' } }, { myVolunteerApplications: [{ ...applicationRecord, status: 'hired' }] })
    await expect(new RealMiniProgramApi().getMyVolunteerApplications()).rejects.toThrow('未知申请段位')
  })

  it('提交申请：selection 带全部回显字段，入参只带非空选填项', async () => {
    // create 链 3 次调用：resolve（session + getWorkspace）→ mutation（无「自身先 getSession」）
    prime(session, { getWorkspace: { id: 'ws-2046', name: '2046 社区' } }, { createVolunteerApplication: { result: applicationRecord, errors: [] } })

    const created = await new RealMiniProgramApi().createVolunteerApplication({
      cohortId: 'cohort-1',
      position: 'tutor',
      city: '',
      heardAboutUs: '',
      message: ''
    })

    const document = String(mocks.graphqlRequest.mock.calls[2]?.[0])
    for (const field of ['cohortId', 'position', 'status', 'rejectionReason', 'assignmentNote']) {
      expect(document).toContain(field)
    }
    expect(mocks.graphqlRequest.mock.calls[2]?.[1]).toEqual({
      workspaceId: 'ws-2046',
      input: { cohortId: 'cohort-1', position: 'tutor', hasInternalReferrer: false }
    })
    expect(created.id).toBe('application-1')
  })

  it('业务错误按 code 出中文文案（本批已申请）', async () => {
    prime(session, { getWorkspace: { id: 'ws-2046', name: '2046 社区' } }, {
      createVolunteerApplication: {
        result: null,
        errors: [{ message: 'already submitted', code: 'volunteer_application_already_submitted' }]
      }
    })
    await expect(new RealMiniProgramApi().createVolunteerApplication({ cohortId: 'cohort-1', position: 'coach' }))
      .rejects.toThrow('本批次你已经提交过申请')
  })

  it('简历：先建档再上传（U2），上传单独放宽超时', async () => {
    const resumeRecord = {
      id: 'resume-1',
      fullName: '小程',
      contactEmail: 'cheng@example.com',
      weeklyHours: null,
      skills: [],
      fileName: null,
      fileContentType: null,
      fileSize: null,
      uploadedAt: null
    }
    prime(
      session,
      { getWorkspace: { id: 'ws-2046', name: '2046 社区' } },
      { upsertResumeProfile: { result: resumeRecord, errors: [] } },
      {
        uploadResumeFile: {
          result: { ...resumeRecord, fileName: 'resume.pdf', fileContentType: 'application/pdf', fileSize: 2048, uploadedAt: '2026-09-18T03:00:00Z' },
          errors: []
        }
      }
    )

    const api = new RealMiniProgramApi()
    const saved = await api.saveResumeProfile({ fullName: ' 小程 ', contactEmail: ' cheng@example.com ', skills: [] })
    expect(saved.fileName).toBeNull()
    expect(mocks.graphqlRequest.mock.calls[2]?.[1]).toEqual({
      workspaceId: 'ws-2046',
      input: { fullName: '小程', contactEmail: 'cheng@example.com', skills: [] }
    })

    const uploaded = await api.uploadResumeFile({ fileName: 'resume.pdf', contentType: 'application/pdf', contentBase64: 'JVBERi0xLjQK' })
    expect(uploaded.fileName).toBe('resume.pdf')
    expect(uploaded.fileSize).toBe(2048)
    expect(mocks.graphqlRequest.mock.calls[3]?.[2]).toEqual({ timeoutMs: 60_000 })
  })

  it('档案缺失上传 → resume_profile_not_found 出中文文案（U2 契约）', async () => {
    prime(session, { getWorkspace: { id: 'ws-2046', name: '2046 社区' } }, {
      uploadResumeFile: {
        result: null,
        errors: [{ message: 'resume profile not found', code: 'resume_profile_not_found' }]
      }
    })
    await expect(new RealMiniProgramApi().uploadResumeFile({ fileName: 'a.pdf', contentType: 'application/pdf', contentBase64: 'x' }))
      .rejects.toThrow('请先完善简历档案')
  })
})

// ── 分流与零导流 ────────────────────────────────────────────────────────────

describe('页面注册与零导流', () => {
  async function loadAppConfig(platform: string) {
    vi.stubGlobal('defineAppConfig', (config: unknown) => config)
    const original = process.env.TARO_ENV
    process.env.TARO_ENV = platform
    try {
      vi.resetModules()
      const { default: config } = await import('../src/app.config')
      return config as { pages: string[]; tabBar: { list: Array<{ pagePath: string }> } }
    } finally {
      process.env.TARO_ENV = original
      vi.unstubAllGlobals()
    }
  }

  it('微信端页清单登记招募流（campaign 页「成为志愿者」的落点）', async () => {
    const config = await loadAppConfig('weapp')
    expect(config.pages).toContain('pages/volunteer-apply/index')
    expect(config.pages).toContain('pages/campaign/index')
  })

  it.each(['tt', 'xhs'])('%s 端页清单不挂招募流（微信端专属；裁剪端无 campaign 页，无入口可达）', async (platform) => {
    const config = await loadAppConfig(platform)
    expect(config.pages).not.toContain('pages/volunteer-apply/index')
    expect(config.pages).not.toContain('pages/campaign/index')
  })

  it('页面文案不含零导流禁词（BANNED_TERMS 单源）', () => {
    const html = [
      renderToStaticMarkup(createElement(VolunteerHero)),
      renderToStaticMarkup(createElement(CohortSection, { cohort })),
      renderToStaticMarkup(createElement(PositionSection)),
      renderToStaticMarkup(createElement(JourneySection)),
      applySectionHtml({ form: { ...INITIAL_APPLY_FORM, step: 2, editingResume: false }, profile }),
      renderToStaticMarkup(createElement(MyApplicationsSection, { applications: [application], subscribeCopy: volunteerFollowUpTouchpoint().deniedCopy, onSubscribe: vi.fn() }))
    ].join('')
    for (const term of BANNED_TERMS) expect(html).not.toContain(term)
  })
})
