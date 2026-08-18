/** Internal type. DO NOT USE DIRECTLY. */
type Exact<T extends { [key: string]: unknown }> = { [K in keyof T]: T[K] };
/** Internal type. DO NOT USE DIRECTLY. */
export type Incremental<T> = T | { [P in keyof T]?: P extends ' $fragmentName' | '__typename' ? T[P] : never };
export type CreateEnrollmentInput = {
  approvalDeadline?: string | null | undefined;
  courseId?: string | number | null | undefined;
  eventId?: string | number | null | undefined;
  inviteCode?: string | null | undefined;
  submissionPayload?: string | null | undefined;
  /** 价格档位 ID（收费活动报名时必填） */
  tierId?: string | null | undefined;
  userId: string | number;
  workflowRunId?: string | number | null | undefined;
};

export type CreateOrderInput = {
  /** 目标报名（须为本人 payment_pending 报名） */
  enrollmentId: string | number;
  /** 支付渠道 */
  provider: string;
};

export type RejectEnrollmentInput = {
  rejectionReason?: string | null | undefined;
};

export type RejectJoinRequestInput = {
  /** 拒绝原因 */
  rejectionReason?: string | null | undefined;
};

export type CatalogQueryVariables = Exact<{
  first?: number | null | undefined;
}>;


export type CatalogQuery = { listEvents: { results: Array<{ id: string, workspaceId: string, title: string, researchRequirements: string | null, status: string, workflowRunId: string | null, enrollmentPolicy: string, capacity: number | null, confirmedCount: number, registrationDeadline: string | null, pricingEnabled: boolean, availablePriceTiers: Array<string> | null }> | null } | null, listCourses: { results: Array<{ id: string, workspaceId: string, title: string, researchRequirements: string | null, status: string, workflowRunId: string | null, enrollmentPolicy: string, capacity: number | null, confirmedCount: number, registrationDeadline: string | null, pricingEnabled: boolean, availablePriceTiers: Array<string> | null }> | null } | null };

export type EventDetailQueryVariables = Exact<{
  id: string | number;
}>;


export type EventDetailQuery = { getEvent: { id: string, workspaceId: string, title: string, researchRequirements: string | null, status: string, workflowRunId: string | null, enrollmentPolicy: string, capacity: number | null, confirmedCount: number, registrationDeadline: string | null, pricingEnabled: boolean, availablePriceTiers: Array<string> | null } | null };

export type CourseDetailQueryVariables = Exact<{
  id: string | number;
}>;


export type CourseDetailQuery = { getCourse: { id: string, workspaceId: string, title: string, researchRequirements: string | null, status: string, workflowRunId: string | null, enrollmentPolicy: string, capacity: number | null, confirmedCount: number, registrationDeadline: string | null, pricingEnabled: boolean, availablePriceTiers: Array<string> | null } | null };

export type SessionQueryVariables = Exact<{ [key: string]: never; }>;


export type SessionQuery = { me: { id: string, email: string | null, displayName: string | null, memberNumber: string | null, joinedAt: string | null, isPlatformAdmin: boolean } | null, meWorkspaces: Array<{ id: string, slug: string, name: string, joinPolicy: string, myRoleNames: Array<string> | null, myMembershipId: string | null, canAccess: boolean | null, myAbilities: Array<string> | null, memberCount: number | null }>, myPendingApprovals: Array<{ id: string, kind: string, workspaceId: string, userId: string, eventId: string | null, courseId: string | null, status: string, approvalDeadline: string | null }> };

export type MyEnrollmentsQueryVariables = Exact<{
  userId: string | number;
  first?: number | null | undefined;
}>;


export type MyEnrollmentsQuery = { enrollments: { results: Array<{ id: string, workspaceId: string, eventId: string | null, courseId: string | null, userId: string, status: string, targetTitle: string | null, approvalDeadline: string | null, rejectionReason: string | null, approvedAt: string | null, expiredAt: string | null, cancelledAt: string | null }> | null } | null };

export type SignInWithPlatformMutationVariables = Exact<{
  platform: string;
  code: string;
  phoneCode?: string | null | undefined;
  encryptedData?: string | null | undefined;
  iv?: string | null | undefined;
}>;


export type SignInWithPlatformMutation = { signInWithPlatform: { id: string, email: string | null, isPlatformAdmin: boolean } | null };

export type SignOutMutationVariables = Exact<{ [key: string]: never; }>;


export type SignOutMutation = { signOut: string | null };

export type CreateEnrollmentMutationVariables = Exact<{
  input: CreateEnrollmentInput;
}>;


export type CreateEnrollmentMutation = { createEnrollment: { result: { id: string, workspaceId: string, eventId: string | null, courseId: string | null, userId: string, status: string, approvalDeadline: string | null } | null, errors: Array<{ message: string | null, code: string | null, fields: Array<string> | null }> } };

export type CancelEnrollmentMutationVariables = Exact<{
  id: string | number;
}>;


export type CancelEnrollmentMutation = { cancelEnrollment: { result: { id: string, workspaceId: string, eventId: string | null, courseId: string | null, userId: string, status: string, approvalDeadline: string | null, rejectionReason: string | null, cancelledAt: string | null } | null, errors: Array<{ message: string | null, code: string | null }> } };

export type ConfirmEnrollmentMutationVariables = Exact<{
  id: string | number;
}>;


export type ConfirmEnrollmentMutation = { confirmEnrollment: { result: { id: string, status: string, approvedAt: string | null } | null, errors: Array<{ message: string | null, fields: Array<string> | null }> } };

export type RejectEnrollmentMutationVariables = Exact<{
  id: string | number;
  input?: RejectEnrollmentInput | null | undefined;
}>;


export type RejectEnrollmentMutation = { rejectEnrollment: { result: { id: string, status: string, rejectionReason: string | null } | null, errors: Array<{ message: string | null, fields: Array<string> | null }> } };

export type ApproveJoinRequestMutationVariables = Exact<{
  id: string | number;
}>;


export type ApproveJoinRequestMutation = { approveJoinRequest: { result: { id: string, status: string, approvedAt: string | null } | null, errors: Array<{ message: string | null, fields: Array<string> | null }> } };

export type RejectJoinRequestMutationVariables = Exact<{
  id: string | number;
  input?: RejectJoinRequestInput | null | undefined;
}>;


export type RejectJoinRequestMutation = { rejectJoinRequest: { result: { id: string, status: string, rejectionReason: string | null } | null, errors: Array<{ message: string | null, fields: Array<string> | null }> } };

export type GrantConsentMutationVariables = Exact<{
  platform: string;
  templateKey: string;
}>;


export type GrantConsentMutation = { grantMiniProgramNotificationConsent: number | null };

export type GenerateMiniProgramCodeMutationVariables = Exact<{
  workspaceId: string | number;
  platform: string;
}>;


export type GenerateMiniProgramCodeMutation = { generateMiniProgramCode: { invitationId: string, platform: string, scene: string, codeBase64: string, expiresAt: string } | null };

export type AdmitMemberByTokenMutationVariables = Exact<{
  scene: string;
}>;


export type AdmitMemberByTokenMutation = { admitMemberByToken: { id: string, workspaceId: string, workspaceName: string | null, status: string, acceptedAt: string | null } | null };

export type CreateOrderMutationVariables = Exact<{
  input: CreateOrderInput;
}>;


export type CreateOrderMutation = { createOrder: { result: { id: string, enrollmentId: string, provider: string, outTradeNo: string, amountCents: number, status: string, expireAt: string } | null, errors: Array<{ message: string | null, code: string | null }>, metadata: { credential: string | null } | null } };

export type OrderStatusQueryVariables = Exact<{
  id: string | number;
}>;


export type OrderStatusQuery = { orderStatus: { id: string, status: string, transactionId: string | null, amountCents: number, expireAt: string } | null };

export type MyOrdersQueryVariables = Exact<{ [key: string]: never; }>;


export type MyOrdersQuery = { myOrders: { results: Array<{ id: string, enrollmentId: string, provider: string, status: string, amountCents: number, expireAt: string }> | null } | null };
