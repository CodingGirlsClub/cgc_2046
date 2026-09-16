defimpl AshGraphql.Error, for: Ash.Error.Unknown do
  @moduledoc """
  `Ash.Error.Unknown` **类**的 GraphQL 映射（#612 全局安全网）。

  单一未知错误经 `Ash.Error.to_error_class/2` 归并后就是本类，此前无 impl，
  落到 `AshGraphql.Errors.to_errors/6` 的 else 分支（无 code 的 uuid 文案）。

  形状与日志口径全部委托 `Cgc2046.Errors.DatabaseError`（唯一判据/唯一文案
  出口）；本文件只做协议接线。同族叶子见
  `lib/cgc_2046_web/ash_graphql/unknown_error_leaf.ex`。
  """

  def to_error(error), do: Cgc2046.Errors.DatabaseError.graphql_error(error)
end
