defmodule Cgc2046.Mcp.Tools.AdminApproveWorkspaceApplication do
  @moduledoc """
  平台治理：批准工作台创建申请（role-agent-journeys-v2 S2，确认流
  two-tool 写，D-D3）。

  第一次调用：不落业务库，建 PendingOperation，返回 needs_confirmation。
  用户确认后 agent 调 `confirm_operation(pending_id)` → `execute_confirmed/2`
  真正执行 `WorkspaceApplication.approve`（platform_admin 专属 action：
  原子条件 UPDATE 抢占 + 事务内创建 workspace + 申请人入座 Owner +
  治理留痕 application_approve）。

  授权 = Wrapper `:platform_admin` 门控族（第一段快速拒绝省 pending）；
  confirm 段由 approve action 的 `Policies.PlatformAdmin` policy 兜底
  （管理员标记可能在确认窗口内被撤——两段式快速失败纪律 §B#7）。
  """
  use Anubis.Server.Component,
    type: :tool,
    meta: %{workspace_id: :optional, membership: :platform_admin}

  alias Cgc2046.Accounts.WorkspaceApplication
  alias Cgc2046.Mcp.Confirmation
  alias Cgc2046.Mcp.Wrapper

  schema do
    field(:application_id, {:required, :string},
      description: "待批准的工作台创建申请 ID（UUID，可从 admin_list_workspace_applications 获取）"
    )
  end

  @impl true
  def execute(params, frame) do
    result =
      Wrapper.run(frame, params, "admin_approve_workspace_application", fn actor,
                                                                           _workspace_id,
                                                                           params ->
        application_id = params["application_id"] || params[:application_id]

        with {:ok, application} <- fetch_application(actor, application_id) do
          # 非终态快速失败：已处理申请不值得建 pending（终态/过期的并发拦截仍由
          # approve 的原子 claim 在 confirm 段兜底）
          if application.status != :pending do
            {:error, "该申请已被处理（当前状态：#{application.status}），无需再批准"}
          else
            summary =
              "批准工作台创建申请 #{application.id}：创建 workspace「#{application.name}」" <>
                "（slug #{application.slug}），申请人 #{application.applicant_id} 自动入座 Owner"

            Confirmation.request(
              frame.assigns[:current_user],
              "admin_approve_workspace_application",
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
           |> Ash.Changeset.for_update(:approve, %{})
           |> Ash.update(actor: actor) do
        {:ok, approved} ->
          {:ok,
           %{
             application_id: approved.id,
             status: to_string(approved.status),
             applicant_id: approved.applicant_id,
             workspace_name: approved.name,
             workspace_slug: approved.slug
           }}

        {:error, %Ash.Error.Forbidden{}} ->
          {:error, "forbidden: platform admin required to approve workspace applications"}

        {:error, %Ash.Error.Invalid{} = err} ->
          {:error, Exception.message(err)}

        {:error, _} ->
          {:error, "failed to approve workspace application"}
      end
    end
  end

  # 全局资源（无 tenant）；read policy 放行 platform_admin 读全部申请
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
