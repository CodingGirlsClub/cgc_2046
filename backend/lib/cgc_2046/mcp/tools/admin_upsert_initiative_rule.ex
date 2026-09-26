defmodule Cgc2046.Mcp.Tools.AdminUpsertInitiativeRule do
  @moduledoc """
  平台管理员专用：为倡导活动新建或覆盖一条规则（同一 key 已有规则时覆盖）。规则决定挂载
  场次的参与条件：deposit（押金）/ age_gate（年龄门槛）/ min_participants（成班人数）/
  deadline_rule（报名截止）。locked=true：挂载的场次强制使用该值且不可修改；locked=false：
  挂载时按当时的值快照，之后场次可自行修改。

  走确认流：第一次调用返回 needs_confirmation + pending_id + summary，用户确认后调
  confirm_operation(pending_id) 才写入。返回活动行，另带 updated_rule（id / key / value / locked）。
  """
  use Anubis.Server.Component,
    type: :tool,
    meta: %{workspace_id: :optional, membership: :platform_admin}

  alias Cgc2046.Initiatives.{Initiative, InitiativeRule}
  alias Cgc2046.Mcp.{Confirmation, Wrapper}
  alias Cgc2046.Mcp.Tools.AdminInitiativeHelpers, as: H

  schema do
    field(:initiative_id, {:required, :string}, description: "倡导活动 ID（取自 admin_list_initiatives）")

    field(:key, {:required, :string},
      description: "deposit | age_gate | min_participants | deadline_rule"
    )

    field(:value_json, {:required, :string}, description: "规则值：JSON 对象的字符串形式（必须是对象）")
    field(:locked, {:required, :boolean}, description: "true = 挂载场次强制使用且不可改；false = 挂载时快照，之后可改")
  end

  @impl true
  def execute(params, frame) do
    result =
      Wrapper.run(frame, params, "admin_upsert_initiative_rule", fn actor, _ws, params ->
        with {:ok, key} <- H.rule_key(params["key"]),
             {:ok, _value} <- decode(params["value_json"]),
             {:ok, initiative} <- Ash.get(Initiative, params["initiative_id"], actor: actor),
             true <- not is_nil(initiative) do
          Confirmation.request(
            frame.assigns[:current_user],
            "admin_upsert_initiative_rule",
            Map.put(params, "key", Atom.to_string(key)),
            "更新倡导活动「#{initiative.name}」的 #{params["key"]} 规则（locked=#{params["locked"]}）"
          )
        else
          false -> {:error, "initiative not found"}
          {:error, message} when is_binary(message) -> {:error, message}
          {:error, _} -> {:error, "failed to load initiative"}
        end
      end)

    Cgc2046.Mcp.Tools.Response.to_response(result, frame)
  end

  @spec execute_confirmed(term(), map()) :: {:ok, map()} | {:error, String.t()}
  def execute_confirmed(actor, params) do
    with {:ok, key} <- H.rule_key(params["key"]),
         {:ok, value} <- decode(params["value_json"]),
         {:ok, initiative} <- Ash.get(Initiative, params["initiative_id"], actor: actor),
         true <- not is_nil(initiative),
         {:ok, existing} <- H.get_rule(params["initiative_id"], key, actor) do
      attrs = %{value: value, locked: params["locked"]}

      result =
        if existing do
          existing |> Ash.Changeset.for_update(:update, attrs) |> Ash.update(actor: actor)
        else
          InitiativeRule
          |> Ash.Changeset.for_create(
            :create,
            Map.merge(attrs, %{initiative_id: initiative.id, key: key})
          )
          |> Ash.create(actor: actor)
        end

      case result do
        {:ok, rule} ->
          H.row(initiative, actor) |> append_rule_result(rule)

        {:error, error} ->
          {:error, Cgc2046.Mcp.Errors.message(error, "failed to update initiative rule")}
      end
    else
      false -> {:error, "initiative not found"}
      {:error, message} when is_binary(message) -> {:error, message}
      {:error, _} -> {:error, "failed to load initiative rule"}
    end
  end

  defp append_rule_result({:ok, row}, rule),
    do: {:ok, Map.put(row, :updated_rule, H.rule_row(rule))}

  defp append_rule_result(error, _rule), do: error

  defp decode(value) do
    case Jason.decode(value) do
      {:ok, map} when is_map(map) -> {:ok, map}
      _ -> {:error, "value_json must be a JSON object"}
    end
  end
end
