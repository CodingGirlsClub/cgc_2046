defmodule Cgc2046.Policies.ReadOwnUser do
  @moduledoc """
  User 读取授权：仅本人可读（ADR-0004 收窄）。

  ADR-0004 后 User 为全局身份（email/display_name/is_platform_admin），profile
  可见性（public/workspace/only_me）已迁至 `WorkspaceProfile` 的
  `ReadWorkspaceProfileByVisibility`；User read 仅服务 me（本人查自己）与认证流程，
  故收窄为 filter 阶段 `id == actor.id`。匿名（actor nil）→ 恒假 filter 不可读。

  说明：不再用 visibility 三档（原 ReadUserByVisibility 语义已迁移），
  成员列表经 `WorkspaceMembership.user_email/user_display_name` 平铺展示（旁路读取面），
  不经 User read policy。
  """
  use Ash.Policy.FilterCheck

  @impl true
  def describe(_opts), do: "用户可读：仅本人（匿名不可读）"

  @impl true
  def filter(nil, _context, _opts) do
    # 匿名：恒假 filter（每行 is_nil(id) 为 false → 0 行）
    expr(is_nil(id))
  end

  def filter(actor, _context, _opts) do
    expr(id == ^actor.id)
  end
end
