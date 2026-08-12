defmodule Cgc2046.Policies.ActorIsWorkspaceMemberViaTest do
  use Cgc2046Web.ConnCase, async: true

  alias Cgc2046.AccountsFixtures, as: Fixtures
  alias Cgc2046.Policies.ActorIsWorkspaceMemberVia
  alias Cgc2046.Workflows.WorkflowDefinition
  alias Cgc2046.Workflows.WorkflowRun

  require Ash.Query

  # 布置方式复用 workflow_run_test.exs：platform_admin 建 workspace →
  # definition → publish → run，全程带 actor 走授权路径。
  defp create_run_fixture(prefix) do
    admin = Fixtures.platform_admin("#{prefix}-admin")
    workspace = Fixtures.create_workspace(admin)

    {:ok, defn} =
      WorkflowDefinition
      |> Ash.Changeset.for_create(
        :create,
        %{
          name: "成员可读 workflow",
          type: :research,
          input_schema: %{"topic" => "string"},
          node_def: %{steps: ["outline_design"]},
          approval_timeout: 604_800
        },
        tenant: workspace.id,
        actor: admin
      )
      |> Ash.create(tenant: workspace.id, actor: admin)

    {:ok, published} =
      defn
      |> Ash.Changeset.for_update(:publish, %{}, actor: admin)
      |> Ash.update(tenant: workspace.id, actor: admin)

    {:ok, run} =
      WorkflowRun
      |> Ash.Changeset.for_create(
        :create,
        %{
          definition_id: published.id,
          definition_version: published.version,
          input_snapshot: %{"topic" => "t1"}
        },
        tenant: workspace.id,
        actor: admin
      )
      |> Ash.create(tenant: workspace.id, actor: admin)

    %{workspace: workspace, run: run}
  end

  defp read_run(workspace, run, actor) do
    WorkflowRun
    |> Ash.Query.for_read(:read)
    |> Ash.Query.filter(id == ^run.id)
    |> Ash.read(tenant: workspace.id, actor: actor)
  end

  describe "经 workflow_run 读策略端到端验证（H3 成员可读）" do
    test "workspace 成员能读到该 workspace 的 workflow_run" do
      %{workspace: workspace, run: run} = create_run_fixture("aimv")
      member = Fixtures.register_user("aimv-member")
      Fixtures.add_member(workspace, member)

      assert {:ok, [found]} = read_run(workspace, run, member)
      assert found.id == run.id
    end

    test "非成员读不到该 workspace 的 workflow_run（过滤后为空）" do
      %{workspace: workspace, run: run} = create_run_fixture("aimv")
      outsider = Fixtures.register_user("aimv-outsider")

      assert {:ok, []} = read_run(workspace, run, outsider)
    end

    test "actor 为 nil 时被策略拒绝 Forbidden（官方 relates_to_actor_via 语义：filter 引用 actor，strict_check(nil) → false）" do
      %{workspace: workspace, run: run} = create_run_fixture("aimv")

      assert {:error, %Ash.Error.Forbidden{}} = read_run(workspace, run, nil)
    end
  end

  describe "路径硬校验（#66 陷阱替代，构造 filter 时 raise ArgumentError）" do
    test "path 中的关系不存在时 filter/3 当场 raise" do
      assert_raise ArgumentError, ~r/关系 :nonexistent_rel 在 .*WorkflowRun 上不存在/, fn ->
        ActorIsWorkspaceMemberVia.filter(nil, %{resource: WorkflowRun}, path: [:nonexistent_rel])
      end
    end

    test "path 终点非 Workspace（停在 WorkflowDefinition）时 filter/3 当场 raise" do
      assert_raise ArgumentError, ~r/path 终点必须是 .*Workspace.*实际停在 .*WorkflowDefinition/, fn ->
        ActorIsWorkspaceMemberVia.filter(nil, %{resource: WorkflowRun}, path: [:definition])
      end
    end
  end
end
