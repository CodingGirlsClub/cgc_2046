defmodule Cgc2046.Accounts.Policies.PlatformAdminOwnerInvite do
  @moduledoc """
  仅允许平台管理员处理预授权 Owner 的邀请。

  平台管理员的治理权限与普通邀请业务写分离：pending-owner 生命周期需要
  平台管理员跨工作台创建或撤销 owner 预授权邀请，普通角色邀请不走该 bypass。
  """

  use Ash.Policy.SimpleCheck

  alias Cgc2046.Accounts.Invitation
  alias Cgc2046.Accounts.Policies.PlatformAdmin

  @impl true
  def describe(_opts), do: "actor is a platform admin with an owner invitation"

  @impl true
  def match?(nil, _context, _opts), do: false

  def match?(actor, context, _opts) do
    PlatformAdmin.platform_admin?(actor) and owner_invitation?(context)
  end

  defp owner_invitation?(%{changeset: changeset}), do: owner_invitation?(changeset)
  defp owner_invitation?(%{subject: subject}), do: owner_invitation?(subject)

  defp owner_invitation?(%Ash.Changeset{} = changeset) do
    owner_role?(Ash.Changeset.get_attribute(changeset, :preauthorized_role_names))
  end

  defp owner_invitation?(%Invitation{preauthorized_role_names: role_names}),
    do: owner_role?(role_names)

  defp owner_invitation?(_), do: false

  defp owner_role?(role_names), do: :owner in (role_names || [])
end
