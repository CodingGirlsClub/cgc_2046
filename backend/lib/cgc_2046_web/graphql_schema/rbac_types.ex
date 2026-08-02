defmodule Cgc2046Web.GraphqlSchema.RbacTypes do
  @moduledoc """
  #66 Rbac 契约类型（角色权限矩阵）。

  #1 能力接口收敛：abilities 为通用 [{name, allowed}] 列表（不再固定六个字段），
  能力词汇唯一真源在 Rbac.abilities_list/0；契约工件 backend/priv/rbac_contract.json
  供前端静态展示词汇做 golden-file 守卫。
  """

  use Absinthe.Schema.Notation

  object :ability_grant do
    field(:name, non_null(:string),
      description:
        "能力名：view_workspace / access_invite_only / list_members / manage_members / assign_roles / create_workspace"
    )

    field(:allowed, non_null(:boolean))
  end

  object :permission_matrix_row do
    field(:name, non_null(:string),
      description: "角色名：owner / admin / member / tutor / volunteer / learner"
    )

    field(:abilities, non_null(list_of(non_null(:ability_grant))))
  end

  object :permission_matrix_payload do
    field(:roles, non_null(list_of(non_null(:permission_matrix_row))))
  end
end
