/**
 * 业务错误（后端 BusinessError 携带稳定 code，#751）：mutation 信封的
 * errors[0].code 命中文案表时抛出——页面可按 code 分派自愈分支（如
 * order_deposit_consent_required → 转披露+勾选流程），不再只拿得到文案。
 *
 * 独立成文件、零依赖（不 import Taro/GraphQLRequestError）：domain 纯函数
 * （payment.ts 自愈判定）与 node --experimental-strip-types 单测都要加载它，
 * 而 client.ts 的 GraphQLRequestError 用了 strip-only 不支持的构造器参数属性。
 */
export class BusinessError extends Error {
  readonly code: string | null

  constructor(message: string, code: string | null = null) {
    super(message)
    this.name = 'BusinessError'
    this.code = code
  }
}
