defmodule Cgc2046.Mcp.Tools.UpdateJoinPolicy do
  @moduledoc """
  更新工作台加入策略（role-agent-journeys-v2 S3，Owner/Admin 管理工具，确认流
  two-tool 写，D-D3）。

  语义对齐 GraphQL updateWorkspace（同 `Accounts.Workspace :update` action，本
  工具只放行 `join_policy` 一个属性）：open（公开直接加入）/ request（公开
  申请审批）/ invite_only（私密仅邀请）。#78 能力 :update_join_policy，
  Owner/Admin（多角色并集）可改；本工具将该能力从 web 设置页重开到 MCP
  （R18 真实 agent-first 需求坐实）。

  第一次调用：不落业务库，建 PendingOperation，返回 needs_confirmation。
  Owner/Admin 专属：默认 fail-closed member 门 + 工具层管理角色判定（第一段
  快速拒绝省 pending）；confirm 段由 update policy 兜底。
  """
  use Anubis.Server.Component, type: :tool

  alias Cgc2046.Accounts.{MembershipContext, Role, Workspace}
  alias Cgc2046.Mcp.{Confirmation, Wrapper}

  @join_policies ~w(open request invite_only)

  @policy_descriptions %{
    "open" => "公开直接加入",
    "request" => "公开申请审批",
    "invite_only" => "私密仅邀请"
  }

  schema do
    field(:workspace_id, {:required, :string}, description: "目标工作台 ID（UUID）")

    field(:join_policy, {:required, :string},
      description: "加入策略：open 公开直接加入 / request 公开申请审批 / invite_only 私密仅邀请"
    )
  end

  @impl true
  def execute(params, frame) do
    result =
      Wrapper.run(frame, params, "update_join_policy", fn actor, workspace_id, params ->
        join_policy = params["join_policy"] || params[:join_policy]

        with :ok <- authorize(actor, workspace_id),
             {:ok, join_policy} <- parse_join_policy(join_policy),
             {:ok, workspace} <- fetch_workspace(actor, workspace_id) do
          summary =
            "将工作台「#{workspace.name}」（#{workspace.id}）加入策略：" <>
              "#{workspace.join_policy}（#{describe(to_string(workspace.join_policy))}）→ " <>
              "#{join_policy}（#{describe(join_policy)}）"

          Confirmation.request(
            frame.assigns[:current_user],
            "update_join_policy",
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

    with {:ok, join_policy} <- parse_join_policy(params["join_policy"]),
         {:ok, workspace} <- fetch_workspace(actor, workspace_id) do
      case workspace
           |> Ash.Changeset.for_update(:update, %{
             join_policy: String.to_existing_atom(join_policy)
           })
           |> Ash.update(actor: actor) do
        {:ok, updated} ->
          {:ok,
           %{
             workspace_id: updated.id,
             join_policy: to_string(updated.join_policy)
           }}

        {:error, %Ash.Error.Forbidden{}} ->
          {:error, "forbidden: owner or admin required to update join policy of #{workspace_id}"}

        {:error, %Ash.Error.Invalid{} = err} ->
          {:error, Exception.message(err)}

        {:error, _} ->
          {:error, "failed to update join policy"}
      end
    end
  end

  # Owner/Admin 专属（S3）：工具层管理角色判定，非管理角色成员快速拒绝
  defp authorize(actor, workspace_id) do
    if actor |> MembershipContext.role_names(workspace_id) |> Enum.any?(&Role.manage_role?/1) do
      :ok
    else
      {:error, "forbidden: owner or admin required to update join policy"}
    end
  end

  # 白名单校验后才 to_existing_atom（confirm 段同款，不污染 atom 表）
  defp parse_join_policy(join_policy) when join_policy in @join_policies, do: {:ok, join_policy}

  defp parse_join_policy(_join_policy),
    do: {:error, "invalid join_policy (expected one of #{Enum.join(@join_policies, "|")})"}

  defp fetch_workspace(actor, workspace_id) do
    case Ash.get(Workspace, workspace_id, actor: actor) do
      {:ok, nil} ->
        {:error, "workspace not found"}

      {:ok, workspace} ->
        {:ok, workspace}

      {:error, %Ash.Error.Forbidden{}} ->
        {:error, "forbidden: not allowed to read workspace #{workspace_id}"}

      {:error, _} ->
        {:error, "failed to load workspace"}
    end
  end

  defp describe(policy), do: Map.get(@policy_descriptions, policy, policy)
end
