defmodule Cgc2046.Mcp.Tools.UpdateCourse do
  @moduledoc """
  更新课程元数据（role-agent-journeys-v2 S3，Owner/Admin 管理工具，确认流
  two-tool 写，D-D3）。

  语义对齐 GraphQL updateCourse（同 `Courses.Course :update` action）：可更新
  字段 = domain accept 列表（title/description/slug/visibility/enrollment_policy/
  capacity/registration_deadline/starts_at/ends_at/pricing_enabled/price_tiers/
  curriculum_requirements）；status 走专用生命周期工具，不在此改。

  高风险依据：定价变更（pricing_enabled true→false）会同事务批量免缴待支付报名
  （`Cgc2046.Admission.Changes.WaivePendingOnPricingDisable`，R9/KTD4）——资金相关
  副作用必须经用户确认。pending 摘要精确列出将变更的字段与新值；true→false 时
  追加批量免缴影响摘要（待支付笔数计入）。nil 值视为未提供（不支持显式置空）。

  Owner/Admin 专属：默认 fail-closed member 门 + 工具层管理角色判定（第一段
  快速拒绝省 pending）；confirm 段由 update policy 兜底。
  """
  use Anubis.Server.Component, type: :tool

  alias Cgc2046.Accounts.{MembershipContext, Role}
  alias Cgc2046.Courses.Course
  alias Cgc2046.Mcp.{Confirmation, Wrapper}

  require Ash.Query

  # 与 Course :update 的 accept 一一对应（不发明字段）
  @updatable_fields ~w(title description slug visibility enrollment_policy capacity
                       registration_deadline starts_at ends_at pricing_enabled price_tiers
                       curriculum_requirements)

  schema do
    field(:workspace_id, {:required, :string}, description: "目标工作台 ID（UUID）")
    field(:course_id, {:required, :string}, description: "课程 ID（UUID）")
    field(:title, :string, description: "课程标题（设置真实标题即清除临时占位标记）")
    field(:description, :string, description: "公开展示文案")
    field(:slug, :string, description: "公开 URL 段（小写 [a-z0-9-]）")
    field(:visibility, :string, description: "可见性：public / workspace（可随时双向切换，D9）")
    field(:enrollment_policy, :string, description: "报名策略：open / request / invite_only")
    field(:capacity, :integer, description: "报名名额上限（≥1）")
    field(:registration_deadline, :string, description: "报名截止时间（ISO8601）")
    field(:starts_at, :string, description: "开课时间（ISO8601）")
    field(:ends_at, :string, description: "结课时间（ISO8601，须晚于 starts_at）")

    field(:pricing_enabled, :boolean, description: "是否收费；true→false 会批量免缴待支付报名（高风险，确认流）")

    field(:price_tiers, {:list, :map}, description: "价格档位配置（PriceTier 形状；改价不追溯已生成订单）")
    field(:curriculum_requirements, :map, description: "教研材料需求")
  end

  @impl true
  def execute(params, frame) do
    result =
      Wrapper.run(frame, params, "update_course", fn actor, workspace_id, params ->
        course_id = params["course_id"] || params[:course_id]

        with :ok <- authorize(actor, workspace_id),
             {:ok, course} <- fetch_course(actor, workspace_id, course_id),
             {:ok, changes} <- collect_changes(params) do
          summary =
            "更新课程「#{course.title}」（#{course.id}）字段：" <>
              Enum.map_join(changes, "；", fn {field, value} ->
                "#{field} → #{preview(value)}"
              end) <> waive_impact_summary(course, changes)

          Confirmation.request(
            frame.assigns[:current_user],
            "update_course",
            params,
            summary
          )
        end
      end)

    Cgc2046.Mcp.Tools.Response.to_response(result, frame)
  end

  @doc """
  确认后真正执行（由 `Confirmation.execute/3` 直接分派调用）。
  params 为 pending 落库的 redact 后参数（本工具参数无敏感键，直接可用）。
  """
  @spec execute_confirmed(term(), map()) :: {:ok, map()} | {:error, String.t()}
  def execute_confirmed(actor, params) do
    workspace_id = params["workspace_id"]
    course_id = params["course_id"]

    with {:ok, course} <- fetch_course(actor, workspace_id, course_id),
         {:ok, changes} <- collect_changes(params) do
      attrs = Map.new(changes, fn {field, value} -> {String.to_existing_atom(field), value} end)

      case course
           |> Ash.Changeset.for_update(:update, attrs, tenant: workspace_id)
           |> Ash.update(actor: actor, tenant: workspace_id) do
        {:ok, updated} ->
          {:ok,
           %{
             course_id: updated.id,
             title: updated.title,
             status: to_string(updated.status),
             updated_fields: Enum.map(changes, fn {field, _value} -> field end)
           }}

        {:error, %Ash.Error.Forbidden{}} ->
          {:error,
           "forbidden: owner or admin required to update course in workspace #{workspace_id}"}

        {:error, %Ash.Error.Invalid{} = err} ->
          {:error, Exception.message(err)}

        {:error, _} ->
          {:error, "failed to update course"}
      end
    end
  end

  # Owner/Admin 专属（S3）：工具层管理角色判定，非管理角色成员快速拒绝
  defp authorize(actor, workspace_id) do
    if actor |> MembershipContext.role_names(workspace_id) |> Enum.any?(&Role.manage_role?/1) do
      :ok
    else
      {:error, "forbidden: owner or admin required to update courses"}
    end
  end

  # tenant 收紧课程归属（save_course_content 同款纪律）：他租户 course_id 与不存在
  # 同一「not found」，不泄露存在性
  defp fetch_course(actor, workspace_id, course_id) do
    case Course
         |> Ash.Query.for_read(:get_by_id, %{id: course_id})
         |> Ash.read_one(actor: actor, tenant: workspace_id) do
      {:ok, nil} ->
        {:error, "course not found: #{course_id}"}

      {:ok, course} ->
        {:ok, course}

      {:error, %Ash.Error.Forbidden{}} ->
        {:error, "forbidden: not allowed to read course #{course_id}"}

      {:error, _} ->
        {:error, "failed to load course"}
    end
  end

  # 白名单 ∩ 入参（nil 视为未提供；false 是合法值——pricing_enabled true→false 是
  # 本工具的高风险主路径，不能用 || 收集），保持 @updatable_fields 声明序
  defp collect_changes(params) do
    changes =
      Enum.flat_map(@updatable_fields, fn field ->
        value =
          if Map.has_key?(params, field),
            do: params[field],
            else: Map.get(params, String.to_existing_atom(field))

        case value do
          nil -> []
          value -> [{field, value}]
        end
      end)

    if changes == [] do
      {:error, "no updatable fields provided (#{Enum.join(@updatable_fields, "|")})"}
    else
      {:ok, changes}
    end
  end

  # 批量免缴影响摘要（R9/KTD4，R12 影响可见）：仅 pricing_enabled true→false 时
  # 追加，并计入当前待支付笔数（第一段快速失败前的如实摘要，confirm 段以域
  # 事务内实况为准）
  defp waive_impact_summary(course, changes) do
    disabling? =
      course.pricing_enabled == true and
        Enum.any?(changes, fn {field, value} -> field == "pricing_enabled" and value == false end)

    if disabling? do
      count = payment_pending_count(course)

      "。注意：pricing_enabled 改为 false 将批量免缴该课程全部待支付报名" <>
        "（当前 #{count} 笔 payment_pending → confirmed，关联 pending 订单同事务作废，R9）"
    else
      ""
    end
  end

  defp payment_pending_count(course) do
    Cgc2046.Admission.Enrollment
    |> Ash.Query.filter(course_id == ^course.id and status == :payment_pending)
    |> Ash.count!(authorize?: false, tenant: course.workspace_id)
  end

  defp preview(value) when is_binary(value), do: value
  defp preview(value), do: Jason.encode!(value)
end
