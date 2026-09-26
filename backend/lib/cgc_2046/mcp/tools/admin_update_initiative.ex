defmodule Cgc2046.Mcp.Tools.AdminUpdateInitiative do
  @moduledoc """
  平台管理员专用：修改倡导活动的元数据（name / slug / hashtag / description /
  window_starts_at / window_ends_at）。只传要改的字段，未传的保持不变；一个字段都不传会报错。
  状态用 admin_open_initiative / admin_close_initiative / admin_cancel_initiative 改，规则用
  admin_upsert_initiative_rule 改，本工具都不涉及。

  走确认流：第一次调用返回 needs_confirmation + pending_id + summary，用户确认后调
  confirm_operation(pending_id) 才生效。返回更新后的活动行（字段同 admin_get_initiative）。
  """
  use Anubis.Server.Component,
    type: :tool,
    meta: %{workspace_id: :optional, membership: :platform_admin}

  alias Cgc2046.Initiatives.Initiative
  alias Cgc2046.Mcp.{Confirmation, Wrapper}
  alias Cgc2046.Mcp.Tools.AdminInitiativeHelpers, as: H

  schema do
    field(:initiative_id, {:required, :string}, description: "倡导活动 ID（取自 admin_list_initiatives）")
    field(:name, :string, description: "新名称")
    field(:slug, :string, description: "新 slug（全局唯一）")
    field(:hashtag, :string, description: "新话题标签")
    field(:description, :string, description: "新简介")
    field(:window_starts_at, :string, description: "新的窗口开始时间（ISO8601）")
    field(:window_ends_at, :string, description: "新的窗口结束时间（ISO8601）")
  end

  @impl true
  def execute(params, frame) do
    result =
      Wrapper.run(frame, params, "admin_update_initiative", fn actor, _ws, params ->
        case Ash.get(Initiative, params["initiative_id"], actor: actor) do
          {:ok, nil} ->
            {:error, "initiative not found"}

          {:ok, initiative} ->
            fields =
              H.attrs(params, ~w(name slug hashtag description)a)
              |> Map.merge(H.datetime_attrs(params))

            if map_size(fields) == 0 do
              {:error, "at least one initiative field is required"}
            else
              summary =
                "更新倡导活动「#{initiative.name}」（#{initiative.id}）的元数据字段：#{Map.keys(fields) |> Enum.join(", ")}"

              Confirmation.request(
                frame.assigns[:current_user],
                "admin_update_initiative",
                params,
                summary
              )
            end

          {:error, _} ->
            {:error, "failed to load initiative"}
        end
      end)

    Cgc2046.Mcp.Tools.Response.to_response(result, frame)
  end

  @spec execute_confirmed(term(), map()) :: {:ok, map()} | {:error, String.t()}
  def execute_confirmed(actor, params) do
    with {:ok, initiative} <- Ash.get(Initiative, params["initiative_id"], actor: actor) do
      attrs =
        H.attrs(params, ~w(name slug hashtag description)a)
        |> Map.merge(H.datetime_attrs(params))

      case initiative |> Ash.Changeset.for_update(:update, attrs) |> Ash.update(actor: actor) do
        {:ok, updated} ->
          H.row(updated, actor)

        {:error, error} ->
          {:error, Cgc2046.Mcp.Errors.message(error, "failed to update initiative")}
      end
    else
      {:error, _} -> {:error, "failed to load initiative"}
    end
  end
end
