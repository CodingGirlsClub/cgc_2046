defmodule Cgc2046.Offering.PlatformAdminGovernanceWrite do
  @moduledoc """
  平台管理员治理写放行（U1/KTD1）：**逐 action** 收口的 offering 治理写面。

  平台管理员（`Cgc2046.Accounts.Policies.PlatformAdmin`）只对四类治理目标 action
  获得写能力：`:update` / `:launch` / `:close` / `:cancel`（Course/Event 同名同集）。
  其余 create/update 型 action（`:create`、`:qualify`、`:link_curriculum_run`、
  `:bind_current_revision`）不在白名单内 → 保持拒绝（R7 无旁路：create 的副作用链
  ——event 自动指派创建者为主理人、course 触发 prep run 实例化——与教研内容写路径
  不因治理面开洞）。

  ## 为什么是既有写 policy 里的第二个 `authorize_if`，而不是独立 policy 块

  Ash 的策略组合语义是「条件命中的 policy **必须全部放行**」（`Ash.Policy.Policy.expression/2`
  把每个 policy 折算成 `cond → pol` 后整体 AND），不是「命中任一 policy 即放行」。
  四类治理 action 同时属于既有的 `action_type([:create, :update])`——另立 policy 块
  会让工作台 Owner/Admin 的正常写同时命中两块，被本 check 拒掉（实测：独立块让
  Owner 的 launch 变 forbidden）。故放行以 **OR 语义的 `authorize_if`** 收在同一个
  写 policy 内：Owner/Admin 路径零变化，平台管理员只多出白名单内的 action。
  """

  use Ash.Policy.SimpleCheck

  alias Cgc2046.Accounts.Policies.PlatformAdmin

  # 治理目标 action 白名单（治理面单源）：只认 action **名**，不看 action_type——
  # action_type 泛化会把 create 与内部 update 型 action 一并放行。
  # launch/close/cancel 无字段面；:update 另受下方字段闭集约束。

  # `:update` 的字段闭集（R7/D3 独立评审收口）：平台管理员经**任何入口**（治理
  # mutation 或既有工作台 mutation）触发 `:update` 时，显式输入字段必须 ⊆
  # accept − 排除集。排除 = slug（R7 锁定）、教研字段（R7：prep 链专属）、
  # 挂载（initiative_id，D1 未批）与赞助设置（D1 未批）。
  # 判定只看 `changeset.attributes`（显式输入键）：RuleInheritance 的挂载
  # force-write 走 `force_change_attribute`（不进 attributes），不误拒挂载场的
  # 合法治理元数据更新。
  # slug 刻意不在排除集：slug 由 ADR-0014 的 status 守卫管理（draft 自由改、
  # 发布后 event_slug_locked/course_slug_locked 拒绝），字段闭集不复制该语义。
  @excluded_update_attrs %{
    Cgc2046.Events.Event => [
      :curriculum_enabled,
      :curriculum_requirements,
      :initiative_id,
      :course_revision_id,
      :sponsorship_enabled,
      :sponsorship_tiers,
      :sponsorship_deadline
    ],
    Cgc2046.Courses.Course => [:curriculum_requirements]
  }

  @impl true
  def describe(_opts), do: "actor is a platform admin performing an offering governance action"

  @impl true
  def match?(actor, %{action: %{name: name}} = context, _opts) do
    PlatformAdmin.platform_admin?(actor) and governance_write?(name, context.changeset)
  end

  def match?(_actor, _context, _opts), do: false

  defp governance_write?(name, _changeset) when name in [:launch, :close, :cancel], do: true

  defp governance_write?(:update, %Ash.Changeset{} = changeset) do
    excluded = Map.fetch!(@excluded_update_attrs, changeset.resource)
    action = Ash.Resource.Info.action(changeset.resource, :update)
    allowed = List.delete(action.accept || [], :*) -- excluded

    input_keys = changeset.attributes |> Map.keys() |> List.delete(:id)
    input_keys -- allowed == []
  end

  defp governance_write?(_name, _changeset), do: false
end
