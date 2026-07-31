defmodule Cgc2046.Workflows.Deploy do
  @moduledoc """
  Workflow DSL 部署服务(T08,spec §6/§7):校验 DSL + 幂等部署。

  - **授权**:部署需 `workflow:deploy`(Owner/Admin/Tutor;Learner/Volunteer 无
    该权限 → 403,验收点 4)。
  - **DSL 校验**(spec §6,非法 → 422,验收点 3):
    - step 顺序:position 从 1 连续递增、无遗漏、无重复
    - allowed_roles:每个角色名必须存在于该 workspace 的 Role 表
    - type:必须为合法 Step 类型(见 `@valid_step_types`)
  - **幂等部署**(验收点 2):同 `name` + workspace 已存在 Workflow → 更新
    (description/dsl_version + 重建 steps/step_roles),不新建 Workflow。

  内部落库走 `authorize?: false`(编排层已显式校验权限,参考
  `Cgc2046.Join` 先例);事务保证 Workflow+Steps 原子性。
  """

  alias Cgc2046.Repo
  alias Cgc2046.Rbac
  alias Cgc2046.Workspaces.{Step, StepRole, Workflow}

  require Ash.Query

  import Ecto.Query, only: [from: 2]

  # 合法 Step 类型(教研场景;调研文档示例:content/discussion,扩展 task/quiz/survey)。
  @valid_step_types ~w(content discussion task quiz survey)

  @doc """
  部署 Workflow DSL。

  返回 `{:ok, workflow, :created | :updated}` 或 `{:error, %Ash.Error{}}`。
  """
  def deploy(actor, workspace_id, params) do
    with :ok <- ensure_permission(actor, workspace_id),
         {:ok, dsl} <- validate_dsl(workspace_id, params) do
      upsert_workflow(workspace_id, dsl)
    end
  end

  # ---------- 授权 ----------

  defp ensure_permission(actor, workspace_id) do
    if Rbac.can?(actor, "workflow:deploy", tenant: workspace_id) do
      :ok
    else
      {:error, Ash.Error.Forbidden.exception([])}
    end
  end

  # ---------- DSL 校验 ----------

  defp validate_dsl(workspace_id, params) do
    with {:ok, name} <- require_string(params, "name"),
         {:ok, dsl_version} <- validate_dsl_version(params),
         {:ok, steps} <- validate_steps(workspace_id, Map.get(params, "steps", [])) do
      {:ok,
       %{
         name: name,
         description: Map.get(params, "description"),
         dsl_version: dsl_version,
         steps: steps
       }}
    end
  end

  defp require_string(params, key) do
    case Map.get(params, key) do
      value when is_binary(value) and value != "" -> {:ok, value}
      _ -> invalid("字段 #{key} 必填且为非空字符串")
    end
  end

  defp validate_dsl_version(params) do
    case Map.get(params, "dsl_version", 1) do
      v when is_integer(v) and v >= 1 -> {:ok, v}
      _ -> invalid("dsl_version 必须为 >= 1 的整数")
    end
  end

  defp validate_steps(workspace_id, steps) when is_list(steps) do
    with {:ok, parsed} <- parse_steps(steps),
         :ok <- validate_positions(parsed),
         :ok <- validate_types(parsed),
         {:ok, enriched} <- resolve_allowed_roles(workspace_id, parsed) do
      {:ok, enriched}
    end
  end

  defp validate_steps(_workspace_id, _steps), do: invalid("steps 必须为数组")

  defp parse_steps(steps) do
    {:ok,
     Enum.map(steps, fn s ->
       %{
         position: Map.get(s, "position"),
         title: Map.get(s, "title"),
         type: Map.get(s, "type"),
         allowed_roles: Map.get(s, "allowed_roles", []),
         agent_hint: Map.get(s, "agent_hint")
       }
     end)}
  rescue
    _ -> invalid("steps 元素必须为对象")
  end

  defp validate_positions(steps) do
    positions = Enum.map(steps, & &1.position)

    # 空 steps 合法(T05 既有创建行为:无 steps 的 Workflow 创建 → 201);
    # 非空时 position 必须为 1..length 连续递增。注意 Elixir 中 1..0 是递减 range。
    expected =
      case length(steps) do
        0 -> []
        n -> Enum.to_list(1..n)
      end

    cond do
      Enum.any?(positions, &(not is_integer(&1) or &1 < 1)) ->
        invalid("step position 必须为正整数")

      Enum.sort(positions) != expected ->
        invalid("step position 必须从 1 连续递增、无遗漏、无重复")

      true ->
        :ok
    end
  end

  defp validate_types(steps) do
    bad = Enum.reject(steps, &(&1.type in @valid_step_types))

    if bad == [] do
      :ok
    else
      invalid("step type 非法,合法值为: #{Enum.join(@valid_step_types, ", ")}")
    end
  end

  defp resolve_allowed_roles(workspace_id, steps) do
    names =
      steps
      |> Enum.flat_map(& &1.allowed_roles)
      |> Enum.uniq()

    roles =
      if names == [] do
        %{}
      else
        from(r in "roles",
          where: r.name in ^names and r.workspace_id == ^Ecto.UUID.dump!(workspace_id),
          select: {r.name, r.id}
        )
        |> Repo.all()
        |> Map.new()
      end

    missing =
      steps
      |> Enum.flat_map(& &1.allowed_roles)
      |> Enum.uniq()
      |> Enum.reject(&Map.has_key?(roles, &1))

    if missing == [] do
      {:ok,
       Enum.map(steps, fn step ->
         Map.put(step, :role_ids, Enum.map(step.allowed_roles, &Map.fetch!(roles, &1)))
       end)}
    else
      invalid("allowed_roles 引用了不存在的角色: #{Enum.join(missing, ", ")}")
    end
  end

  defp invalid(message), do: {:error, Ash.Error.Invalid.exception(errors: [message])}

  # ---------- 幂等部署 ----------

  defp upsert_workflow(workspace_id, dsl) do
    Repo.transaction(fn ->
      case find_workflow(workspace_id, dsl.name) do
        nil ->
          workflow = create_workflow!(workspace_id, dsl)
          create_steps!(workspace_id, workflow, dsl.steps)
          {workflow, :created}

        workflow ->
          workflow = update_workflow!(workspace_id, workflow, dsl)
          replace_steps!(workspace_id, workflow, dsl.steps)
          {workflow, :updated}
      end
    end)
    |> case do
      {:ok, {workflow, action}} -> {:ok, workflow, action}
      {:error, %Ash.Error.Invalid{} = e} -> {:error, e}
      {:error, error} -> {:error, error}
    end
  end

  defp find_workflow(workspace_id, name) do
    Workflow
    |> Ash.Query.filter(name == ^name)
    |> Ash.read_one(tenant: workspace_id, authorize?: false)
    |> case do
      {:ok, workflow} -> workflow
      _ -> nil
    end
  end

  defp create_workflow!(workspace_id, dsl) do
    {workflow, _notifications} =
      Ash.create!(Workflow, %{
        name: dsl.name,
        description: dsl.description,
        dsl_version: dsl.dsl_version
      }, tenant: workspace_id, authorize?: false, return_notifications?: true)

    workflow
  end

  defp update_workflow!(workspace_id, workflow, dsl) do
    {workflow, _notifications} =
      Ash.update!(workflow, %{
        description: dsl.description,
        dsl_version: dsl.dsl_version
      }, tenant: workspace_id, authorize?: false, return_notifications?: true)

    workflow
  end

  defp replace_steps!(workspace_id, workflow, steps) do
    workflow
    |> Ash.load!(:steps, tenant: workspace_id, authorize?: false)
    |> Map.fetch!(:steps)
    |> Enum.each(fn step -> destroy_step!(step) end)

    create_steps!(workspace_id, workflow, steps)
  end

  defp destroy_step!(step) do
    step_uuid = Ecto.UUID.dump!(step.id)

    from(sr in "step_roles", where: sr.step_id == ^step_uuid)
    |> Repo.delete_all()

    from(s in "steps", where: s.id == ^step_uuid)
    |> Repo.delete_all()

    :ok
  end

  defp create_steps!(workspace_id, workflow, steps) do
    Enum.each(steps, fn step ->
      {created, _notifications} =
        Ash.create!(Step, %{
          title: step.title,
          position: step.position,
          type: step.type,
          agent_hint: step.agent_hint,
          workflow_id: workflow.id
        }, tenant: workspace_id, authorize?: false, return_notifications?: true)

      Enum.each(step.role_ids, fn role_id ->
        {_role, _notifications} =
          Ash.create!(StepRole, %{
            step_id: created.id,
            role_id: role_id
          }, tenant: workspace_id, authorize?: false, return_notifications?: true)
      end)
    end)

    :ok
  end
end
