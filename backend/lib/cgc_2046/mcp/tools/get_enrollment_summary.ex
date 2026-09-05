defmodule Cgc2046.Mcp.Tools.GetEnrollmentSummary do
  @moduledoc """
  报名前摘要：向学员展示单个供给的目标/时间/定价/策略与「现在报名将创建的
  报名状态」（role-agent-journeys-v2 S7，R31）。

  授权（`membership: :deferred`，workspace_id 仍必填——D12 无状态作用域）：
  供给物读取**带 actor 走 policy 授权**（tenant 收紧到参数 workspace_id）——
  open+public 任何登录用户可读；workspace 可见性仅成员可读；draft 仅
  Owner/Admin。不可见与不存在返回同一 not_found 错误，不泄存在性。

  `would_create_status` 精确镜像 Enrollment `create_enrollment` 的
  prepare_policy 分支（驱动因子 = **offering 的 enrollment_policy**，
  与 workspace join_policy 无关）：

  - open + 免费 → `"confirmed"`（立即占位）
  - open + 收费 → `"payment_pending"`（占位后限时支付，ADR-0007）
  - request → `"pending"`（等 Owner/Admin 审批；收费目标审批通过后才进
    payment_pending）
  - invite_only → `nil`（域 action 强制 invite_code，本工具族不含邀请码
    入口——邀请报名走 web/小程序；policy 字段已标明 invite_only）

  截止已过/名额已满等失败不在本字段表达——create_enrollment 时由域错误原样
  报出。capacity_info 仅成员可读（capacity/confirmed_count 在 field_policy
  收窄名单内），非成员读公开条目落 nil。goals 仅课程有（S6 published
  revision，无 revision 回退 Curriculum.Output 草稿，
  Course.published_content/1）；活动用 description。
  """
  use Anubis.Server.Component, type: :tool, meta: %{membership: :deferred}

  alias Cgc2046.Admission.Enrollment
  alias Cgc2046.Courses.Course
  alias Cgc2046.Events.Event
  alias Cgc2046.Mcp.Tools.LearnerJourney
  alias Cgc2046.Mcp.Wrapper

  require Ash.Query

  schema do
    field(:workspace_id, {:required, :string}, description: "目标工作台 ID（UUID）")
    field(:kind, {:required, :string}, description: "event | course")

    field(:offering_id, {:required, :string},
      description: "活动或课程 ID（UUID，来自 discover_offerings 条目 id）"
    )
  end

  @impl true
  def execute(params, frame) do
    result =
      Wrapper.run(frame, params, "get_enrollment_summary", fn actor, workspace_id, params ->
        offering_id = params["offering_id"] || params[:offering_id]

        with {:ok, kind} <- LearnerJourney.parse_required_kind(params["kind"] || params[:kind]),
             {:ok, offering} <- fetch_offering(actor, workspace_id, kind, offering_id) do
          {:ok, to_summary(actor, kind, offering, workspace_id)}
        end
      end)

    Cgc2046.Mcp.Tools.Response.to_response(result, frame)
  end

  # 带 actor 的 policy 授权读（tenant 收紧）；不可见 = nil，与不存在同一拒绝。
  # read_one（非 bang）纪律同 get_public_offering：失败进 Wrapper 审计不逃逸。
  defp fetch_offering(actor, workspace_id, kind, offering_id) do
    resource = if kind == :event, do: Event, else: Course

    resource
    |> Ash.Query.filter(id == ^offering_id)
    |> Ash.Query.load(:available_price_tiers)
    |> Ash.read_one(actor: actor, tenant: workspace_id)
    |> case do
      {:ok, nil} -> {:error, "offering not found: #{offering_id}"}
      {:ok, offering} -> {:ok, offering}
      {:error, _} -> {:error, "failed to load offering"}
    end
  end

  defp to_summary(actor, kind, offering, workspace_id) do
    tiers = offering.available_price_tiers || []

    %{
      offering: %{
        kind: to_string(kind),
        id: offering.id,
        title: offering.title,
        slug: offering.slug,
        status: to_string(offering.status),
        visibility: to_string(offering.visibility),
        description: offering.description,
        goals: goals_for(kind, offering, workspace_id),
        registration_deadline: offering.registration_deadline,
        capacity_info: capacity_info(offering),
        price_tiers: tiers
      },
      policy: to_string(offering.enrollment_policy),
      pricing: %{enabled: offering.pricing_enabled, tiers: tiers},
      would_create_status: would_create_status(offering),
      my_enrollment: my_enrollment(actor, kind, offering.id, workspace_id)
    }
  end

  # 课程目标：S6 起内容源 = 当前 published revision（无 revision 的存量课程回退
  # 草稿），Course.published_content 单源。活动无 goals 概念 → []。
  # /2 显式 workspace_id：actor policy 读出的 offering 其 workspace_id 列对
  # 非成员是 ForbiddenField，/1 的 struct guard 会落 nil（S7 实测）。
  defp goals_for(:course, %Course{} = course, workspace_id) do
    case Course.published_content(course, workspace_id) do
      %{} = content -> Map.get(content, "goals") || []
      _ -> []
    end
  end

  defp goals_for(:event, _event, _workspace_id), do: []

  # capacity/confirmed_count 在 field_policy 收窄名单内：成员/管理面可读，
  # 非成员读公开条目为 %Ash.ForbiddenField{} → 落 nil（不超 web 匿名面——
  # 匿名口径只有派生 badge）。
  defp capacity_info(offering) do
    if match?(%Ash.ForbiddenField{}, offering.capacity) do
      nil
    else
      %{capacity: offering.capacity, confirmed_count: offering.confirmed_count}
    end
  end

  # 镜像 create_enrollment 的 prepare_policy/auto_confirm_status 分支
  # （invite_only 域强制 invite_code，本工具族无邀请码入口 → nil）。
  defp would_create_status(%{enrollment_policy: :open, pricing_enabled: true}),
    do: "payment_pending"

  defp would_create_status(%{enrollment_policy: :open}), do: "confirmed"
  defp would_create_status(%{enrollment_policy: :request}), do: "pending"
  defp would_create_status(%{enrollment_policy: :invite_only}), do: nil

  defp my_enrollment(actor, kind, offering_id, workspace_id) do
    case Enrollment.active_enrollment(actor, kind, offering_id, workspace_id) do
      nil -> nil
      enrollment -> %{id: enrollment.id, status: to_string(enrollment.status)}
    end
  end
end
