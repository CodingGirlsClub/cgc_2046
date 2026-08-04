defmodule Cgc2046.Changes.ValidateInviterRolePreauthorization do
  @moduledoc """
  校验邀请创建时 inviter 的角色与预授权角色的一致性（决策 5）。

  Volunteer 不可预授权 Admin 级角色（owner/admin）。
  如果 inviter 的角色不在 Role.manage_roles()（owner/admin）中，
  则 preauthorized_role_names 不得包含 owner 或 admin。

  复用 MembershipContext.role_names/2 读取 inviter 的角色。
  """
  use Ash.Resource.Change

  alias Cgc2046.Accounts.MembershipContext
  alias Cgc2046.Accounts.Role

  @impl true
  def change(changeset, _opts, _context) do
    preauthorized_role_names = Ash.Changeset.get_attribute(changeset, :preauthorized_role_names)

    # 无预授权角色则无需校验
    if is_nil(preauthorized_role_names) || preauthorized_role_names == [] do
      changeset
    else
      workspace_id = Ash.Changeset.get_attribute(changeset, :workspace_id)
      inviter_id = Ash.Changeset.get_attribute(changeset, :inviter_id)

      if workspace_id && inviter_id do
        inviter_roles = MembershipContext.role_names(%{id: inviter_id}, workspace_id)
        manage_roles = Role.manage_roles()

        # 如果 inviter 没有管理角色（owner/admin），则检查预授权角色
        if Enum.any?(inviter_roles, &(&1 in manage_roles)) do
          changeset
        else
          forbidden = Enum.filter(preauthorized_role_names, &(&1 in manage_roles))

          if forbidden == [] do
            changeset
          else
            changeset
            |> Ash.Changeset.add_error(
              Ash.Error.Changes.InvalidAttribute.exception(
                field: :preauthorized_role_names,
                message:
                  "Volunteer cannot preauthorize admin-level roles: #{Enum.map(forbidden, &to_string/1) |> Enum.join(", ")}"
              )
            )
          end
        end
      else
        changeset
      end
    end
  end
end
