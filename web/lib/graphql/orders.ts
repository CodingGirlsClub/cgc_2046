import { gql } from "@apollo/client";
import type { TypedDocumentNode } from "@apollo/client";
import type { MutationError, MutationResult } from "./shared";

/**
 * 缴费闭环订单 GraphQL 契约（plan 024 U5/U10 + backend/priv/graphql/schema.graphql）。
 *
 * - 学员面：createOrder / replaceProvider / cancelOrder（本人 payment_pending 报名）、
 *   orderStatus 轮询（R14）、myOrders；
 * - 管理面：workspaceOrders（状态筛选 + tier/报名人信息计算字段）、
 *   workspacePaymentStats（R24；返回 JsonString——U10 决策 3：三个 snake_case
 *   int 键，经 lib/payment.parsePaymentStats 解析）；refundOrder（R15）/
 *   retryRefund（R17）/waivePayment（R18，作用于报名）为后端两段确认
 *   （第一段建 pending 返回后端摘要，confirmOperation/cancelOperation 收尾）。
 * - createOrder/replaceProvider 的支付凭据在 metadata.credential（JsonString：
 *   qr_code → code_url；redirect → url；jsapi 仅小程序），分派见
 *   lib/payment.dispatchCredential。
 */

/* ---------------- 类型 ---------------- */

export type PaymentProvider =
  "wechat_jsapi" | "wechat_native" | "alipay_page" | "alipay_wap" | "alipay_qr";

export type OrderStatus =
  | "pending"
  | "paid"
  | "refunding"
  | "refunded"
  | "refund_failed"
  | "cancelled"
  | "expired";

export interface Order {
  id: string;
  enrollmentId: string;
  provider: string;
  outTradeNo: string;
  transactionId: string | null;
  amountCents: number;
  status: OrderStatus | string;
  expireAt: string;
  refundedAt: string | null;
  cancelReason: string | null;
  /** 下单时档位快照（JsonString，含 name；成功卡明细取名见 lib/payment.tierSnapshotName） */
  tierSnapshot?: string | null;
  /** 管理列表计算字段（R24） */
  tierName?: string | null;
  /** 下单时档位快照 id（U8 已售档守卫，R10） */
  tierId?: string | null;
  enrollmentStatus?: string | null;
  learnerEmail?: string | null;
}
export interface CreateOrderPayload {
  result: Order | null;
  errors: { message: string; code?: string | null }[];
  metadata: { credential: string | null } | null;
}

export type OrderMutationResult = MutationResult<Order>;

/**
 * 高风险支付操作两段确认（R2 对齐：refundOrder/retryRefund/waivePayment 第一段
 * 只建 PendingOperation 不落业务库）——pendingId + 后端生成的确认摘要；
 * errors 为业务错误（与自动 mutation 同通道，按 code 查文案）。
 */
export interface PendingConfirmation {
  pendingId: string | null;
  summary: string | null;
  errors: MutationError[];
}

/** confirmOperation/cancelOperation 返回：status = confirmed | cancelled */
export interface OperationResolution {
  pendingId: string | null;
  status: string | null;
  errors: MutationError[];
}

/* ---------------- 学员面 ---------------- */

export const CREATE_ORDER: TypedDocumentNode<
  { createOrder: CreateOrderPayload },
  { input: { enrollmentId: string; provider: PaymentProvider } }
> = gql`
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
        code
        message
      }
      metadata {
        credential
      }
    }
  }
`;

export const REPLACE_PROVIDER: TypedDocumentNode<
  { replaceProvider: CreateOrderPayload },
  { input: { orderId: string; provider: PaymentProvider } }
> = gql`
  mutation ReplaceProvider($input: ReplaceProviderInput!) {
    replaceProvider(input: $input) {
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
        code
        message
      }
      metadata {
        credential
      }
    }
  }
`;

export const ORDER_STATUS: TypedDocumentNode<
  { orderStatus: Order | null },
  { id: string }
> = gql`
  query OrderStatus($id: ID!) {
    orderStatus(id: $id) {
      id
      status
      transactionId
      expireAt
      amountCents
      outTradeNo
      tierSnapshot
    }
  }
`;

export const MY_ORDERS: TypedDocumentNode<
  { myOrders: { results: Order[] } },
  Record<string, never>
> = gql`
  query MyOrders {
    myOrders {
      results {
        id
        enrollmentId
        provider
        status
        amountCents
        expireAt
        insertedAt
      }
    }
  }
`;

/**
 * 某报名下是否已有进行中订单。两个消费方：
 * - /orders/new 进页守卫：payment_pending 且已有 pending 订单 → 直接跳已有
 *   订单页，避免重复下单撞后端 not_payment_pending（只用 id）；
 * - 收银模态框（payment-checkout-dialog）：复用活单就绪态渲染（渠道选中/
 *   金额/倒计时），字段随查询一并返回，避免二次拉取。
 */
export const MY_PENDING_ORDERS: TypedDocumentNode<
  {
    myOrders: {
      results: Array<
        Pick<
          Order,
          "id" | "provider" | "status" | "amountCents" | "expireAt" | "outTradeNo"
        >
      >;
    };
  },
  { enrollmentId: string }
> = gql`
  query MyPendingOrders($enrollmentId: ID!) {
    myOrders(
      filter: { enrollmentId: { eq: $enrollmentId }, status: { eq: "pending" } }
      first: 1
    ) {
      results {
        id
        provider
        status
        amountCents
        expireAt
        outTradeNo
      }
    }
  }
`;

/* ---------------- 管理面（R24/R15/R18） ---------------- */

export interface AdminOrderFilter {
  workspaceId: string;
  status?: string;
  /** organizer-payment U4：订单按活动/课程收敛（详情页经营面，R6） */
  eventId?: string;
  courseId?: string;
}

export const WORKSPACE_ORDERS: TypedDocumentNode<
  {
    workspaceOrders: {
      results: Order[];
      count: number | null;
      startKeyset: string | null;
      endKeyset: string | null;
    };
  },
  AdminOrderFilter & {
    filter?:
      | {
          status?: { eq?: string; in?: string[] };
          eventId?: { eq?: string };
          courseId?: { eq?: string };
        }
      | null;
    /** U7 keyset 分页（页大小 20；after = 上一页 endKeyset） */
    first?: number;
    after?: string | null;
  }
> = gql`
  query WorkspaceOrders(
    $workspaceId: ID!
    $filter: OrderFilterInput
    $first: Int
    $after: String
  ) {
    workspaceOrders(
      workspaceId: $workspaceId
      filter: $filter
      first: $first
      after: $after
    ) {
      count
      results {
        id
        enrollmentId
        provider
        outTradeNo
        transactionId
        amountCents
        status
        expireAt
        refundedAt
        cancelReason
        tierName
        tierId
        enrollmentStatus
        learnerEmail
      }
      startKeyset
      endKeyset
    }
  }
`;
export const WORKSPACE_PAYMENT_STATS: TypedDocumentNode<
  { workspacePaymentStats: string },
  { workspaceId: string; eventId?: string; courseId?: string }
> = gql`
  query WorkspacePaymentStats(
    $workspaceId: ID!
    $eventId: ID
    $courseId: ID
  ) {
    workspacePaymentStats(
      workspaceId: $workspaceId
      eventId: $eventId
      courseId: $courseId
    )
  }
`;

/**
 * 退款（R15）：两段确认第一段——建 pending 返回后端摘要（不落业务库）；
 * 确认/取消走 CONFIRM_OPERATION / CANCEL_OPERATION。
 */
export const REFUND_ORDER: TypedDocumentNode<
  { refundOrder: PendingConfirmation },
  { id: string }
> = gql`
  mutation RefundOrder($id: ID!) {
    refundOrder(id: $id) {
      pendingId
      summary
      errors {
        code
        message
      }
    }
  }
`;

/** 免缴（R18）：作用于报名（payment_pending → confirmed），非订单；两段确认第一段 */
export const WAIVE_PAYMENT: TypedDocumentNode<
  { waivePayment: PendingConfirmation },
  { id: string }
> = gql`
  mutation WaivePayment($id: ID!) {
    waivePayment(id: $id) {
      pendingId
      summary
      errors {
        code
        message
      }
    }
  }
`;

/** 退款失败重试（organizer-payment U4/R7）：refund_failed → refunding 重入退款链；两段确认第一段 */
export const RETRY_REFUND: TypedDocumentNode<
  { retryRefund: PendingConfirmation },
  { id: string }
> = gql`
  mutation RetryRefund($id: ID!) {
    retryRefund(id: $id) {
      pendingId
      summary
      errors {
        code
        message
      }
    }
  }
`;

/** 两段确认第二段：确认并执行 pending 操作（仅本人、pending 且未过期） */
export const CONFIRM_OPERATION: TypedDocumentNode<
  { confirmOperation: OperationResolution },
  { pendingId: string }
> = gql`
  mutation ConfirmOperation($pendingId: ID!) {
    confirmOperation(pendingId: $pendingId) {
      pendingId
      status
      errors {
        code
        message
      }
    }
  }
`;

/** 两段确认第二段：取消 pending 操作（仅本人、pending；取消后不执行） */
export const CANCEL_OPERATION: TypedDocumentNode<
  { cancelOperation: OperationResolution },
  { pendingId: string }
> = gql`
  mutation CancelOperation($pendingId: ID!) {
    cancelOperation(pendingId: $pendingId) {
      pendingId
      status
      errors {
        code
        message
      }
    }
  }
`;
