/**
 * 志愿者招募域（R20/R21）——批次 / 三职位 / 四段流程 / 两步网申 / 我的申请。
 *
 * 页面（pages/volunteer-apply，微信端专属）只留渲染与调起：职位清单、段位文案、
 * 批次文案、简历文件的前置校验、同批一份的判据全部下沉本模块（AGENTS.md：小程序
 * 无页面渲染测试，逻辑必须下沉 domain 用测试钉住）。
 *
 * ## 入口 workspace 的解析（与 web 的差异，勿默默补齐）
 *
 * 三资源都带 `workspace_id` 租户，GraphQL 入口是显式 argument（KTD2）。小程序没有
 * URL slug，故按 **slug 常量 + 已登录的 `getWorkspace(slug:)`** 解析（KTD2：所有
 * 倡导活动都在 2046 台；该工作台由部署 seed 固定，见 CONTEXT.md「默认 workspace」）。
 *
 * `getWorkspace` 的策略是 `actor_present`（actor 定向读，匿名不可）——因此**匿名
 * 用户拿不到 workspaceId，批次区只能先登录**。这是本页与 web 申请页的**有意差异**：
 * 公网可查的批次口径在 web 申请页 / campaign 页，小程序侧的分流是「先登录再看批次」，
 * AE1（未登录 → 登录引导而非表单）即此。后端刻意不为小程序开匿名 workspace 解析面。
 *
 * ## 简历文件校验的两层分工
 *
 * 本模块只做**能省一次往返的前置校验**（扩展名白名单 + ≤5MB），真判据在后端
 * U2 `Recruitment.Upload.store/3`（扩展名 / 声明 MIME / 文件头魔数三者一致，大小
 * 以实际解码字节数计）。魔数与 declared MIME 的一致性**不在此复刻**——客户端拿不到
 * 权威类型信息，复刻只会造出与后端漂移的第二份判据。
 */

import { formatDateTime } from './format'
import type {
  RecruitmentCohort,
  RecruitmentCohortStatus,
  ResumeProfileForm,
  ResumeProfileSummary,
  VolunteerApplicationSummary,
  VolunteerPosition,
  VolunteerStatus
} from './models'

/**
 * 招募入口工作台 slug（KTD2：所有倡导活动都在 2046 台）。与
 * `web` 的 `/w/2046/...` 同址；集中在这里，改一处即可。
 */
export const RECRUITMENT_WORKSPACE_SLUG = '2046'

/** 招募流页面路径（campaign 页「成为志愿者」入口的落点，U9 已引用） */
export const VOLUNTEER_APPLY_PATH = '/pages/volunteer-apply/index'

/** 三职位（R20；kicker/文案取自原型 weapp-host，与 web 申请页同口径） */
export const VOLUNTEER_POSITIONS: readonly {
  key: VolunteerPosition
  kicker: string
  title: string
  desc: string
  /** 首批最需要的职位标记（仅主理人） */
  chip: string | null
}[] = [
  {
    key: 'event_moderator',
    kicker: 'EVENT MODERATOR',
    title: '场次主理人',
    desc: '组织一场 3 小时工作坊的完整 owner——把它开到你的城市。适合有场地或社群资源、每期一个周末的组织者。',
    chip: '首批最需要'
  },
  {
    key: 'tutor',
    kicker: 'TUTOR',
    title: '教程研究员',
    desc: '把课程写成可复用的教程与示例项目，一门课预估投入 5-10 小时。适合会编程、能写作的程序员，远程参与。',
    chip: null
  },
  {
    key: 'coach',
    kicker: 'COACH',
    title: '活动教练',
    desc: '线下现场辅助陪跑：巡场答疑、帮学员跑通动手环节，学员自学为主、不讲课。适合用过 Agent 工具的人。',
    chip: null
  }
]

/** 四段流程（R20；文案取自原型 weapp-host） */
export const VOLUNTEER_JOURNEY: readonly { title: string; detail: string }[] = [
  { title: '网申', detail: '先完善简历（跨批复用），再申请项目：批次、职位、城市。同批限申一个职位' },
  { title: '面试', detail: '线上群面约 30 分钟——约好时间后自我介绍 + 材料共读讨论' },
  { title: '训练营', detail: '线上训练营（站内的一门课程）：walkthrough + 共备，入选后运营拉你进课程' },
  { title: '项目分配', detail: '主理人指派场次、教程研究员分配课程任务——正式进入志愿者网络' }
]

/** 四段段位标签（我的申请进度条与「段」同名；R12 状态图的前进路径） */
export const VOLUNTEER_STAGES = ['网申', '面试', '训练营', '项目分配'] as const

/** 前进路径的段位下标；rejected/canceled 是脱离路径的终态 → -1（不画进度） */
const STAGE_INDEX: Record<VolunteerStatus, number> = {
  submitted: 0,
  interview: 1,
  training: 2,
  assigned: 3,
  rejected: -1,
  canceled: -1
}

/** 段位文案（我的申请卡片主状态行） */
export function volunteerStatusText(status: VolunteerStatus): string {
  switch (status) {
    case 'submitted': return '已提交 · 等待初审'
    case 'interview': return '面试沟通中'
    case 'training': return '训练营阶段'
    case 'assigned': return '已分配 · 欢迎加入'
    case 'rejected': return '本批未通过'
    case 'canceled': return '已取消'
  }
}

/** 申请是否在前进路径上（rejected/canceled → false：不画四段进度，只出终态文案） */
export function isActiveApplication(status: VolunteerStatus): boolean {
  return STAGE_INDEX[status] >= 0
}

/** 四段进度（done/current/todo）；终态 → null（页面据此只渲染终态行，不假造进度） */
export function volunteerStageProgress(
  status: VolunteerStatus
): { label: string; state: 'done' | 'current' | 'todo' }[] | null {
  const index = STAGE_INDEX[status]
  if (index < 0) return null
  return VOLUNTEER_STAGES.map((label, position) => ({
    label,
    state: position < index ? 'done' : position === index ? 'current' : 'todo'
  }))
}

/** 职位展示名（申请卡片回显；未知 key 原样返回，不臆造中文名） */
export function positionTitle(position: VolunteerPosition): string {
  return VOLUNTEER_POSITIONS.find(({ key }) => key === position)?.title ?? position
}

/** 解析职位（后端字符串枚举；未知值 fail-closed 抛错，不静默降级到某个职位） */
export function parseVolunteerPosition(value: string): VolunteerPosition {
  if (value === 'event_moderator' || value === 'tutor' || value === 'coach') return value
  throw new Error(`服务端返回未知志愿者职位：${value}`)
}

/** 解析段位（同上 fail-closed；未知段位不得当成「已提交」展示） */
export function parseVolunteerStatus(value: string): VolunteerStatus {
  if (
    value === 'submitted' || value === 'interview' || value === 'training' ||
    value === 'assigned' || value === 'rejected' || value === 'canceled'
  ) return value
  throw new Error(`服务端返回未知申请段位：${value}`)
}

/** 解析批次状态（申请侧只见 open；draft/closed 到达即异常） */
export function parseCohortStatus(value: string): RecruitmentCohortStatus {
  if (value === 'draft' || value === 'open' || value === 'closed') return value
  throw new Error(`服务端返回未知批次状态：${value}`)
}

/** 批次状态文案（原型批次卡右上角 chip） */
export function cohortStatusText(status: RecruitmentCohortStatus): string {
  switch (status) {
    case 'open': return '进行中'
    case 'draft': return '筹备中'
    case 'closed': return '已结束'
  }
}

/** 批次截止行（展示格式单源 = 既有 formatDateTime，不引第二种时间格式） */
export function cohortDeadlineText(cohort: RecruitmentCohort): string {
  return `申请截止 ${formatDateTime(cohort.applyDeadlineAt)}`
}

/** 批次执行周期行（两端皆空 → null，页面不渲染空行） */
export function cohortWindowText(cohort: RecruitmentCohort): string | null {
  const start = cohort.startsAt ? formatDateTime(cohort.startsAt) : null
  const end = cohort.endsAt ? formatDateTime(cohort.endsAt) : null
  if (start && end) return `执行周期 ${start} - ${end}`
  if (start) return `执行周期 ${start} 起`
  if (end) return `执行周期至 ${end}`
  return null
}

/** 无 open 批次空态文案（AE12 小程序侧；申请入口同时收起） */
export const NO_OPEN_COHORT_COPY = '当前无开放批次'
export const NO_OPEN_COHORT_HINT = '下一批开放后，可在这里直接申请。'

// ── 简历文件（U2 管道的前置校验） ────────────────────────────────────────────

/** 原始文件上限（与后端 Upload 的 @max_file_size 同值：5MB） */
export const RESUME_FILE_MAX_BYTES = 5 * 1024 * 1024

/** 支持的扩展名（与后端 family_of/1 同集） */
export const RESUME_FILE_EXTENSIONS = ['pdf', 'doc', 'docx'] as const

const RESUME_CONTENT_TYPES: Record<string, string> = {
  pdf: 'application/pdf',
  doc: 'application/msword',
  docx: 'application/vnd.openxmlformats-officedocument.wordprocessingml.document'
}

/** 扩展名（小写、去点）；无扩展名 → '' */
export function resumeExtension(name: string): string {
  const dot = name.lastIndexOf('.')
  return dot < 0 ? '' : name.slice(dot + 1).toLowerCase()
}

/** 按扩展名给同族声明 MIME；不支持的扩展名 → null（不猜类型——后端三者一致才收） */
export function resumeContentTypeFor(name: string): string | null {
  return RESUME_CONTENT_TYPES[resumeExtension(name)] ?? null
}

/**
 * 选择文件后的前置校验：null = 通过（仍以后端判据为准），否则为可读的错误文案。
 * 大小判定用 chooseMessageFile 的 `size`（字节）——与后端「实际解码字节数」同量纲。
 */
export function resumeFileError(file: { name: string; size: number }): string | null {
  if (resumeContentTypeFor(file.name) === null) return '简历仅支持 PDF 或 Word（.pdf / .doc / .docx）文件。'
  if (file.size <= 0) return '文件内容为空，请重新选择。'
  if (file.size > RESUME_FILE_MAX_BYTES) return '简历文件超过 5MB，请压缩后重试。'
  return null
}

/** 文件大小展示（KB 取整；上传前的确认行） */
export function resumeFileSizeText(size: number): string {
  if (size < 1024) return `${size} B`
  return `${Math.round(size / 1024)} KB`
}

// ── 档案与申请（两步网申的判据） ─────────────────────────────────────────────

/** 已有档案且有简历文件 → 第 1 步跳过重传（AE5 小程序侧） */
export function hasResumeFile(profile: ResumeProfileSummary | null): boolean {
  return profile !== null && profile.fileName !== null
}

/** 第 1 步必填校验（姓名 / 联系邮箱；邮箱是 R14 邮件保底通道收件地址，手机号建号必填） */
export function resumeProfileError(form: ResumeProfileForm): string | null {
  if (form.fullName.trim() === '') return '请填写姓名。'
  if (form.contactEmail.trim() === '') return '请填写联系邮箱（阶段结果会发到这个邮箱）。'
  return null
}

/** 技能标签候选（原型口径，多选；可自由组合，不做全选约束） */
export const RESUME_SKILL_OPTIONS = ['组织', '社群', '写作', '开发', '设计', '其他'] as const

/** 每周可投入小时数：正整数才提交（空/0/负数 → undefined，后端 weeklyHours 选填） */
export function weeklyHoursValue(input: string): number | undefined {
  const hours = Number.parseInt(input, 10)
  if (!Number.isFinite(hours) || hours <= 0) return undefined
  return hours
}

/** 某批次的已有申请（同批一份，后端 unique 约束 + volunteer_application_already_submitted） */
export function applicationForCohort(
  applications: VolunteerApplicationSummary[],
  cohortId: string
): VolunteerApplicationSummary | null {
  return applications.find((application) => application.cohortId === cohortId) ?? null
}

/** 本批已申请提示（AE2 前端侧；申请入口据此收起，改由「我的申请」展示段位） */
export const ALREADY_APPLIED_COPY = '本批次你已提交申请，可在下方查看当前段位。'

// ── 页面状态机（三态 + 登录分流） ────────────────────────────────────────────

/**
 * 招募流的页面状态。**读取失败与「无 open 批次」是不同桶**（plan U10 测试场景）：
 * 失败必须走可重试错误态，绝不能落到「当前无开放批次」空态——把服务故障说成
 * 「没有批次」会让申请人以为招募已停，且不给重试入口。
 *
 * 判定顺序即优先级：加载中 → 掉线重登 → 读取失败 → 未登录（登录引导，AE1）
 * → 无 open 批次（空态，AE12）→ 就绪。
 */
export type RecruitmentPageState = 'loading' | 'expired' | 'error' | 'anonymous' | 'empty' | 'ready'

export function recruitmentPageState(input: {
  loading: boolean
  expired: boolean
  error: string
  loggedIn: boolean
  cohort: RecruitmentCohort | null
}): RecruitmentPageState {
  if (input.loading) return 'loading'
  if (input.expired) return 'expired'
  if (input.error !== '') return 'error'
  if (!input.loggedIn) return 'anonymous'
  return input.cohort ? 'ready' : 'empty'
}
