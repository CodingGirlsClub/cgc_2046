defmodule Cgc2046.Mcp.Tools.ListCourseEnrollments do
  @moduledoc """
  列出某课程的报名记录（role-agent-journeys-v2 S3，Owner/Admin 管理读工具）。

  数据面同 web 管理页（`Admission.Enrollment` read policy：Owner/Admin 见本租户
  全部）。授权锚 = workspace：默认 fail-closed member 门之外，本工具层再做
  Owner/Admin 判定（`Role.manage_role?/1`），非管理角色成员快速拒绝并落
  ToolCallLog 审计。课程经 tenant 收紧归属——他租户 course_id 与不存在同一
  「not found」。

  返回紧凑行：enrollment_id / 报名人摘要（id/email/display_name）/ 状态 /
  档位（收费报名的 tier_id 快照，可按课程当前 price_tiers 解析出名称与金额）/
  approval_deadline / inserted_at。

  报名人摘要投影：User read policy 仅本人/平台管理员（ADR-0004），本工具不向
  User 资源发起授权读——报名列表先经 Enrollment read policy + tenant 授权收窄，
  再对 enrollee 的 id/email/display_name 做 `authorize?: false` 批量投影（与
  web 管理页经 Order `learner_email` SQL 计算列露出报名人邮箱同口径；
  save_course_content 工具层授权 + authorize?: false 读同款纪律）。
  """
  use Anubis.Server.Component, type: :tool

  alias Cgc2046.Accounts.{MembershipContext, Role, User}
  alias Cgc2046.Admission.Enrollment
  alias Cgc2046.Courses.Course
  alias Cgc2046.Mcp.Wrapper

  require Ash.Query

  @statuses ~w(pending payment_pending confirmed rejected expired cancelled)

  schema do
    field(:workspace_id, {:required, :string}, description: "目标工作台 ID（UUID）")
    field(:course_id, {:required, :string}, description: "课程 ID（UUID）")

    field(:status, :string,
      description: "按状态过滤（pending|payment_pending|confirmed|rejected|expired|cancelled；缺省 = 全部）"
    )
  end

  @impl true
  def execute(params, frame) do
    result =
      Wrapper.run(frame, params, "list_course_enrollments", fn actor, workspace_id, params ->
        course_id = params["course_id"] || params[:course_id]
        status = params["status"] || params[:status]

        with :ok <- authorize(actor, workspace_id),
             {:ok, course} <- fetch_course(actor, workspace_id, course_id),
             {:ok, status} <- parse_status(status) do
          # read（非 bang）+ 错误分类：Forbidden 等错误也落 ToolCallLog 审计
          query =
            Enrollment
            |> Ash.Query.filter(course_id == ^course.id)
            |> maybe_filter_status(status)
            |> Ash.Query.sort(inserted_at: :desc)

          case Ash.read(query, actor: actor, tenant: workspace_id) do
            {:ok, enrollments} ->
              users = load_enrollees(enrollments)

              {:ok,
               %{
                 workspace_id: workspace_id,
                 course_id: course.id,
                 course_title: course.title,
                 status: status || "all",
                 count: length(enrollments),
                 enrollments: Enum.map(enrollments, &to_row(&1, course, users))
               }}

            {:error, %Ash.Error.Forbidden{}} ->
              {:error, "forbidden: not allowed to list enrollments of workspace #{workspace_id}"}

            {:error, _} ->
              {:error, "failed to list enrollments"}
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
      {:error, "forbidden: owner or admin required to list enrollments"}
    end
  end

  # tenant 收紧课程归属：他租户 course_id 与不存在同一「not found」，不泄露存在性
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

  defp parse_status(nil), do: {:ok, nil}
  defp parse_status(status) when status in @statuses, do: {:ok, status}

  defp parse_status(_status),
    do: {:error, "invalid status (expected one of #{Enum.join(@statuses, "|")})"}

  # 白名单校验后才 to_existing_atom（不污染 atom 表）
  defp maybe_filter_status(query, nil), do: query

  defp maybe_filter_status(query, status),
    do: Ash.Query.filter(query, status == ^String.to_existing_atom(status))

  # enrollee 批量投影（authorize?: false——授权已在工具层 + enrollment 读完成；
  # 只取 id/email/display_name 三字段，与 web 管理页露出同口径）
  defp load_enrollees(enrollments) do
    user_ids = enrollments |> Enum.map(& &1.user_id) |> Enum.uniq()

    User
    |> Ash.Query.filter(id in ^user_ids)
    |> Ash.read!(authorize?: false)
    |> Map.new(fn user -> {user.id, user} end)
  end

  defp to_row(enrollment, course, users) do
    user = Map.get(users, enrollment.user_id)

    %{
      enrollment_id: enrollment.id,
      user: %{
        id: enrollment.user_id,
        email: user && user.email && to_string(user.email),
        display_name: user && user.display_name
      },
      status: to_string(enrollment.status),
      tier: tier_row(enrollment, course),
      approval_deadline: enrollment.approval_deadline,
      inserted_at: enrollment.inserted_at
    }
  end

  # 收费报名的档位快照（KTD9 报名时写入 submission_payload.tier_id）；按课程
  # 当前 price_tiers 解析名称与金额（档位被删/改名时回退裸 tier_id）
  defp tier_row(enrollment, course) do
    case enrollment.submission_payload["tier_id"] do
      nil ->
        nil

      tier_id ->
        tier = Enum.find(course.price_tiers || [], &(&1["id"] == tier_id))

        case tier do
          nil ->
            %{id: tier_id}

          tier ->
            %{id: tier_id, name: tier["name"], amount_cents: tier["amount_cents"]}
        end
    end
  end
end
