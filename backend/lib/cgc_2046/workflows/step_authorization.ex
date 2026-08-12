defmodule Cgc2046.Workflows.StepAuthorization do
  @moduledoc """
  Step 执行角色授权判定（#38 语义从 Engine 剥离；ADR-0003「审批策略外置」）。

  判定 = actor 角色集合 ∩ step 执行角色集合，命中即放行（多角色并集）。
  owner/admin 豁免（管理角色类，机制委托 `Role.manage_role?/1`，单源 `Role.manage_roles/0`）。
  Step/StepRole 未配置 = 不限制。

  ## fail-closed（2026-08-07 用户决策）

  配置读取失败 = 拒绝：`step_allowed_roles/3` 返回标签元组 `{:ok, [atom]} | {:error, term}`，
  读失败与「未配置」在类型层面区分，不再混为一谈（旧 Engine 实现 `_ -> []` 把读失败
  当未配置放行）。读失败 → `{:error, :authorization_unavailable}`。

  owner/admin 豁免在读取前短路（`authorize_signal/5`），不触发配置读取，不受
  fail-closed 影响——豁免是领域规则，与配置存在与否无关。
  """

  alias Cgc2046.Accounts.MembershipContext
  alias Cgc2046.Accounts.Role
  alias Cgc2046.Workflows.Step
  alias Cgc2046.Workflows.StepRole

  require Ash.Query

  @type step_roles_result :: {:ok, [atom]} | {:error, term}

  @doc """
  IO 入口：查 actor 在目标工作台的角色 + step 执行角色配置，委托纯判定。

  返回 `:ok` 或 `{:error, :unauthorized | :authorization_unavailable}`。
  """
  @spec authorize_signal(term(), String.t(), String.t(), String.t()) ::
          :ok | {:error, :unauthorized | :authorization_unavailable}
  def authorize_signal(actor, workspace_id, definition_id, step_key)
      when is_binary(workspace_id) and is_binary(definition_id) and is_binary(step_key) do
    authorize_signal(actor, workspace_id, definition_id, step_key, &step_allowed_roles/3)
  end

  @doc false
  # 测试缝：注入 step_allowed_roles，覆盖「读失败 → 拒绝」接线（评审点 2）。
  @spec authorize_signal(
          term(),
          String.t(),
          String.t(),
          String.t(),
          (String.t(), String.t(), String.t() -> step_roles_result)
        ) :: :ok | {:error, :unauthorized | :authorization_unavailable}
  def authorize_signal(actor, workspace_id, definition_id, step_key, fetch_step_allowed_roles)
      when is_function(fetch_step_allowed_roles, 3) do
    roles = MembershipContext.role_names(actor, workspace_id)

    # owner/admin 豁免在读取 step 配置前短路（旧 Engine 语义）：豁免是领域规则，
    # 豁免集单源为 Role.manage_roles/0（经 Role.manage_role?/1），
    # 不依赖 StepRole 配置，也不该被配置读取失败（fail-closed）波及。
    if Enum.any?(roles, &Role.manage_role?/1) do
      :ok
    else
      authorize_roles(roles, fetch_step_allowed_roles.(workspace_id, definition_id, step_key))
    end
  end

  @doc """
  纯判定矩阵（无 IO，可直测）：

  - owner/admin 豁免（`Role.manage_role?/1`）→ `:ok`
  - `{:ok, []}`（未配置 = 不限制）→ `:ok`
  - `{:ok, allowed}` → 角色并集命中 `:ok`，未命中 `{:error, :unauthorized}`
  - `{:error, _}`（配置读取失败）→ `{:error, :authorization_unavailable}`（fail-closed）
  """
  @spec authorize_roles([atom], step_roles_result) ::
          :ok | {:error, :unauthorized | :authorization_unavailable}
  def authorize_roles(roles, step_roles_result) do
    cond do
      Enum.any?(roles, &Role.manage_role?/1) ->
        :ok

      true ->
        case step_roles_result do
          {:ok, []} ->
            :ok

          {:ok, allowed} ->
            if Enum.any?(roles, &(&1 in allowed)), do: :ok, else: {:error, :unauthorized}

          {:error, _} ->
            {:error, :authorization_unavailable}
        end
    end
  end

  @doc """
  授权错误文案（判定模块自持，WorkflowRun 接线只做透传，不做 pattern match）。

  - `:unauthorized` → `unauthorized to signal step <key>`
  - `:authorization_unavailable` → `authorization check failed for step <key>`
  """
  @spec error_message(:unauthorized | :authorization_unavailable, String.t()) :: String.t()
  def error_message(:unauthorized, step_key), do: "unauthorized to signal step #{step_key}"

  def error_message(:authorization_unavailable, step_key),
    do: "authorization check failed for step #{step_key}"

  # 查 Step 行（definition_id + step_key）→ step_roles → role.name 原子列表。
  # Step 行不存在 → {:ok, []}（未配置授权 = 不限制）。
  # 读取失败 → {:error, _}（fail-closed，2026-08-07 用户决策——不再与「未配置」混为一谈）。
  defp step_allowed_roles(workspace_id, definition_id, step_key) do
    case Ash.Query.filter(Step, definition_id == ^definition_id and step_key == ^step_key)
         |> Ash.read_one(tenant: workspace_id, authorize?: false) do
      {:ok, %Step{} = step} ->
        case Ash.Query.filter(StepRole, step_id == ^step.id)
             |> Ash.Query.load(:role)
             |> Ash.read(tenant: workspace_id, authorize?: false) do
          {:ok, step_roles} -> {:ok, Enum.map(step_roles, & &1.role.name)}
          {:error, error} -> {:error, error}
        end

      {:ok, nil} ->
        {:ok, []}

      {:error, error} ->
        {:error, error}
    end
  end
end
