export type ContentKind = 'event' | 'course'
export type EnrollmentStatus = 'pending' | 'confirmed' | 'rejected' | 'expired' | 'cancelled'
export type SubscriptionScenario = 'approval_result' | 'approval_reminder' | 'event_reminder'

export interface SchemaField {
  key: string
  label: string
  value: string
}

export interface CatalogItem {
  id: string
  kind: ContentKind
  workspaceId: string
  workspaceName: string
  title: string
  enrollmentPolicy: 'open' | 'request' | 'invite_only'
  capacity: number | null
  confirmedCount: number
  registrationDeadline: string | null
  schemaFields: SchemaField[]
}

export interface UserSummary {
  id: string
  displayName: string
  email: string | null
  memberNumber: string | null
}

export interface WorkspaceSummary {
  id: string
  slug: string
  name: string
  roleNames: string[]
  abilities: string[]
  memberCount: number | null
}

export interface ApprovalSummary {
  id: string
  kind: string
  workspaceId: string
  workspaceName: string
  targetId: string | null
  status: string
  approvalDeadline: string | null
}

export interface SessionSnapshot {
  user: UserSummary | null
  workspaces: WorkspaceSummary[]
  approvals: ApprovalSummary[]
}

export interface EnrollmentSummary {
  id: string
  workspaceId: string
  targetId: string
  kind: ContentKind
  title: string
  status: EnrollmentStatus
  approvalDeadline: string | null
  rejectionReason: string | null
}

export interface EnrollmentForm {
  target: CatalogItem
  name: string
  email: string
  reason: string
  inviteCode?: string
}

export interface NotificationItem {
  id: string
  title: string
  body: string
  createdAt: string
  read: boolean
}

export interface MiniProgramCode {
  invitationId: string
  platform: string
  scene: string
  codeBase64: string
  expiresAt: string
}

export interface AdmitResult {
  workspaceId: string
  workspaceName: string
}

export interface PlatformPhonePayload {
  loginCode?: string
  code?: string
  encryptedData?: string
  iv?: string
}

export interface MiniProgramApi {
  getCatalog(): Promise<CatalogItem[]>
  getContent(kind: ContentKind, id: string): Promise<CatalogItem>
  getSession(): Promise<SessionSnapshot>
  signIn(payload: PlatformPhonePayload): Promise<SessionSnapshot>
  signOut(): Promise<void>
  getEnrollments(): Promise<EnrollmentSummary[]>
  createEnrollment(form: EnrollmentForm): Promise<EnrollmentSummary>
  approvePending(approval: ApprovalSummary): Promise<void>
  rejectPending(approval: ApprovalSummary, reason?: string): Promise<void>
  grantConsent(scenario: SubscriptionScenario): Promise<number>
  generateMiniProgramCode(workspaceId: string): Promise<MiniProgramCode>
  admitMember(scene: string): Promise<AdmitResult>
  getNotifications(): Promise<NotificationItem[]>
}
