defmodule Cgc2046.Changes.ValidateInviterRolePreauthorization do
  @moduledoc """
  校验邀请创建时 inviter 的角色与预授权角色的一致性（决策 5）。

  Volunteer 不可预授权 Admin 级角色（owner/admin）。
  如果 inviter 的角色不在 Role.manage_roles()（owner/admin）中，
  则 preauthorized_role_names 不得包含 owner 或 admin。

  始终用真实调用者（actor）查角色，而非 changeset 上的 inviter_id——
  inviter_id 是 GraphQL mutation 的外部 argument，create policy 已用
  forbid_unless 强制 inviter_id == actor.id，但此 change 作为纵深防御，
  不信任 inviter_id 与 actor 的一致性，直接读 actor 防止伪造越权。
  """
  use Ash.Resource.Change

  alias Cgc2046.Accounts.MembershipContext
  alias Cgc2046.Accounts.Role

  @impl true
  def change(changeset, _opts, _context) do
    # 用 before_action：普通 change 在 for_create 构建阶段 actor 为 nil，
    # 真实 actor 只在 authorization 通过后的 before_action 回调里可取
    # （与 portfolio_item.ex create :user_id 注入同款模式）。
    Ash.Changeset.before_action(changeset, fn cs ->
      preauthorized_role_names = Ash.Changeset.get_attribute(cs, :preauthorized_role_names)

      # 无预授权角色则无需校验
      if is_nil(preauthorized_role_names) || preauthorized_role_names == [] do
        cs
      else
        workspace_id = Ash.Changeset.get_attribute(cs, :workspace_id)
        actor = cs.context[:private][:actor]

        if workspace_id && actor do
          # 用真实 actor 查角色，杜绝 inviter_id 伪造导致的权限提升
          inviter_roles = MembershipContext.role_names(actor, workspace_id)
          manage_roles = Role.manage_roles()

          # 如果 inviter 没有管理角色（owner/admin），则检查预授权角色
          if Enum.any?(inviter_roles, &(&1 in manage_roles)) do
            cs
          else
            forbidden = Enum.filter(preauthorized_role_names, &(&1 in manage_roles))

            if forbidden == [] do
              cs
            else
              cs
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
          cs
        end
      end
    end)
  end
end
