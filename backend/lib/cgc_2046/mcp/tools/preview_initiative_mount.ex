defmodule Cgc2046.Mcp.Tools.PreviewInitiativeMount do
  @moduledoc """
  挂载前预览 Initiative 四项规则的值与锁态（#596，Owner/Admin 专属，直接读）。

  用途：`create_event` / `update_event` 带 `initiative_id` **之前**，把「挂上去会
  发生什么」如实复述给用户。`locked: true`（平台锁死）的规则会在挂载后强制写入
  Event 且此后不可改；`locked: false`（默认规则）只在挂载那一刻按当时取值快照，
  之后 Event 侧可改。`create_event` / `update_event` 的响应另有 `inherited`
  回传「本次实际生效」的字段与来源。

  规则键与作用字段（四键封闭，逐一对应）：

  - `deposit` → `deposit_enabled` / `deposit_amount_cents`（押金开关与金额；开启时
    与定价互斥，已开定价的场会被拒绝）
  - `age_gate` → `min_age`（年龄门槛）
  - `min_participants` → `min_participants`（最小成班人数）
  - `deadline_rule` → `registration_deadline`（报名截止 = 开始前
    `hours_before_start` 小时）

  `missing_rules` 非空表示规则未配齐——挂载会被域拒绝，先补规则再挂；`status`
  非 `open` 的 Initiative 同样不能挂载。

  权限：member-only 门（非成员 forbidden）+ 工具层 Owner/Admin 判定。**普通成员
  看不到规则**（建场/挂载本身即 Owner/Admin 专属）；平台管理员读规则走
  `admin_get_initiative`，本工具不设 platform_admin 豁免（双面契约）。
  """
  use Anubis.Server.Component, type: :tool

  alias Cgc2046.Accounts.Rbac
  alias Cgc2046.Initiatives.RulePreview
  alias Cgc2046.Mcp.Wrapper

  schema do
    field(:workspace_id, {:required, :string}, description: "目标工作台 ID（UUID；仅用于权限判定）")

    field(:initiative_id, {:required, :string},
      description: "待挂载的 Initiative UUID（从 list_public_initiatives / get_public_initiative 取）"
    )
  end

  @impl true
  def execute(params, frame) do
    result =
      Wrapper.run(frame, params, "preview_initiative_mount", fn actor, workspace_id, params ->
        with :ok <- authorize(actor, workspace_id) do
          case RulePreview.get(params["initiative_id"], actor, workspace_id) do
            {:ok, preview} -> {:ok, payload(preview)}
            {:error, :not_found} -> {:error, "initiative not found: #{params["initiative_id"]}"}
            {:error, _} -> {:error, "failed to load initiative rules"}
          end
        end
      end)

    Cgc2046.Mcp.Tools.Response.to_response(result, frame)
  end

  # Owner/Admin 专属（与 create_event 同款第一段快速失败，错误以 forbidden 开头供审计分类）
  defp authorize(actor, workspace_id) do
    if Rbac.manage?(actor, workspace_id) do
      :ok
    else
      {:error, "forbidden: owner or admin required to preview initiative rules"}
    end
  end

  # agent 面按规则键成 map（比列表更好按 key 取用），缺失项单列
  defp payload(preview) do
    %{
      initiative: %{
        id: preview.initiative_id,
        name: preview.name,
        slug: preview.slug,
        status: preview.status
      },
      rules:
        Map.new(preview.rules, fn rule ->
          {rule.key, %{value: rule.value, locked: rule.locked}}
        end),
      missing_rules: preview.missing_rules
    }
  end
end
