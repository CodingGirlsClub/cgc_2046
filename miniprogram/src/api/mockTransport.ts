import type { RequestDocument } from 'graphql-request'

const workspace = {
  id: 'workspace-1',
  slug: 'beijing-cgc',
  name: '北京 CGC',
  joinPolicy: 'request',
  myRoleNames: ['owner'],
  myMembershipId: 'membership-1',
  canAccess: true,
  myAbilities: ['view_workspace', 'manage_members'],
  memberCount: 128
}

const records = [
  {
    id: 'event-1',
    workspaceId: workspace.id,
    title: 'Python 入门工作坊',
    researchRequirements: JSON.stringify({
      audience: '零基础学习者',
      duration: '2 小时',
      location: '北京 CGC 活动空间',
      tutor: '林老师',
      sections: ['环境准备', '语法基础', '动手练习']
    }),
    status: 'open',
    workflowRunId: null,
    enrollmentPolicy: 'request',
    capacity: 30,
    confirmedCount: 18,
    registrationDeadline: new Date(Date.now() + 72 * 3_600_000).toISOString()
  },
  {
    id: 'event-open',
    workspaceId: workspace.id,
    title: '周末开源分享会',
    researchRequirements: JSON.stringify({ audience: '所有成员', format: '线下分享' }),
    status: 'open',
    workflowRunId: null,
    enrollmentPolicy: 'open',
    capacity: 80,
    confirmedCount: 31,
    registrationDeadline: null
  }
]

const course = {
  id: 'course-1',
  workspaceId: workspace.id,
  title: '社区组织者成长课',
  researchRequirements: JSON.stringify({ audience: '社区志愿者', duration: '4 周' }),
  status: 'open',
  workflowRunId: null,
  enrollmentPolicy: 'invite_only',
  capacity: null,
  confirmedCount: 12,
  registrationDeadline: null
}

interface MockEnrollment {
  id: string
  workspaceId: string
  eventId: string | null
  courseId: string | null
  userId: string
  status: string
  submissionPayload: string
  approvalDeadline: string | null
  rejectionReason: string | null
  approvedAt: string | null
  expiredAt: string | null
  cancelledAt: string | null
}

let loggedIn = false
let enrollment: MockEnrollment | null = null

function variablesRecord(variables: object): Record<string, unknown> {
  return variables as Record<string, unknown>
}

function responseFor(document: string, variables: object): unknown {
  const values = variablesRecord(variables)

  if (document.includes('query Catalog')) {
    return { listEvents: { results: records }, listCourses: { results: [course] } }
  }
  if (document.includes('query EventDetail')) {
    return { getEvent: records.find(({ id }) => id === values.id) ?? null }
  }
  if (document.includes('query CourseDetail')) {
    return { getCourse: values.id === course.id ? course : null }
  }
  if (document.includes('query Session')) {
    return {
      me: loggedIn
        ? {
            id: 'user-1',
            email: 'cheng@example.com',
            displayName: '小程',
            memberNumber: 'CGC-000001',
            joinedAt: new Date().toISOString(),
            isPlatformAdmin: false
          }
        : null,
      meWorkspaces: loggedIn ? [workspace] : [],
      myPendingApprovals: loggedIn && enrollment?.status === 'pending'
        ? [{
            id: enrollment.id,
            kind: 'enrollment',
            workspaceId: enrollment.workspaceId,
            userId: enrollment.userId,
            eventId: enrollment.eventId,
            courseId: enrollment.courseId,
            status: enrollment.status,
            approvalDeadline: enrollment.approvalDeadline
          }]
        : []
    }
  }
  if (document.includes('query MyEnrollments')) {
    return { enrollments: { results: loggedIn && enrollment ? [enrollment] : [] } }
  }
  if (document.includes('mutation SignInWithPlatform')) {
    loggedIn = true
    return { signInWithPlatform: { id: 'user-1', email: 'cheng@example.com', isPlatformAdmin: false } }
  }
  if (document.includes('mutation SignOut')) {
    loggedIn = false
    return { signOut: true }
  }
  if (document.includes('mutation CreateEnrollment')) {
    const input = values.input as Record<string, unknown>
    const eventId = typeof input.eventId === 'string' ? input.eventId : null
    const courseId = typeof input.courseId === 'string' ? input.courseId : null
    const status = eventId === 'event-1' ? 'pending' : 'confirmed'
    enrollment = {
      id: 'enrollment-1',
      workspaceId: workspace.id,
      eventId,
      courseId,
      userId: 'user-1',
      status,
      submissionPayload: String(input.submissionPayload ?? '{}'),
      approvalDeadline: status === 'pending'
        ? new Date(Date.now() + 12 * 3_600_000).toISOString()
        : null,
      rejectionReason: null,
      approvedAt: null,
      expiredAt: null,
      cancelledAt: null
    }
    return { createEnrollment: { result: enrollment, errors: [] } }
  }
  if (document.includes('mutation ConfirmEnrollment')) {
    if (enrollment) {
      enrollment = { ...enrollment, status: 'confirmed', approvalDeadline: null, approvedAt: new Date().toISOString() }
    }
    return { confirmEnrollment: { result: enrollment, errors: [] } }
  }
  if (document.includes('mutation RejectEnrollment')) {
    const input = values.input as Record<string, unknown> | undefined
    if (enrollment) {
      enrollment = {
        ...enrollment,
        status: 'rejected',
        approvalDeadline: null,
        rejectionReason: typeof input?.rejectionReason === 'string' ? input.rejectionReason : null
      }
    }
    return { rejectEnrollment: { result: enrollment, errors: [] } }
  }
  if (document.includes('mutation ApproveJoinRequest')) {
    return { approveJoinRequest: { result: { id: values.id, status: 'approved', approvedAt: new Date().toISOString() }, errors: [] } }
  }
  if (document.includes('mutation RejectJoinRequest')) {
    return { rejectJoinRequest: { result: { id: values.id, status: 'rejected', rejectionReason: null }, errors: [] } }
  }
  if (document.includes('mutation GrantConsent')) {
    return { grantMiniProgramNotificationConsent: 1 }
  }
  if (document.includes('mutation GenerateMiniProgramCode')) {
    return {
      generateMiniProgramCode: {
        invitationId: 'invitation-1',
        platform: 'wechat',
        scene: `mock_scene_${values.workspaceId}`,
        codeBase64: '',
        expiresAt: new Date(Date.now() + 24 * 3_600_000).toISOString()
      }
    }
  }
  if (document.includes('mutation AdmitMemberByToken')) {
    return {
      admitMemberByToken: {
        id: 'invitation-1',
        workspaceId: workspace.id,
        workspaceName: workspace.name,
        status: 'accepted',
        acceptedAt: new Date().toISOString()
      }
    }
  }

  throw new Error(`E2E GraphQL mock 未处理该 operation：${document.slice(0, 80)}`)
}

export function mockGraphQLRequest<TData>(document: RequestDocument, variables: object): TData {
  return responseFor(String(document), variables) as TData
}
