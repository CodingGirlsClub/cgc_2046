defmodule Cgc2046.Mcp.Tools.ConfirmEnrollment do
  @moduledoc """
  确认报名（role-agent-journeys-v2 S3，Owner/Admin 管理工具，确认流 two-tool
  写，D-D3）。

  语义对齐 GraphQL confirmEnrollment（同 `Admission.Enrollment :confirm_enrollment`
  action）：pending → 原子占位 + 落点分叉（KTD6-3）——免费课程直接
  confirmed 占名额；收费课程落 payment_pending（支付完成或免缴才真正
  confirmed）。

  第一次调用：不落业务库，建 PendingOperation，返回 needs_confirmation。
  非 pending 报名快速失败（不建 pending，approve_join_request 同款纪律）；
  并发拦截由 domain 的原子 claim 在 confirm 段兜底。

  Owner/Admin 专属：默认 fail-closed member 门 + 工具层管理角色判定（第一段
  快速拒绝省 pending）；confirm 段由 confirm_enrollment policy 兜底（审批人
  角色可能在确认窗口内被撤）。
  """
  use Anubis.Server.Component, type: :tool

  alias Cgc2046.Accounts.{MembershipContext, Role}
  alias Cgc2046.Admission.Enrollment
  alias Cgc2046.Mcp.{Confirmation, Wrapper}

  schema do
    field(:workspace_id, {:required, :string}, description: "目标工作台 ID（UUID）")
    field(:enrollment_id, {:required, :string}, description: "待确认报名 ID（UUID，须为 pending）")
  end

  @impl true
  def execute(params, frame) do
    result =
      Wrapper.run(frame, params, "confirm_enrollment", fn actor, workspace_id, params ->
        enrollment_id = params["enrollment_id"] || params[:enrollment_id]

        with :ok <- authorize(actor, workspace_id),
             {:ok, enrollment} <- fetch_enrollment(actor, workspace_id, enrollment_id) do
          if enrollment.status != :pending do
            {:error, "该报名已被处理（当前状态：#{enrollment.status}），无需再确认"}
          else
            summary =
              "确认报名 #{enrollment.id}（报名人 #{enrollment.user_id}）：占用名额并审批通过。" <>
                "免费课程直接 confirmed；收费课程落 payment_pending（支付完成或免缴才真正 confirmed）"

            Confirmation.request(
              frame.assigns[:current_user],
              "confirm_enrollment",
              params,
              summary
            )
          end
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
    enrollment_id = params["enrollment_id"]

    with {:ok, enrollment} <- fetch_enrollment(actor, workspace_id, enrollment_id) do
      case enrollment
           |> Ash.Changeset.for_update(:confirm_enrollment, %{}, tenant: workspace_id)
           |> Ash.update(actor: actor, tenant: workspace_id) do
        {:ok, confirmed} ->
          {:ok,
           %{
             enrollment_id: confirmed.id,
             status: to_string(confirmed.status),
             user_id: confirmed.user_id,
             course_id: confirmed.course_id,
             approved_by: confirmed.approved_by,
             approved_at: confirmed.approved_at
           }}

        {:error, %Ash.Error.Forbidden{}} ->
          {:error,
           "forbidden: owner or admin required to confirm enrollments in workspace #{workspace_id}"}

        {:error, %Ash.Error.Invalid{} = err} ->
          {:error, Exception.message(err)}

        {:error, _} ->
          {:error, "failed to confirm enrollment"}
      end
    end
  end

  # Owner/Admin 专属（S3）：工具层管理角色判定，非管理角色成员快速拒绝
  defp authorize(actor, workspace_id) do
    if actor |> MembershipContext.role_names(workspace_id) |> Enum.any?(&Role.manage_role?/1) do
      :ok
    else
      {:error, "forbidden: owner or admin required to confirm enrollments"}
    end
  end

  # tenant 收紧报名归属：他租户 enrollment_id 与不存在同一「not found」，不泄露存在性
  defp fetch_enrollment(actor, workspace_id, enrollment_id) do
    case Ash.get(Enrollment, enrollment_id, actor: actor, tenant: workspace_id) do
      {:ok, nil} ->
        {:error, "enrollment not found"}

      {:ok, enrollment} ->
        {:ok, enrollment}

      {:error, %Ash.Error.Forbidden{}} ->
        {:error, "forbidden: not allowed to read enrollments of workspace #{workspace_id}"}

      {:error, _} ->
        {:error, "failed to load enrollment"}
    end
  end
end
