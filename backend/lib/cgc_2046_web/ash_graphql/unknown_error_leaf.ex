defimpl AshGraphql.Error, for: Ash.Error.Unknown.UnknownError do
  @moduledoc """
  `Ash.Error.Unknown.UnknownError` **叶子**的 GraphQL 映射（#612 全局安全网）。

  为什么叶子也要 impl（实测依据，不是冗余洁癖）：

  1. `Ash.Error.to_ash_error/2`（ash_postgres 数据层处理 `%Postgrex.Error{}` 等
     异常的入口）返回的就是叶子，不是类；
  2. `AshGraphql.Graphql.Resolver.unwrap_errors/1` 会展开
     `%Ash.Error.Invalid{errors: [...]}`——混合树（invalid 类错误 + 未知叶子，
     Splode `choose_error/1` 取类序号最小者 = Invalid）到面的是**叶子**，
     只实现类会漏掉这条路径；
  3. ash_graphql 升版若改变 `unwrap_errors/1` 的展开规则，本 impl 是冗余兜底。

  形状与日志口径委托 `Cgc2046.Errors.DatabaseError`。同族类见
  `lib/cgc_2046_web/ash_graphql/unknown_error.ex`。
  """

  def to_error(error), do: Cgc2046.Errors.DatabaseError.graphql_error(error)
end
