defmodule Cgc2046.Admission.Policies.EventModerator do
  @moduledoc """
  「Event 主理人」授权的命名 SimpleCheck（押金制 KTD4；R6、R11）。

  核销的授权主体是**活动级**的：主理人是「成员里被指派管这场」的人
  （#558：成员前提由 assign 写边界承载），授权判定落在 Event 上的指派
  关系而非租户管理角色上。判定：

  1. 取 changeset 的 `event_id` 参数与 `tenant`（调用方传入的租户）；
  2. `authorize?: false` 直读 Event（带 tenant：租户不一致即读不到 → 拒绝）；
  3. 委托 `Events.Moderators.can_moderate?/2`（主理人 **或** 目标 workspace
     Owner/Admin，多角色并集），并要求 `event.workspace_id == tenant`。

  任一读取失败 / 字段缺失 / 租户不一致 → false（fail-closed，
  `ActorIsAttemptLearner` 同款模板）。PlatformAdmin 不在本 check 内——它由
  `Attendance` 的 policy 并联 `authorize_if PlatformAdmin` 单独放行
  （`Rbac.manage?/2` 不认平台管理员，两条分支语义不同）。

  仅用于 `Attendance.check_in`（create）上下文；其他 action/资源一律 false。
  """

  use Ash.Policy.SimpleCheck

  alias Cgc2046.Events.{Event, Moderators}

  @impl true
  def describe(_opts), do: "actor can moderate the target event"

  @impl true
  def match?(nil, _context, _opts), do: false

  def match?(actor, %{changeset: %Ash.Changeset{} = changeset}, _opts) do
    event_id = Ash.Changeset.get_argument(changeset, :event_id)
    tenant = changeset.tenant

    with {:ok, event_id} <- Ecto.UUID.cast(event_id),
         true <- is_binary(tenant),
         {:ok, %Event{} = event} <-
           Ash.get(Event, event_id, tenant: tenant, authorize?: false) do
      event.workspace_id == tenant and Moderators.can_moderate?(actor, event)
    else
      _ -> false
    end
  end

  def match?(_actor, _context, _opts), do: false
end
