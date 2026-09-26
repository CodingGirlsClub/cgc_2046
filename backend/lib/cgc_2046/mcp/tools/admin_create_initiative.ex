defmodule Cgc2046.Mcp.Tools.AdminCreateInitiative do
  @moduledoc """
  平台管理员专用：创建倡导活动（Initiative），初始状态 draft。倡导活动是平台级主题活动，
  工作台的活动场次可以挂载到它下面并继承它的规则。创建后用 admin_upsert_initiative_rule
  配置规则，再用 admin_open_initiative 开放。

  走确认流：第一次调用不创建，返回 needs_confirmation + pending_id + summary；用户确认后
  调 confirm_operation(pending_id) 才真正创建。

  返回活动行：id / name / slug / url（公开页地址）/ hashtag / description /
  window_starts_at / window_ends_at / status / created_by / rules。
  """
  use Anubis.Server.Component,
    type: :tool,
    meta: %{workspace_id: :optional, membership: :platform_admin}

  alias Cgc2046.Initiatives.Initiative
  alias Cgc2046.Mcp.{Confirmation, Wrapper}
  alias Cgc2046.Mcp.Tools.AdminInitiativeHelpers, as: H

  schema do
    field(:name, {:required, :string}, description: "活动名称")
    field(:slug, {:required, :string}, description: "全局唯一 slug")
    field(:hashtag, :string, description: "话题标签，可省略")
    field(:description, :string, description: "活动简介，可省略")
    field(:window_starts_at, :string, description: "活动窗口开始时间（ISO8601），可省略")
    field(:window_ends_at, :string, description: "活动窗口结束时间（ISO8601），可省略")
  end

  @impl true
  def execute(params, frame) do
    result =
      Wrapper.run(frame, params, "admin_create_initiative", fn _actor, _ws, params ->
        summary = "创建倡导活动「#{params["name"]}」（slug #{params["slug"]}），初始状态 draft"

        Confirmation.request(
          frame.assigns[:current_user],
          "admin_create_initiative",
          params,
          summary
        )
      end)

    Cgc2046.Mcp.Tools.Response.to_response(result, frame)
  end

  @spec execute_confirmed(term(), map()) :: {:ok, map()} | {:error, String.t()}
  def execute_confirmed(actor, params) do
    attrs =
      H.attrs(params, ~w(name slug hashtag description)a)
      |> Map.merge(H.datetime_attrs(params))
      |> Map.put(:created_by, actor.id)

    case Initiative |> Ash.Changeset.for_create(:create, attrs) |> Ash.create(actor: actor) do
      {:ok, initiative} ->
        H.row(initiative, actor)

      {:error, error} ->
        {:error, Cgc2046.Mcp.Errors.message(error, "failed to create initiative")}
    end
  end
end
