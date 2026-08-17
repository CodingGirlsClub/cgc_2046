import { gql } from "@apollo/client";
import type { TypedDocumentNode } from "@apollo/client";
import type { MutationResult } from "./shared";

/**
 * 缴费闭环订单 GraphQL 契约（plan 024 U5/U10 + backend/priv/graphql/schema.graphql）。
 *
 * - 学员面：createOrder / replaceProvider / cancelOrder（本人 payment_pending 报名）、
 *   orderStatus 轮询（R14）、myOrders；
 * - 管理面：workspaceOrders（状态筛选 + tier/报名人信息计算字段）、
 *   workspacePaymentStats（R24；返回 JsonString——U10 决策 3：三个 snake_case
 *   int 键，经 lib/payment.parsePaymentStats 解析）、refundOrder（R15）、
 *   waivePayment（R18，作用于报名）。
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
  /** 管理列表计算字段（R24） */
  tierName?: string | null;
  enrollmentStatus?: string | null;
  learnerEmail?: string | null;
}

export interface CreateOrderPayload {
  result: Order | null;
  errors: { message: string }[];
  metadata: { credential: string | null } | null;
}

export type OrderMutationResult = MutationResult<Order>;

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
        Pick<Order, "id" | "provider" | "status" | "amountCents" | "expireAt">
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
      }
    }
  }
`;

/* ---------------- 管理面（R24/R15/R18） ---------------- */

export interface AdminOrderFilter {
  workspaceId: string;
  status?: string;
}

export const WORKSPACE_ORDERS: TypedDocumentNode<
  { workspaceOrders: { results: Order[]; count: number | null } },
  AdminOrderFilter & { filter?: { status: { eq: string } } | null }
> = gql`
  query WorkspaceOrders($workspaceId: ID!, $filter: OrderFilterInput) {
    workspaceOrders(workspaceId: $workspaceId, filter: $filter) {
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
        enrollmentStatus
        learnerEmail
      }
    }
  }
`;

export const WORKSPACE_PAYMENT_STATS: TypedDocumentNode<
  { workspacePaymentStats: string },
  { workspaceId: string }
> = gql`
  query WorkspacePaymentStats($workspaceId: ID!) {
    workspacePaymentStats(workspaceId: $workspaceId)
  }
`;

export const REFUND_ORDER: TypedDocumentNode<
  { refundOrder: OrderMutationResult },
  { id: string }
> = gql`
  mutation RefundOrder($id: ID!) {
    refundOrder(id: $id) {
      result {
        id
        status
      }
      errors {
        message
      }
    }
  }
`;

/** 免缴（R18）：作用于报名（payment_pending → confirmed），非订单 */
export const WAIVE_PAYMENT: TypedDocumentNode<
  { waivePayment: MutationResult<{ id: string; status: string }> },
  { id: string }
> = gql`
  mutation WaivePayment($id: ID!) {
    waivePayment(id: $id) {
      result {
        id
        status
      }
      errors {
        message
      }
    }
  }
`;
