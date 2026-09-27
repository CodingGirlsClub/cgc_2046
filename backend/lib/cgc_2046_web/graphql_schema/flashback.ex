defmodule Cgc2046Web.GraphqlSchema.Flashback do
  @moduledoc """
  闪念间（In a Flash）产品线 GraphQL 面聚合入口：首程 token 面、
  wish2 公开 / admin 面、触达运营与看板兑换的 notation 子模块群
  （Queries / Mutations / WishMutations / Types / WishTypes；域内
  helper 在 `Flashback.Helpers`）。schema 只 import_types 本模块。
  """

  use Absinthe.Schema.Notation

  import_types(Cgc2046Web.GraphqlSchema.Flashback.Queries)
  import_types(Cgc2046Web.GraphqlSchema.Flashback.Mutations)
  import_types(Cgc2046Web.GraphqlSchema.Flashback.WishMutations)
  import_types(Cgc2046Web.GraphqlSchema.Flashback.Types)
  import_types(Cgc2046Web.GraphqlSchema.Flashback.WishTypes)
end
