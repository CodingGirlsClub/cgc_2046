defmodule Cgc2046.Mcp.Tools.AdminRejectWorkspaceApplication do
  @moduledoc """
  平台治理：拒绝工作台创建申请（role-agent-journeys-v2 S2，确认流
  two-tool 写，D-D3）。

  第一次调用：不落业务库，建 PendingOperation，返回 needs_confirmation。
  用户确认后 agent 调 `confirm_operation(pending_id)` → `execute_confirmed/2`
  真正执行 `WorkspaceApplication.reject`（platform_admin 专属 action：
  状态守卫 pending-only + 落拒绝人/时间 + 治理留痕 application_reject）。

  授权 = Wrapper `:platform_admin` 门控族（第一段快速拒绝省 pending）；
  confirm 段由 reject action 的 `Policies.PlatformAdmin` policy 兜底。
  """
  use Anubis.Server.Component,
    type: :tool,
    meta: %{workspace_id: :optional, membership: :platform_admin}

  alias Cgc2046.Accounts.WorkspaceApplication
  alias Cgc2046.Mcp.Confirmation
  alias Cgc2046.Mcp.Wrapper

  schema do
    field(:application_id, {:required, :string},
      description: "待拒绝的工作台创建申请 ID（UUID，可从 admin_list_workspace_applications 获取）"
    )

    field(:rejection_reason, :string, description: "拒绝原因（可选，会展示给申请人）")
  end

  @impl true
  def execute(params, frame) do
    result =
      Wrapper.run(frame, params, "admin_reject_workspace_application", fn actor,
                                                                          _workspace_id,
                                                                          params ->
        application_id = params["application_id"] || params[:application_id]
        reason = params["rejection_reason"] || params[:rejection_reason]

        with {:ok, application} <- fetch_application(actor, application_id) do
          # 非终态快速失败（与 admin_approve_workspace_application 同款纪律）
          if application.status != :pending do
            {:error, "该申请已被处理（当前状态：#{application.status}），无需再拒绝"}
          else
            summary =
              "拒绝工作台创建申请 #{application.id}（#{application.name} / " <>
                "#{application.slug}，申请人 #{application.applicant_id}）" <>
                reason_summary(reason)

            Confirmation.request(
              frame.assigns[:current_user],
              "admin_reject_workspace_application",
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
    with {:ok, application} <- fetch_application(actor, params["application_id"]) do
      case application
           |> Ash.Changeset.for_update(:reject, %{
             rejection_reason: params["rejection_reason"]
           })
           |> Ash.update(actor: actor) do
        {:ok, rejected} ->
          {:ok,
           %{
             application_id: rejected.id,
             status: to_string(rejected.status),
             applicant_id: rejected.applicant_id,
             rejection_reason: rejected.rejection_reason
           }}

        {:error, %Ash.Error.Forbidden{}} ->
          {:error, "forbidden: platform admin required to reject workspace applications"}

        {:error, %Ash.Error.Invalid{} = err} ->
          {:error, Exception.message(err)}

        {:error, _} ->
          {:error, "failed to reject workspace application"}
      end
    end
  end

  defp reason_summary(nil), do: "（未填拒绝原因）"
  defp reason_summary(reason), do: "，拒绝原因：#{reason}"

  defp fetch_application(actor, application_id) do
    case Ash.get(WorkspaceApplication, application_id, actor: actor) do
      {:ok, nil} ->
        {:error, "workspace application not found"}

      {:ok, application} ->
        {:ok, application}

      {:error, %Ash.Error.Forbidden{}} ->
        {:error, "forbidden: not allowed to read workspace application #{application_id}"}

      {:error, _} ->
        {:error, "failed to load workspace application"}
    end
  end
end
