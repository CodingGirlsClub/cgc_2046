/**
 * GraphQL 契约层共享类型（跨领域单源）。
 *
 * - MutationError：Ash Graphql create/update mutation 的错误信封。原在
 *   join.ts / workspace.ts / auth.ts / portfolio.ts 各重复定义一份（同构
 *   { message?, code? }），2026-08-05 收敛到此单源——任一处扩展字段其余
 *   自动同步，消除 drift。
 * - MutationResult<T>：create/update mutation 的两段式返回包装
 *   { result: T | null; errors: MutationError[] }。原 10 处 *ResultData
 *   interface 同构，收敛为泛型 alias（带 metadata 等额外字段的 result 类型
 *   保持具名 interface，仅复用此处的 MutationError）。
 *
 * 语义：成功时 result 非空、errors 为空数组；失败时 result 为 null、
 * errors 至少含一条带 message 的错误。
 */

export interface MutationError {
  message?: string | null;
  code?: string | null;
}

export type MutationResult<T> = {
  result: T | null;
  errors: MutationError[];
};
