defmodule Cgc2046.Mcp.Tools.CreateCourse do
  @moduledoc """
  创建课程草稿（role-agent-journeys-v2 S3，Owner/Admin 管理工具，直接写不进确认流）。

  语义对齐 GraphQL createCourse（同 `Courses.Course :create` action）：status 恒 draft
  （domain change 强制），slug 缺省由 domain 生成 `c-<hex>`。`title` 可缺省
  （零输入草稿，R21/AE1）：不提供时 domain 生成临时占位标题
  `未命名课程 <hex8>` 并置 `provisional_title`，发布（launch）前必须经
  update_course 补齐正式标题（命名门）。

  直接写依据：创建私密 draft 可逆/低风险（R12），不进 D-D3 确认流；生命周期
  推进（launch/close/cancel）与定价变更（update_course）走确认流工具。

  Owner/Admin 专属：默认 fail-closed member 门 + 工具层管理角色判定；
  业务 create action 的 `WorkspaceActorIsOwnerOrAdmin` policy 兜底。
  """
  use Anubis.Server.Component, type: :tool

  alias Cgc2046.Accounts.{MembershipContext, Role}
  alias Cgc2046.Courses.Course
  alias Cgc2046.Mcp.Wrapper

  # 与 Course :create 的 accept 一一对应（不发明字段）；nil = 未提供
  @create_fields ~w(title description curriculum_requirements enrollment_policy capacity
                    registration_deadline starts_at ends_at visibility slug pricing_enabled
                    price_tiers)

  schema do
    field(:workspace_id, {:required, :string}, description: "目标工作台 ID（UUID）")

    field(:title, :string,
      description: "课程标题（可缺省：不提供时系统生成临时标题「未命名课程 <hex>」，Tutor 发布前必须经 update_course 补齐）"
    )

    field(:description, :string, description: "公开展示文案")
    field(:slug, :string, description: "公开 URL 段（小写 [a-z0-9-]；缺省由平台生成 c-<hex>）")

    field(:visibility, :string, description: "可见性：public 公开 / workspace 仅工作台（默认 public）")

    field(:enrollment_policy, :string, description: "报名策略：open / request / invite_only（默认 open）")
    field(:capacity, :integer, description: "报名名额上限（≥1；不提供 = 不限）")
    field(:registration_deadline, :string, description: "报名截止时间（ISO8601；不提供 = 不设截止）")
    field(:starts_at, :string, description: "开课时间（ISO8601）")
    field(:ends_at, :string, description: "结课时间（ISO8601，须晚于 starts_at）")
    field(:pricing_enabled, :boolean, description: "是否收费（默认 false；true 时报名须选档并完成支付）")

    field(:price_tiers, {:list, :map},
      description: "价格档位配置（PriceTier 形状：%{id, name, amount_cents, ...}）"
    )

    field(:curriculum_requirements, :map, description: "教研材料需求（audience/duration/sections 等）")
  end

  @impl true
  def execute(params, frame) do
    result =
      Wrapper.run(frame, params, "create_course", fn actor, workspace_id, params ->
        with :ok <- authorize(actor, workspace_id) do
          input = take_fields(params, @create_fields)

          case Course
               |> Ash.Changeset.for_create(:create, input, tenant: workspace_id)
               |> Ash.create(actor: actor, tenant: workspace_id) do
            {:ok, course} ->
              {:ok,
               %{
                 course_id: course.id,
                 title: course.title,
                 slug: course.slug,
                 status: to_string(course.status),
                 visibility: to_string(course.visibility),
                 pricing_enabled: course.pricing_enabled
               }}

            {:error, %Ash.Error.Forbidden{}} ->
              {:error, "forbidden: not allowed to create course in workspace #{workspace_id}"}

            {:error, %Ash.Error.Invalid{} = err} ->
              {:error, Exception.message(err)}

            {:error, _} ->
              {:error, "failed to create course"}
          end
        end
      end)

    Cgc2046.Mcp.Tools.Response.to_response(result, frame)
  end

  # Owner/Admin 专属（S3）：工具层管理角色判定，非管理角色成员快速拒绝
  defp authorize(actor, workspace_id) do
    if actor |> MembershipContext.role_names(workspace_id) |> Enum.any?(&Role.manage_role?/1) do
      :ok
    else
      {:error, "forbidden: owner or admin required to create courses"}
    end
  end

  # 白名单取参（string/atom 键双兼容；固定字段名 to_existing_atom 不污染 atom 表）；
  # nil 值视为未提供（本工具不支持显式置空）
  defp take_fields(params, fields) do
    fields
    |> Enum.filter(fn field ->
      value = params[field] || params[String.to_existing_atom(field)]
      not is_nil(value)
    end)
    |> Map.new(fn field ->
      {String.to_existing_atom(field), params[field] || params[String.to_existing_atom(field)]}
    end)
  end
end
