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
      # 活动介绍（公开展示文案；仅详情查询携带，列表不选）
      description
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
      #538：公开主理人投影（[JsonString!]，每行 {display_name, member_number}；
      # assignedAt 升序，详情页渲染「本场主理人」行——三端同口径）
      publicModerators
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
      # 课程介绍（公开展示文案；仅详情查询携带，列表不选）
      description
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
        depositAmountCents
        startsAt
        venue
        registrationDeadline
      }
    }
  }
`

// #930 回访静默登录：只用平台登录凭证 code；本平台未绑定身份 → platform_identity_not_found
export const SignInWithPlatformIdentityMutationDocument = /* GraphQL */ `
  mutation SignInWithPlatformIdentity($platform: String!, $code: String!) {
    signInWithPlatformIdentity(platform: $platform, code: $code) {
      id
      email
      isPlatformAdmin
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

// #933 相册：已登录即可读（未登录 → flashback_auth_required）；场次选择集与胶囊逐字一致
export const FlashbackArchivesQueryDocument = /* GraphQL */ `
  query FlashbackArchives($city: String) {
    flashbackArchives(city: $city) {
      cities
      archives {
        key
        name
        city
        occurredOn
        appliedCount
        attendedCount
        label
        isMine
        piles {
          city
          count
          returned
        }
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
    }
  }
`

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
        quoteSpans {
          questionKey
          start
          len
        }
        quoteStats {
          likeCount
        }
        today {
          nowStatus
          want
          need
          say
          fogSpans
          sentToWallAt
        }
        cardSharing {
          enabled
          shareId
          preview {
            displayName
            city
            appliedAt
            occurredOn
            answers {
              questionKey
              segments {
                text
                fog
                len
              }
            }
            today {
              questionKey
              segments {
                text
                fog
                len
              }
            }
          }
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
        piles {
          city
          count
          returned
        }
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
      futureEvents {
        initiativeSlug
        initiativeName
        initiativeStartsAt
        events {
          id
          slug
          title
          city
          startsAt
          capacity
          confirmedCount
          registrationDeadline
        }
      }
      publicWishes {
        id
        content
        city
        wisherMasked
        endorsementCount
        endorsedByMe
        mine
        comments {
          id
          content
          commenterMasked
          insertedAt
        }
        latestEcho {
          id
          content
          status
          publishedAt
          correctedAt
        }
        echoCount
        echoes {
          id
          content
          status
          publishedAt
          correctedAt
        }
        insertedAt
      }
      myPrivateWishes {
        id
        content
        city
        wisherMasked
        endorsementCount
        endorsedByMe
        mine
        insertedAt
      }
      myWishQuotaRemaining
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
    $chosenQuoteSpans: [FlashbackQuoteSpanInput!]
    $token: String
  ) {
    flashbackSetQuoteLicense(
      level: $level
      chosenQuoteSpans: $chosenQuoteSpans
      token: $token
    ) {
      level
      chosenQuoteSpans {
        questionKey
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

// #931 起双入口：token 省略时按登录账号绑定档案（认领作废 token 后的唯一入口）
export const FlashbackSendToWallMutationDocument = /* GraphQL */ `
  mutation FlashbackSendToWall($token: String) {
    flashbackSendToWall(token: $token) {
      sentToWallAt
    }
  }
`

// 撤下（#931，双入口）：sent_to_wall_at 清回 nil，名册回到结构化卡
export const FlashbackRetractMutationDocument = /* GraphQL */ `
  mutation FlashbackRetract($token: String) {
    flashbackRetract(token: $token) {
      retracted
      sentToWallAt
    }
  }
`

// 删除档案（#931，与 web delete-account 同两步）：先取摘要，再以 DELETE 确认
export const FlashbackDeletePreviewQueryDocument = /* GraphQL */ `
  query FlashbackDeletePreview($token: String) {
    flashbackDeletePreview(token: $token) {
      personId
      fullName
      sentToWallAt
      endorsementCount
      alreadyDeleted
    }
  }
`

// #932 小程序内找回：发起同 web（命中与未命中同形）；验证绑定到当前登录账号（不另建账号）
export const FlashbackRecoverMutationDocument = /* GraphQL */ `
  mutation FlashbackRecover($identifier: String!) {
    flashbackRecover(identifier: $identifier) {
      dispatched
    }
  }
`

export const FlashbackRecoverVerifyForAccountMutationDocument = /* GraphQL */ `
  mutation FlashbackRecoverVerifyForAccount($identifier: String!, $code: String!) {
    flashbackRecoverVerifyForAccount(identifier: $identifier, code: $code) {
      bound
      cards {
        surnameMasked
        eventName
        city
      }
    }
  }
`

// 邮箱找回·贴链接：找回邮件里的入口链接原样上送（服务端取其中的 fb_ token），同邮箱档案绑到当前账号
export const FlashbackRecoverClaimForAccountMutationDocument = /* GraphQL */ `
  mutation FlashbackRecoverClaimForAccount($link: String!) {
    flashbackRecoverClaimForAccount(link: $link) {
      bound
      cards {
        surnameMasked
      }
    }
  }
`

export const FlashbackDeleteMutationDocument = /* GraphQL */ `
  mutation FlashbackDelete($token: String, $confirm: String!) {
    flashbackDelete(token: $token, confirm: $confirm) {
      deleted
      deletedAt
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
  mutation FlashbackAdjustFog($token: String, $answerId: ID!, $spans: [FlashbackFogSpanInput!]!) {
    flashbackAdjustFog(token: $token, answerId: $answerId, spans: $spans) {
      answerId
      fogSpans {
        start
        len
      }
    }
  }
`
// 今天的你句级雾面(field ∈ now/want/need/say;双入口 token)
export const FlashbackAdjustTodayFogMutationDocument = /* GraphQL */ `
  mutation FlashbackAdjustTodayFog($token: String, $field: String!, $spans: [FlashbackFogSpanInput!]!) {
    flashbackAdjustTodayFog(token: $token, field: $field, spans: $spans) {
      field
      fogSpans
    }
  }
`

// U4 愿望写操作(双入口 token:独立 token 或登录会话)；
// wish2 U8/U10 扩参：署名快照/期望地归一/公开树授权；返回 id+status 三态
export const FlashbackCreateWishMutationDocument = /* GraphQL */ `
  mutation FlashbackCreateWish(
    $token: String
    $requestId: ID
    $content: String!
    $visibility: String!
    $signatureChoice: String
    $expectedCity: String
    $publicListingConsent: Boolean
  ) {
    flashbackCreateWish(
      token: $token
      requestId: $requestId
      content: $content
      visibility: $visibility
      signatureChoice: $signatureChoice
      expectedCity: $expectedCity
      publicListingConsent: $publicListingConsent
    ) {
      id
      endorsementCount
      endorsedByMe
      status
    }
  }
`

// wish2 U10（KTD11）：期望地候选名单真源（与 web FLASHBACK_CITIES 同一服务端读面）
export const FlashbackCitiesQueryDocument = /* GraphQL */ `
  query FlashbackCities {
    flashbackCities {
      name
      fullName
      pinyin
      lngLat
    }
  }
`

// wish2 U6/KTD3：附议改登录版（旧 token 匿名腿下线——未登录由登录页承接）
export const FlashbackEndorseWishMutationDocument = /* GraphQL */ `
  mutation FlashbackEndorseWish(
    $wishId: ID!
    $contributionTypes: [String!]
    $message: String
    $notify: Boolean
  ) {
    flashbackEndorseWish(
      wishId: $wishId
      contributionTypes: $contributionTypes
      message: $message
      notify: $notify
    ) {
      endorsementCount
      endorsedByMe
    }
  }
`

// wish2 U6/KTD3：取消附议（登录）
export const FlashbackCancelEndorseWishMutationDocument = /* GraphQL */ `
  mutation FlashbackCancelEndorseWish($wishId: ID!) {
    flashbackCancelEndorseWish(wishId: $wishId) {
      endorsementCount
      endorsedByMe
    }
  }
`

// wish2 U6/KTD2：期待/取消期待（expected 双向；登录强制 u: 键，匿名 a: 设备键）
export const FlashbackExpectWishMutationDocument = /* GraphQL */ `
  mutation FlashbackExpectWish($wishId: ID!, $expected: Boolean!, $anonVoterKey: String) {
    flashbackExpectWish(wishId: $wishId, expected: $expected, anonVoterKey: $anonVoterKey) {
      expectationCount
      expectedByMe
    }
  }
`

// wish2 U6/KTD5：举报（匿名可报；预设理由 + 补充 ≤200）
export const FlashbackReportWishMutationDocument = /* GraphQL */ `
  mutation FlashbackReportWish(
    $wishId: ID!
    $reasonType: String!
    $reasonFree: String
    $anonVoterKey: String
  ) {
    flashbackReportWish(
      wishId: $wishId
      reasonType: $reasonType
      reasonFree: $reasonFree
      anonVoterKey: $anonVoterKey
    ) {
      reportId
      status
    }
  }
`

// wish2 U6/KTD10：viewer 公开树读面（listed 四条件 + 加权随机排序）
export const FlashbackPublicWishesQueryDocument = /* GraphQL */ `
  query FlashbackPublicWishes($city: String, $withEchoes: Boolean, $seed: String, $offset: Int, $limit: Int, $voterKey: String) {
    flashbackPublicWishes(
      city: $city
      withEchoes: $withEchoes
      seed: $seed
      offset: $offset
      limit: $limit
      voterKey: $voterKey
    ) {
      id
      content
      city
      signature
      expectationCount
      endorsementCount
      contributionDistribution
      expectedByViewer
      endorsedByViewer
      latestEcho {
        id
        content
        status
        publishedAt
        correctedAt
      }
      echoCount
      echoes {
        id
        content
        status
        publishedAt
        correctedAt
      }
      listedAt
      insertedAt
    }
  }
`

export const FlashbackAddWishCommentMutationDocument = /* GraphQL */ `
  mutation FlashbackAddWishComment($token: String, $wishId: ID!, $content: String!) {
    flashbackAddWishComment(token: $token, wishId: $wishId, content: $content) {
      endorsementCount
      endorsedByMe
    }
  }
`

export const FlashbackDeleteWishMutationDocument = /* GraphQL */ `
  mutation FlashbackDeleteWish($token: String, $wishId: ID!) {
    flashbackDeleteWish(token: $token, wishId: $wishId)
  }
`

// ── 卡片站外公开（#771/R14）──────────────────────────────────────────────
// 开关（本人面，双入口 token）：返回状态含 shareId 与本人预览。preview 在
// enabled=false 时**仍在**（本人预览与公开门独立），故选择集固定，不做条件分叉。
export const FlashbackSetCardSharingMutationDocument = /* GraphQL */ `
  mutation FlashbackSetCardSharing($enabled: Boolean!, $token: String) {
    flashbackSetCardSharing(enabled: $enabled, token: $token) {
      enabled
      shareId
      preview {
        displayName
        city
        appliedAt
        occurredOn
        answers {
          questionKey
          segments {
            text
            fog
            len
          }
        }
        today {
          questionKey
          segments {
            text
            fog
            len
          }
        }
      }
    }
  }
`

// 公开读面（匿名，无 token/slug）：shareId 不存在/已关闭/档案已删 → null。
// 「朋友点开看到我的卡」的全部数据源——段结构即雾面口径，原文字符不出服务端。
export const FlashbackSharedCardQueryDocument = /* GraphQL */ `
  query FlashbackSharedCard($shareId: String!) {
    flashbackSharedCard(shareId: $shareId) {
      displayName
      city
      appliedAt
      occurredOn
      answers {
        questionKey
        segments {
          text
          fog
          len
        }
      }
      today {
        questionKey
        segments {
          text
          fog
          len
        }
      }
    }
  }
`

// ── 志愿者招募（R20/R21；U5 招募域 GraphQL 面）───────────────────────────────
//
// 三资源都带 workspace_id 租户，入口 workspaceId 是显式 argument（KTD2）。小程序
// 没有 URL slug，故先按 slug 解析入口工作台（getWorkspace 需登录 → 招募流先登录，
// 见 domain/recruitment.ts 的 moduledoc），后续三读写面共用该 id。
//
// 档案 selection（九键）在查询与两条 mutation 里各写一遍：本仓 operations.ts 一贯
// 内联 selection（见 Enrollment 两处），codegen 的文档加载器不认选择集常量插值。
export const RecruitmentWorkspaceQueryDocument = /* GraphQL */ `
  query RecruitmentWorkspace($slug: String!) {
    getWorkspace(slug: $slug) {
      id
      name
    }
  }
`

// 批次：匿名可读 open（申请侧的 workspaceId 需登录解析，故本页先登录再读）。
// 无 open 批次 → null（AE12 小程序侧的空态）；draft/closed 不因本字段露面。
export const CurrentRecruitmentCohortQueryDocument = /* GraphQL */ `
  query CurrentRecruitmentCohort($workspaceId: ID!) {
    currentRecruitmentCohort(workspaceId: $workspaceId) {
      id
      name
      applyDeadlineAt
      startsAt
      endsAt
      status
    }
  }
`

// 档案元数据：文件内容列（file_data）结构上不在 GraphQL 面（KTD3），读的是
// 文件名 / MIME / 大小 / 上传时间四键。
export const MyResumeProfileQueryDocument = /* GraphQL */ `
  query MyResumeProfile($workspaceId: ID!) {
    myResumeProfile(workspaceId: $workspaceId) {
      id
      fullName
      contactEmail
      weeklyHours
      skills
      fileName
      fileContentType
      fileSize
      uploadedAt
    }
  }
`

export const UpsertResumeProfileMutationDocument = /* GraphQL */ `
  mutation UpsertResumeProfile($workspaceId: ID!, $input: UpsertResumeProfileInput!) {
    upsertResumeProfile(workspaceId: $workspaceId, input: $input) {
      result {
        id
        fullName
        contactEmail
        weeklyHours
        skills
        fileName
        fileContentType
        fileSize
        uploadedAt
      }
      errors {
        message
        code
      }
    }
  }
`

// U2 单入口：先 upsertResumeProfile 建档，再上传（档案缺失 → resume_profile_not_found）。
// 文件经 base64-over-JSON（KTD3），请求体接近 endpoint 8MB 闸门 → 调用方放宽超时。
export const UploadResumeFileMutationDocument = /* GraphQL */ `
  mutation UploadResumeFile($workspaceId: ID!, $input: UploadResumeFileInput!) {
    uploadResumeFile(workspaceId: $workspaceId, input: $input) {
      result {
        id
        fullName
        contactEmail
        weeklyHours
        skills
        fileName
        fileContentType
        fileSize
        uploadedAt
      }
      errors {
        message
        code
      }
    }
  }
`

// 申请列表（申请人视角，跨批次新→旧；段位与拒绝原因）
export const MyVolunteerApplicationsQueryDocument = /* GraphQL */ `
  query MyVolunteerApplications($workspaceId: ID!) {
    myVolunteerApplications(workspaceId: $workspaceId) {
      id
      cohortId
      position
      city
      heardAboutUs
      hasInternalReferrer
      message
      status
      rejectionReason
      assignedEventId
      assignmentNote
      assignedAt
    }
  }
`

// 第 2 步提交（user_id 由 actor 强制填充，不接受客户端传入）；同批一份由后端
// 唯一约束 + volunteer_application_already_submitted 兜底。
export const CreateVolunteerApplicationMutationDocument = /* GraphQL */ `
  mutation CreateVolunteerApplication($workspaceId: ID!, $input: CreateVolunteerApplicationInput!) {
    createVolunteerApplication(workspaceId: $workspaceId, input: $input) {
      result {
        id
        cohortId
        position
        city
        heardAboutUs
        hasInternalReferrer
        message
        status
        rejectionReason
        assignedEventId
        assignmentNote
        assignedAt
      }
      errors {
        message
        code
      }
    }
  }
`

// 第一批：公开金句面。单句查询独立于热门列表，旧分享链接不受热度排序影响。
export const FlashbackVoicesQueryDocument = /* GraphQL */ `
  query FlashbackVoices($voterKey: String, $city: String) {
    flashbackPublicQuotes(voterKey: $voterKey, city: $city) {
      quoteId text attribution city year likeCount likedByViewer level publicSlug
    }
  }
`
export const FlashbackVoiceQueryDocument = /* GraphQL */ `
  query FlashbackVoice($quoteId: ID!, $voterKey: String) {
    flashbackPublicQuote(quoteId: $quoteId, voterKey: $voterKey) {
      quoteId text attribution city year likeCount likedByViewer level publicSlug
    }
  }
`
export const FlashbackRandomVoicesQueryDocument = /* GraphQL */ `
  query FlashbackRandomVoices($voterKey: String, $limit: Int) {
    flashbackRandomQuotes(voterKey: $voterKey, limit: $limit) {
      quoteId text attribution city year likeCount likedByViewer level publicSlug
    }
  }
`
export const FlashbackLikeVoiceMutationDocument = /* GraphQL */ `
  mutation FlashbackLikeVoice($quoteId: ID!, $voterKey: String!, $liked: Boolean!) {
    flashbackLikeQuote(quoteId: $quoteId, voterKey: $voterKey, liked: $liked) { likeCount }
  }
`

export const FlashbackVoiceCitiesQueryDocument = /* GraphQL */ `
  query FlashbackVoiceCities {
    flashbackVoiceCities { name fullName pinyin lngLat }
  }
`

export const FlashbackMyWishesQueryDocument = /* GraphQL */ `
  query FlashbackMyWishes {
    flashbackMyWishes {
      quotaRemaining
      wishes { id content city signature visibility status insertedAt }
    }
  }
`

export const FlashbackWishCitiesQueryDocument = /* GraphQL */ `
  query FlashbackWishCities { flashbackWishCities { name lngLat } }
`
export const FlashbackPublicWishQueryDocument = /* GraphQL */ `
  query FlashbackPublicWish($wishId: ID!, $voterKey: String) {
    flashbackPublicWish(wishId: $wishId, voterKey: $voterKey) {
      id
      content
      city
      signature
      expectationCount
      endorsementCount
      contributionDistribution
      expectedByViewer
      endorsedByViewer
      latestEcho {
        id
        content
        status
        publishedAt
        correctedAt
      }
      echoCount
      echoes {
        id
        content
        status
        publishedAt
        correctedAt
      }
      listedAt
      insertedAt
    }
  }
`
