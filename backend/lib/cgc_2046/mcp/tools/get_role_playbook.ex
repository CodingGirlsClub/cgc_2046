defmodule Cgc2046.Mcp.Tools.GetRolePlaybook do
  @moduledoc """
  按角色分发 playbook（role-agent-journeys-v2 S1，R2/R6；任务指令模式 D10 的 v1 通道）。

  授权在工具层（meta `%{workspace_id: :optional, membership: :deferred}` 双键命中
  Wrapper `:optional` 分支——playbook 读取是 actor 锚定的跨工作台读，无单一
  workspace 门；map 子集匹配下 `:optional` 子句先于 `:deferred` 命中，子句顺序即
  语义，wrapper_gate_test 钉死）：

  - `learner`：任何已认证用户；
  - `tutor`：要求在 workspace_id 所指工作台持有 tutor、owner 或 admin 角色
    （workspace_id 必填）；
  - `workspace_admin`：要求在该工作台持有 owner 或 admin 角色（workspace_id 必填）；
  - `platform_admin`：要求 `is_platform_admin` 全局标记（与具体工作台无关，workspace_id 不适用）。

  playbook 只组织用户已有能力，不扩大网站 RBAC 权限（R6）。未知 role → 错误并
  列明合法角色；授权拒绝一律 `"forbidden: ..."` 前缀（Wrapper 据此把审计行归为
  forbidden）。
  """
  use Anubis.Server.Component,
    type: :tool,
    meta: %{workspace_id: :optional, membership: :deferred}

  alias Cgc2046.Accounts.MembershipContext
  alias Cgc2046.Accounts.Policies.PlatformAdmin
  alias Cgc2046.Accounts.Role
  alias Cgc2046.Curriculum.Prep
  alias Cgc2046.Mcp.Playbooks
  alias Cgc2046.Mcp.Wrapper

  schema do
    field(:role, {:required, :string},
      description: "目标角色：learner | tutor | workspace_admin | platform_admin"
    )

    field(:workspace_id, :string,
      description: "目标工作台 ID（UUID）；tutor / workspace_admin 必填，learner / platform_admin 不适用"
    )
  end

  @impl true
  def execute(params, frame) do
    result =
      Wrapper.run(frame, params, "get_role_playbook", fn actor, workspace_id, params ->
        role_param = params["role"] || params[:role]

        with {:ok, playbook} <- Playbooks.fetch(role_param),
             :ok <- authorize(playbook.role, actor, workspace_id) do
          {:ok, playbook}
        else
          {:error, :unknown_role} ->
            valid = Playbooks.roles() |> Enum.map_join(", ", &to_string/1)
            {:error, "unknown role: #{inspect(role_param)}; valid roles: #{valid}"}

          {:error, message} when is_binary(message) ->
            {:error, message}
        end
      end)

    Cgc2046.Mcp.Tools.Response.to_response(result, frame)
  end

  defp authorize(:learner, _actor, _workspace_id), do: :ok

  defp authorize(:platform_admin, actor, _workspace_id) do
    if PlatformAdmin.platform_admin?(actor) do
      :ok
    else
      {:error, "forbidden: platform_admin playbook requires platform admin"}
    end
  end

  defp authorize(:tutor, actor, workspace_id) do
    with {:ok, workspace_id} <- require_workspace_id(workspace_id, :tutor) do
      if Prep.tutor?(actor, workspace_id) or Prep.manage?(actor, workspace_id) do
        :ok
      else
        {:error,
         "forbidden: tutor, owner or admin required to read tutor playbook in workspace #{workspace_id}"}
      end
    end
  end

  defp authorize(:workspace_admin, actor, workspace_id) do
    with {:ok, workspace_id} <- require_workspace_id(workspace_id, :workspace_admin) do
      roles = MembershipContext.role_names(actor, workspace_id)

      if Enum.any?(roles, &Role.manage_role?/1) do
        :ok
      else
        {:error,
         "forbidden: workspace_admin playbook requires owner/admin role in workspace #{workspace_id}"}
      end
    end
  end

  defp require_workspace_id(workspace_id, _role) when is_binary(workspace_id),
    do: {:ok, workspace_id}

  defp require_workspace_id(_workspace_id, role),
    do: {:error, "workspace_id is required for role #{role}"}
end
