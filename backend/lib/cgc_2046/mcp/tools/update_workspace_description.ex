defmodule Cgc2046.Mcp.Tools.UpdateWorkspaceDescription do
  @moduledoc """
  更新工作台简介（#1226，Owner/Admin 管理工具，确认流 two-tool 写，D-D3）。

  语义对齐 GraphQL `updateWorkspace`（同 `Accounts.Workspace :update` action，本
  工具只放行 `description` 一个属性）：工作台门面文案（公开展示），帮助成员与访客
  识别这个工作台做什么。`""` 归一为 `nil`（清空）；首尾空白去除。字段本身无长度
  约束（与 course/event 的 description 同款），长度治理在展示层。

  授权：**不新增 RBAC 能力**——工具层用 `Rbac.manage?/2`（与 update_join_policy
  同款快速拒绝），confirm 段由 `Workspace :update` 的 Owner/Admin ∪ 平台管理员
  policy 兜底。web 设置页把 `update_join_policy` 当作「工作台设置管理」能力门
  （settings/general），本工具沿用同一口径。

  第一次调用：不落业务库，建 PendingOperation，返回 needs_confirmation。
  """

  use Anubis.Server.Component, type: :tool, scopes: ["workspace_admin"]

  alias Cgc2046.Accounts.{Rbac, Workspace}
  alias Cgc2046.Mcp.{Confirmation, Wrapper}

  # 确认摘要里的简介预览上限（字符）：卡片只展示可读片段；全文落
  # PendingOperation.params（two-tool 事务数据，不截断），审计路径由 Redact 另行
  # 截断（1KB/值）——三处分工不同，不要互相取代。
  @preview_chars 80

  # 发给调用方 agent 的工具描述（只写契约）；@moduledoc 留给维护者
  @impl true
  def description do
    """
    工作台 Owner/Admin 专用：修改工作台简介（公开展示文案，用来说明这个工作台是什么、面向谁）。
    传空字符串表示清空简介；首尾空白会被去掉。
    走确认流：第一次调用只返回 needs_confirmation + pending_id + summary，
    用户确认后调 confirm_operation(pending_id) 才执行。
    """
  end

  schema do
    field(:workspace_id, {:required, :string}, description: "目标工作台 ID（UUID）")

    field(:description, {:required, :string}, description: "新的工作台简介（公开展示文案；空字符串 = 清空）")
  end

  @impl true
  def execute(params, frame) do
    result =
      Wrapper.run(frame, params, "update_workspace_description", fn actor, workspace_id, params ->
        with :ok <- authorize(actor, workspace_id),
             {:ok, description} <- normalize(params["description"]),
             {:ok, workspace} <- fetch_workspace(actor, workspace_id) do
          summary =
            "将工作台「#{workspace.name}」（#{workspace.id}）简介：" <>
              "#{preview(workspace.description)} → #{preview(description)}"

          # pending 落**归一后**的值：确认段执行的必须与摘要展示的是同一份文本。
          Confirmation.request(
            frame.assigns[:current_user],
            "update_workspace_description",
            %{"workspace_id" => workspace_id, "description" => description},
            summary
          )
        end
      end)

    Cgc2046.Mcp.Tools.Response.to_response(result, frame)
  end

  @doc """
  确认后真正执行（由 `Confirmation.execute/3` 直接分派调用）。
  params 为 pending 落库的参数（本工具参数无敏感键，直接可用）。
  """
  @spec execute_confirmed(term(), map()) :: {:ok, map()} | {:error, String.t()}
  def execute_confirmed(actor, params) do
    workspace_id = params["workspace_id"]

    with {:ok, description} <- normalize(params["description"]),
         {:ok, workspace} <- fetch_workspace(actor, workspace_id) do
      previous_description = workspace.description

      case workspace
           |> Ash.Changeset.for_update(:update, %{description: description})
           |> Ash.update(actor: actor) do
        {:ok, updated} ->
          {:ok,
           %{
             workspace_id: updated.id,
             description: updated.description,
             previous_description: previous_description
           }}

        {:error, %Ash.Error.Forbidden{}} ->
          {:error, "forbidden: owner or admin required to update description of #{workspace_id}"}

        {:error, err} ->
          {:error, Cgc2046.Mcp.Errors.message(err, "failed to update workspace description")}
      end
    end
  end

  # Owner/Admin 专属：工具层管理角色判定，非管理角色成员快速拒绝（省 pending）。
  # 不新增能力名：web 设置页已把 update_join_policy 作为「工作台设置管理」门。
  defp authorize(actor, workspace_id) do
    if Rbac.manage?(actor, workspace_id) do
      :ok
    else
      {:error, "forbidden: owner or admin required to update workspace description"}
    end
  end

  # 空串（含纯空白）= 清空（落 nil）；非空去首尾空白后照写。
  # nil 是「确认段读回已归一为清空」的合法值（缺参在 execute 段已被
  # schema 的 {:required, :string} 拦下，不会走到这里）。
  defp normalize(nil), do: {:ok, nil}

  defp normalize(description) when is_binary(description) do
    case String.trim(description) do
      "" -> {:ok, nil}
      trimmed -> {:ok, trimmed}
    end
  end

  defp normalize(_description), do: {:error, "invalid description (expected a string)"}

  # 摘要预览：截断只为卡片可读性，净化（控制字符/2000 字封顶）由
  # Confirmation.request 单点完成。
  defp preview(nil), do: "（空）"

  defp preview(text) when is_binary(text) do
    length = String.length(text)

    body =
      if length > @preview_chars do
        String.slice(text, 0, @preview_chars) <> "…"
      else
        text
      end

    "「#{body}」（共 #{length} 字）"
  end

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
end
