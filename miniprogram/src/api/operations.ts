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
// #355 P2-10：发现页搜索服务端化。keyword 非空时改用本文档，filter 变量由
// catalogSearchVariables 构造（status/visibility 钉死 + title ilike `%kw%`）；
// 拆成两份文档是因为 AshGraphql 对 filter 内的 null 子字段容忍度未验证，
// 空关键词继续走上方无变量的 CatalogQueryDocument。
export const CatalogSearchQueryDocument = /* GraphQL */ `
  query CatalogSearch($first: Int, $eventFilter: EventFilterInput, $courseFilter: CourseFilterInput) {
    listEvents(first: $first, filter: $eventFilter) {
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
    listCourses(first: $first, filter: $courseFilter) {
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
    getEvent(id: $id, filter: { status: { in: ["open", "closed", "cancelled"] }, visibility: { eq: "public" } }) {
      id
      title
      status
      enrollmentPolicy
      registrationDeadline
      pricingEnabled
      availablePriceTiers
      depositEnabled
      depositAmountCents
      #510：min_age 非空的场报名须勾选年龄确认（公开字段白名单内，匿名可读）
      minAge
      startsAt
      endsAt
      venue
      enrollmentBadge
      qualificationBadge
      shortBy
      # 阶段1：挂载 Initiative 的活动带出隶属 id（公开字段白名单内，匿名可读）；
      # 详情页据此渲染「所属倡导活动」回链
      initiativeId
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
        insertedAt
        checkInCode
        paymentMode
        startsAt
        venue
        registrationDeadline
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
        insertedAt
        checkInCode
        paymentMode
        startsAt
        venue
        registrationDeadline
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
        insertedAt
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
        orderKind
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
      orderKind
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
        orderKind
      }
    }
  }
`

export const PublicInitiativesQueryDocument = /* GraphQL */ `
  query PublicInitiatives {
    publicInitiatives { id name slug hashtag status description windowStartsAt windowEndsAt }
  }
`

// #508-A：主理人核销（Admission.Attendance 手写 mutation，成功判据 = enrollmentId
// 非空；业务失败进 errors 带领域 code——码无效/已核销/押金已结算/无权限）
export const CheckInEnrollmentMutationDocument = /* GraphQL */ `
  mutation CheckInEnrollment($eventId: ID!, $code: String!, $method: String!) {
    checkInEnrollment(eventId: $eventId, code: $code, method: $method) {
      enrollmentId
      checkedInAt
      method
      depositRefund
      errors {
        message
        code
      }
    }
  }
`

// #508-A：核销入口的成员面探测——workspace_id 是 Event 的 field_policy 收窄字段
// （仅本 workspace 成员/平台管理员可选中）：匿名/非成员请求整体 forbidden_field，
// 调用方按「非运营角色」隐藏入口。成员可读 closed（现场核销时活动通常已截止）。
export const EventModerationScopeQueryDocument = /* GraphQL */ `
  query EventModerationScope($id: ID!) {
    getEvent(id: $id) {
      id
      workspaceId
    }
  }
`

// #558 后续：非管理角色主理人的入口判定——主理人或 Owner/Admin 可读（后端
// Moderators.list 走 can_moderate?）；普通成员 forbidden，调用方按 false 收敛
export const EventModeratorsQueryDocument = /* GraphQL */ `
  query EventModerators($workspaceId: ID!, $eventId: ID!) {
    eventModerators(workspaceId: $workspaceId, eventId: $eventId) {
      userId
    }
  }
`

export const PublicInitiativeQueryDocument = /* GraphQL */ `
  query PublicInitiative($slug: String!) {
    publicInitiative(slug: $slug) {
      id name slug hashtag description status windowStartsAt windowEndsAt
      cityCount eventCount confirmedCount qualifiedEventCount
      cities {
        city
        events { id slug title status startsAt endsAt registrationDeadline venue archived qualificationBadge shortBy paymentMode deposit { enabled amountCents refundableOnCheckIn } minAge priceRangeMinCents }
      }
    }
  }
`

// ── 闪念间「我的」（U9/R28）──────────────────────────────────────────────
// 双入口：token（首程链接身份，KTD2）优先，缺省走登录会话腿。投影含
// archives（长廊/场次页读面，R12/R28 批次二）：
// city（R34 城市钉）：非空时名册/行动板按城市过滤；cities 供钉条渲染（全量）。

export const FlashbackCapsuleQueryDocument = /* GraphQL */ `
  query FlashbackCapsule($city: String, $token: String) {
    flashbackCapsule(city: $city, token: $token) {
      me {
        id
        fullName
        surname
        city
        occupationThen
        participation
        appliedAt
        quoteLevel
        quote
        quoteQuestionKey
        quoteSpan {
          start
          len
        }
        quoteStats {
          likeCount
        }
        today {
          nowStatus
          want
          say
          sentToWallAt
        }
        answers {
          id
          questionKey
          rawText
          fogSpans {
            start
            len
          }
          text
        }
      }
      archives {
        key
        name
        city
        occurredOn
        appliedCount
        attendedCount
        label
        isMine
        roster {
          id
          surnameMasked
          fullName
          appliedAt
          city
          occupationThen
          sentToWallAt
          today {
            nowStatus
            want
            say
          }
          answers {
            questionKey
            segments {
              text
              fog
              len
            }
          }
        }
      }
      cities
    }
  }
`

// 公开统计层（R32 路人态长廊数据源）：场次档案 + 已回来人数，无个人内容
export const FlashbackPublicStatsQueryDocument = /* GraphQL */ `
  query FlashbackPublicStats {
    flashbackPublicStats {
      archives {
        key
        name
        city
        occurredOn
        appliedCount
        attendedCount
        label
      }
      returnedCount
      sentCount
    }
  }
`

export const FlashbackSubmitTodayMutationDocument = /* GraphQL */ `
  mutation FlashbackSubmitToday($input: FlashbackTodayInput!, $token: String) {
    flashbackSubmitToday(input: $input, token: $token) {
      today {
        nowStatus
        want
        need
        say
      }
    }
  }
`

export const FlashbackSetQuoteLicenseMutationDocument = /* GraphQL */ `
  mutation FlashbackSetQuoteLicense(
    $level: String!
    $questionKey: String
    $chosenQuoteSpan: FlashbackFogSpanInput
    $token: String
  ) {
    flashbackSetQuoteLicense(
      level: $level
      questionKey: $questionKey
      chosenQuoteSpan: $chosenQuoteSpan
      token: $token
    ) {
      level
      questionKey
      chosenQuoteSpan {
        start
        len
      }
    }
  }
`

// 首程 token 面（R1/R4-R9；mp 旅程用）：enter 分流 + 显影事件 + 寄出上墙。
export const FlashbackEnterMutationDocument = /* GraphQL */ `
  mutation FlashbackEnter($token: String!) {
    flashbackEnter(token: $token) {
      line
      profile {
        fullName
        surname
        city
        occupationThen
        participation
        role
        appliedAt
        archive {
          key
          name
          city
          occurredOn
        }
        answers {
          id
          questionKey
          rawText
          fogSpans {
            start
            len
          }
        }
      }
      progress {
        quoteLevel
        maskedPhone
        maskedEmail
        today {
          nowStatus
          want
          say
          sentToWallAt
        }
      }
    }
  }
`

export const FlashbackMarkRevealedMutationDocument = /* GraphQL */ `
  mutation FlashbackMarkRevealed($token: String!) {
    flashbackMarkRevealed(token: $token) {
      recorded
    }
  }
`

export const FlashbackSendToWallMutationDocument = /* GraphQL */ `
  mutation FlashbackSendToWall($token: String!) {
    flashbackSendToWall(token: $token) {
      sentToWallAt
    }
  }
`

// R27 小程序路径「微信一键收好」：带 token 收该链接档案；不带则按登录手机/邮箱自动匹配。
export const FlashbackClaimMutationDocument = /* GraphQL */ `
  mutation FlashbackClaim($token: String) {
    flashbackClaim(token: $token) {
      bound
      boundCount
      maskedPhone
    }
  }
`

export const FlashbackAdjustFogMutationDocument = /* GraphQL */ `
  mutation FlashbackAdjustFog($answerId: ID!, $spans: [FlashbackFogSpanInput!]!) {
    flashbackAdjustFog(answerId: $answerId, spans: $spans) {
      answerId
      fogSpans {
        start
        len
      }
    }
  }
`
