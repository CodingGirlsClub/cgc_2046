defmodule Cgc2046.Initiatives.RulePreview do
  @moduledoc """
  挂载前规则预览读面（#596）：Owner/Admin 可读某 Initiative 四项规则的值与锁态。

  与 `Public`（匿名公开投影）刻意分开：规则属平台治理数据（押金金额、年龄门槛、
  成班人数、报名截止策略），公开 DTO 不含、也不应含。

  权限立场（唯一门）：`Rbac.manage?/2` —— actor 必须是 `workspace_id` 工作台的
  Owner/Admin（多角色并集）。

  - **不向普通成员开放**：建场/挂载本身即 Owner/Admin 专属，预览没有别的消费者；
  - **不含 platform_admin 豁免**：平台管理员的规则治理读面是既有
    `admin_get_initiative`（MCP 平台治理族），与 `Cgc2046.Mcp.Wrapper` moduledoc
    的「双面契约」一致——管理类能力不因平台管理员豁免；
  - **先判权再读库**：无权者即使传不存在的 initiative_id 也只得 forbidden，不泄露存在性。

  返回规则**原始值**（不是 Event 字段投影）：`locked: true` = 挂载后强制写入且不可改；
  `locked: false` = 挂载那一刻按当时取值快照，之后 Event 侧可改。`missing_rules`
  非空表示规则未配齐——挂载会被域拒绝，提前可见。
  """

  alias Cgc2046.Accounts.Rbac
  alias Cgc2046.Initiatives.{InitiativeRule, RuleInheritance}
  alias Cgc2046.Repo

  @rule_keys InitiativeRule.rule_keys()

  @type preview :: %{
          initiative_id: String.t(),
          name: String.t(),
          slug: String.t(),
          status: String.t(),
          rules: [%{key: String.t(), value: map(), locked: boolean()}],
          missing_rules: [String.t()]
        }

  @spec get(String.t() | nil, term(), String.t() | nil) ::
          {:ok, preview()} | {:error, :forbidden | :not_found | :failed}
  def get(initiative_id, actor, workspace_id) do
    if Rbac.manage?(actor, workspace_id) do
      do_get(initiative_id)
    else
      {:error, :forbidden}
    end
  end

  defp do_get(initiative_id) do
    with {:ok, initiative} <- fetch_initiative(initiative_id),
         {:ok, rules} <- RuleInheritance.rules_for(initiative.id) do
      missing = Enum.reject(@rule_keys, &Map.has_key?(rules, &1))

      {:ok,
       %{
         initiative_id: initiative.id,
         name: initiative.name,
         slug: initiative.slug,
         status: initiative.status,
         rules:
           Enum.flat_map(@rule_keys, fn key ->
             case Map.get(rules, key) do
               nil -> []
               rule -> [%{key: to_string(key), value: rule.value, locked: rule.locked}]
             end
           end),
         missing_rules: Enum.map(missing, &to_string/1)
       }}
    else
      # rules_for/1 的读失败是字符串错误（load_rules/1 原样透出）；本模块对外只
      # 承诺 :forbidden | :not_found | :failed 三态，归一后再交给消费面
      {:error, :not_found} -> {:error, :not_found}
      {:error, _reason} -> {:error, :failed}
    end
  end

  defp fetch_initiative(initiative_id) do
    case Ecto.UUID.cast(initiative_id) do
      {:ok, uuid} ->
        case Repo.query("SELECT id, name, slug, status FROM initiatives WHERE id = $1", [
               Ecto.UUID.dump!(uuid)
             ]) do
          {:ok, %{rows: [[id, name, slug, status]]}} ->
            {:ok, %{id: Ecto.UUID.load!(id), name: name, slug: slug, status: status}}

          {:ok, %{rows: []}} ->
            {:error, :not_found}

          {:error, _reason} ->
            {:error, :failed}
        end

      :error ->
        {:error, :not_found}
    end
  end
end
