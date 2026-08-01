defmodule Cgc2046Web.GraphqlSchema.RbacTypes do
  @moduledoc """
  #66 Rbac 契约类型（角色权限矩阵 / 当前用户能力）。
  """

  use Absinthe.Schema.Notation

  object :permission_abilities do
    field(:view_workspace, non_null(:boolean))
    field(:access_invite_only, non_null(:boolean))
    field(:list_members, non_null(:boolean))
    field(:manage_members, non_null(:boolean))
    field(:assign_roles, non_null(:boolean))
    field(:create_workspace, non_null(:boolean))
  end

  object :permission_matrix_row do
    field(:name, non_null(:string), description: "角色名：owner / admin / member")
    field(:abilities, non_null(:permission_abilities))
  end

  object :permission_matrix_payload do
    field(:roles, non_null(list_of(non_null(:permission_matrix_row))))
  end

  object :my_abilities_payload do
    field(:abilities, non_null(list_of(non_null(:string))))
  end
end
