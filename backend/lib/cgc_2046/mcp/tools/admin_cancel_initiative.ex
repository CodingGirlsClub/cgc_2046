defmodule Cgc2046.Mcp.Tools.AdminCancelInitiative do
  @moduledoc """
  平台管理员专用：中止倡导活动，状态改为 cancelled。这是终态，不可逆，恢复只能新建活动。
  会级联取消全部仍开放的挂载场次，这些场次的已付报名无条件全额退款；已结束或已取消的场次
  不改写。走确认流：第一次调用返回 needs_confirmation + pending_id + summary（含上述影响），
  用户确认后调 confirm_operation(pending_id) 才执行。返回更新后的活动行。
  """
  use Anubis.Server.Component,
    type: :tool,
    meta: %{workspace_id: :optional, membership: :platform_admin}

  alias Cgc2046.Initiatives.Initiative
  alias Cgc2046.Mcp.{Confirmation, Wrapper}
  alias Cgc2046.Mcp.Tools.AdminInitiativeHelpers, as: H

  schema do
    field(:initiative_id, {:required, :string}, description: "倡导活动 ID（取自 admin_list_initiatives）")
  end

  @impl true
  def execute(params, frame) do
    result =
      Wrapper.run(frame, params, "admin_cancel_initiative", fn actor, _ws, params ->
        case Ash.get(Initiative, params["initiative_id"], actor: actor) do
          {:ok, nil} ->
            {:error, "initiative not found"}

          {:ok, initiative} ->
            Confirmation.request(
              frame.assigns[:current_user],
              "admin_cancel_initiative",
              params,
              "中止倡导活动「#{initiative.name}」（#{initiative.id}）：#{initiative.status} → cancelled。" <>
                "将级联取消全部仍开放的挂载场次，其已付报名无条件全额退款；" <>
                "已结束/已取消的场次不改写。终态不可逆，恢复 = 新建活动"
            )

          {:error, _} ->
            {:error, "failed to load initiative"}
        end
      end)

    Cgc2046.Mcp.Tools.Response.to_response(result, frame)
  end

  @spec execute_confirmed(term(), map()) :: {:ok, map()} | {:error, String.t()}
  def execute_confirmed(actor, params) do
    case Ash.get(Initiative, params["initiative_id"], actor: actor) do
      {:ok, nil} ->
        {:error, "initiative not found"}

      {:ok, initiative} ->
        case initiative |> Ash.Changeset.for_update(:cancel, %{}) |> Ash.update(actor: actor) do
          {:ok, updated} ->
            H.row(updated, actor)

          {:error, error} ->
            {:error, Cgc2046.Mcp.Errors.message(error, "failed to cancel initiative")}
        end

      {:error, _} ->
        {:error, "failed to load initiative"}
    end
  end
end
