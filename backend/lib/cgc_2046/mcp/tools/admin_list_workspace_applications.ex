defmodule Cgc2046.Mcp.Tools.AdminListWorkspaceApplications do
  @moduledoc """
  平台治理：工作台创建申请列表（role-agent-journeys-v2 S2，R12–R16 的 MCP 面）。

  数据面同 GraphQL `listWorkspaceApplications`：status 过滤（默认 pending），
  按 inserted_at 倒序，封顶 50 条，附申请人概要。授权 = Wrapper
  `:platform_admin` 门控族 + WorkspaceApplication read policy 的
  platform_admin 放行兜底。

  返回紧凑申请概要（application_id / name / slug / purpose / status /
  applicant（id/email/display_name）/ 审批四字段 / 时间戳）。
  """
  use Anubis.Server.Component,
    type: :tool,
    meta: %{workspace_id: :optional, membership: :platform_admin}

  alias Cgc2046.Accounts.WorkspaceApplication
  alias Cgc2046.Mcp.Wrapper

  require Ash.Query

  @statuses ~w(pending approved rejected expired)
  @limit 50

  schema do
    field(:status, :string, description: "按状态过滤（pending|approved|rejected|expired，默认 pending）")
  end

  @impl true
  def execute(params, frame) do
    result =
      Wrapper.run(frame, params, "admin_list_workspace_applications", fn actor,
                                                                         _workspace_id,
                                                                         params ->
        status = params["status"] || params[:status] || "pending"

        with {:ok, status} <- parse_status(status) do
          status_atom = String.to_existing_atom(status)

          WorkspaceApplication
          |> Ash.Query.for_read(:read)
          |> Ash.Query.filter(status == ^status_atom)
          |> Ash.Query.load(:applicant)
          |> Ash.Query.sort(inserted_at: :desc, id: :desc)
          |> Ash.Query.limit(@limit)
          |> Ash.read(actor: actor)
          |> case do
            {:ok, applications} ->
              {:ok,
               %{
                 status: status,
                 count: length(applications),
                 applications: Enum.map(applications, &to_row/1)
               }}

            {:error, %Ash.Error.Forbidden{}} ->
              {:error, "forbidden: platform admin required to list workspace applications"}

            {:error, _} ->
              {:error, "failed to list workspace applications"}
          end
        end
      end)

    Cgc2046.Mcp.Tools.Response.to_response(result, frame)
  end

  # 白名单校验后才 to_existing_atom（不污染 atom 表）
  defp parse_status(status) when status in @statuses, do: {:ok, status}

  defp parse_status(_status),
    do: {:error, "invalid status (expected one of #{Enum.join(@statuses, "|")})"}

  defp to_row(application) do
    %{
      application_id: application.id,
      name: application.name,
      slug: application.slug,
      purpose: application.purpose,
      status: to_string(application.status),
      applicant: applicant_row(application.applicant),
      rejection_reason: application.rejection_reason,
      approval_deadline: application.approval_deadline,
      approved_at: application.approved_at,
      rejected_at: application.rejected_at,
      inserted_at: application.inserted_at
    }
  end

  defp applicant_row(nil), do: nil

  defp applicant_row(applicant) do
    %{
      id: applicant.id,
      email: applicant.email && to_string(applicant.email),
      display_name: applicant.display_name
    }
  end
end
