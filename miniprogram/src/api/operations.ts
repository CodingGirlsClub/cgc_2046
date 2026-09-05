// 公开发现面查询（F2/D2）：字段 = 匿名白名单（与 web PUBLIC_LIST_* 同源），
// 不含 workspaceId/curriculumRequirements/workflowRunId/capacity/confirmedCount
// 等成员可见字段——匿名/跨工作台成员请求受保护字段会 forbidden_field 抛错。
// filter 同时钉死 status=open 且 visibility=public，workspace_only 条目不混入。
export const CatalogQueryDocument = /* GraphQL */ `
  query Catalog($first: Int) {
    listEvents(first: $first, filter: { status: { eq: "open" }, visibility: { eq: "public" } }) {
      results {
        id
        title
        status
        enrollmentPolicy
        registrationDeadline
        pricingEnabled
        availablePriceTiers
        startsAt
        endsAt
        venue
        enrollmentBadge
      }
    }
    listCourses(first: $first, filter: { status: { eq: "open" }, visibility: { eq: "public" } }) {
      results {
        id
        title
        status
        enrollmentPolicy
        registrationDeadline
        pricingEnabled
        availablePriceTiers
        startsAt
        endsAt
        enrollmentBadge
      }
    }
  }
`

export const EventDetailQueryDocument = /* GraphQL */ `
  query EventDetail($id: ID!) {
    getEvent(id: $id, filter: { status: { eq: "open" }, visibility: { eq: "public" } }) {
      id
      title
      status
      enrollmentPolicy
      registrationDeadline
      pricingEnabled
      availablePriceTiers
      startsAt
      endsAt
      venue
      enrollmentBadge
    }
    # #355 P1-3：同文档带出「我的报名」（匿名/未报名 → null）
    myEnrollment(kind: "event", offeringId: $id) {
      id
      status
      approvalDeadline
    }
  }
`

export const CourseDetailQueryDocument = /* GraphQL */ `
  query CourseDetail($id: ID!) {
    getCourse(id: $id, filter: { status: { eq: "open" }, visibility: { eq: "public" } }) {
      id
      title
      status
      enrollmentPolicy
      registrationDeadline
      pricingEnabled
      availablePriceTiers
      startsAt
      endsAt
      enrollmentBadge
    }
    # #355 P1-3：同文档带出「我的报名」（匿名/未报名 → null）
    myEnrollment(kind: "course", offeringId: $id) {
      id
      status
      approvalDeadline
    }
  }
`

export const SessionQueryDocument = /* GraphQL */ `
  query Session {
    me {
      id
      email
      displayName
      memberNumber
      joinedAt
      isPlatformAdmin
    }
    meWorkspaces {
      id
      slug
      name
      joinPolicy
      myRoleNames
      myMembershipId
      canAccess
      myAbilities
      memberCount
    }
    myPendingApprovals {
      id
      kind
      workspaceId
      userId
      eventId
      courseId
      status
      approvalDeadline
      requesterName
      contextTitle
      tierName
      amount
    }
  }
`

export const MyEnrollmentsQueryDocument = /* GraphQL */ `
  query MyEnrollments($userId: ID!, $first: Int) {
    enrollments(first: $first, filter: { userId: { eq: $userId } }) {
      results {
        id
        workspaceId
        eventId
        courseId
        userId
        status
        targetTitle
        approvalDeadline
        rejectionReason
        approvedAt
        expiredAt
        cancelledAt
      }
    }
  }
`

// #355 P1-4：结果页按 id 回查单条报名（服务端过滤；enrollments read policy
// 本人锚定，未登录 → forbidden 由调用方降级处理）
export const EnrollmentQueryDocument = /* GraphQL */ `
  query Enrollment($id: ID!) {
    enrollments(first: 1, filter: { id: { eq: $id } }) {
      results {
        id
        workspaceId
        eventId
        courseId
        userId
        status
        targetTitle
        approvalDeadline
        rejectionReason
        approvedAt
        expiredAt
        cancelledAt
      }
    }
  }
`

export const SignInWithPlatformMutationDocument = /* GraphQL */ `
  mutation SignInWithPlatform(
    $platform: String!
    $code: String!
    $phoneCode: String
    $encryptedData: String
    $iv: String
  ) {
    signInWithPlatform(
      platform: $platform
      code: $code
      phoneCode: $phoneCode
      encryptedData: $encryptedData
      iv: $iv
    ) {
      id
      email
      isPlatformAdmin
    }
  }
`

export const SignOutMutationDocument = /* GraphQL */ `
  mutation SignOut {
    signOut
  }
`

export const CreateEnrollmentMutationDocument = /* GraphQL */ `
  mutation CreateEnrollment($input: CreateEnrollmentInput!) {
    createEnrollment(input: $input) {
      result {
        id
        workspaceId
        eventId
        courseId
        userId
        status
        approvalDeadline
      }
      errors {
        message
        code
        fields
      }
    }
  }
`

export const CancelEnrollmentMutationDocument = /* GraphQL */ `
  mutation CancelEnrollment($id: ID!) {
    cancelEnrollment(id: $id) {
      result {
        id
        workspaceId
        eventId
        courseId
        userId
        status
        approvalDeadline
        rejectionReason
        cancelledAt
      }
      errors {
        message
        code
      }
    }
  }
`

export const ConfirmEnrollmentMutationDocument = /* GraphQL */ `
  mutation ConfirmEnrollment($id: ID!) {
    confirmEnrollment(id: $id) {
      result { id status approvedAt }
      errors { message fields }
    }
  }
`

export const RejectEnrollmentMutationDocument = /* GraphQL */ `
  mutation RejectEnrollment($id: ID!, $input: RejectEnrollmentInput) {
    rejectEnrollment(id: $id, input: $input) {
      result { id status rejectionReason }
      errors { message fields }
    }
  }
`

export const ApproveJoinRequestMutationDocument = /* GraphQL */ `
  mutation ApproveJoinRequest($id: ID!) {
    approveJoinRequest(id: $id) {
      result { id status approvedAt }
      errors { message fields }
    }
  }
`

export const RejectJoinRequestMutationDocument = /* GraphQL */ `
  mutation RejectJoinRequest($id: ID!, $input: RejectJoinRequestInput) {
    rejectJoinRequest(id: $id, input: $input) {
      result { id status rejectionReason }
      errors { message fields }
    }
  }
`

export const GrantConsentMutationDocument = /* GraphQL */ `
  mutation GrantConsent($platform: String!, $templateKey: String!) {
    grantMiniProgramNotificationConsent(platform: $platform, templateKey: $templateKey)
  }
`

export const GenerateMiniProgramCodeMutationDocument = /* GraphQL */ `
  mutation GenerateMiniProgramCode($workspaceId: ID!, $platform: String!) {
    generateMiniProgramCode(workspaceId: $workspaceId, platform: $platform) {
      invitationId
      platform
      scene
      codeBase64
      expiresAt
    }
  }
`

export const AdmitMemberByTokenMutationDocument = /* GraphQL */ `
  mutation AdmitMemberByToken($scene: String!) {
    admitMemberByToken(scene: $scene) {
      id
      workspaceId
      workspaceName
      status
      acceptedAt
    }
  }
`

export const CreateOrderMutationDocument = /* GraphQL */ `
  mutation CreateOrder($input: CreateOrderInput!) {
    createOrder(input: $input) {
      result {
        id
        enrollmentId
        provider
        outTradeNo
        amountCents
        status
        expireAt
      }
      errors {
        message
        code
      }
      metadata {
        credential
      }
    }
  }
`

export const OrderStatusQueryDocument = /* GraphQL */ `
  query OrderStatus($id: ID!) {
    orderStatus(id: $id) {
      id
      status
      transactionId
      amountCents
      expireAt
    }
  }
`

export const MyOrdersQueryDocument = /* GraphQL */ `
  query MyOrders {
    myOrders {
      results {
        id
        enrollmentId
        provider
        status
        amountCents
        expireAt
      }
    }
  }
`
