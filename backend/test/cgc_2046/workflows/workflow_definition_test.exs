defmodule Cgc2046.Workflows.WorkflowDefinitionTest do
  use Cgc2046Web.ConnCase, async: true

  alias Cgc2046.Accounts.User
  alias Cgc2046.Accounts.Workspace
  alias Cgc2046.Workflows.WorkflowDefinition
  alias Cgc2046.Workflows.Step
  alias AshAuthentication.Info, as: AuthInfo

  require Ash.Query

  @admin_email "wfdef-admin@example.com"
  @outsider_email "wfdef-outsider@example.com"
  @password "sup3r-secret-password"

  defp password_strategy, do: AuthInfo.strategy!(User, :password)

  defp register_user(email) do
    strategy = password_strategy()

    assert {:ok, user} =
             AshAuthentication.Strategy.action(strategy, :register, %{
               email: email,
               password: @password
             })

    user
  end

  defp platform_admin(email \\ @admin_email) do
    user = register_user(email)

    {:ok, _} =
      Ecto.Adapters.SQL.query(
        Cgc2046.Repo,
        "UPDATE users SET is_platform_admin = true WHERE id = $1",
        [Ecto.UUID.dump!(user.id)]
      )

    Ash.get!(User, user.id, actor: user, authorize?: false, domain: Cgc2046.GlobalApi)
  end

  defp create_workspace(admin) do
    slug = "wfdef-ws-#{System.unique_integer([:positive])}"

    assert {:ok, workspace} =
             Workspace
             |> Ash.Changeset.for_create(:create, %{slug: slug, name: "WF Def WS"})
             |> Ash.create(actor: admin)

    workspace
  end

  defp create_definition(workspace, actor, attrs \\ %{}) do
    defaults = %{
      name: "教研 workflow",
      type: :research,
      input_schema: %{"topic" => "string"},
      node_def: %{steps: ["outline_design", "content_review"]},
      approval_timeout: 604_800
    }

    WorkflowDefinition
    |> Ash.Changeset.for_create(:create, Map.merge(defaults, attrs),
      tenant: workspace.id,
      actor: actor
    )
    |> Ash.create(tenant: workspace.id, actor: actor)
  end

  describe "lifecycle: draft → published → archived" do
    test "create defaults to status=draft, version=1" do
      admin = platform_admin()
      workspace = create_workspace(admin)
      {:ok, defn} = create_definition(workspace, admin)

      assert defn.status == :draft
      assert defn.version == 1
    end

    test "draft → published → archived" do
      admin = platform_admin()
      workspace = create_workspace(admin)
      {:ok, defn} = create_definition(workspace, admin)

      assert {:ok, published} =
               defn
               |> Ash.Changeset.for_update(:publish, %{}, actor: admin)
               |> Ash.update(tenant: workspace.id, actor: admin)

      assert published.status == :published

      assert {:ok, archived} =
               published
               |> Ash.Changeset.for_update(:archive, %{}, actor: admin)
               |> Ash.update(tenant: workspace.id, actor: admin)

      assert archived.status == :archived
    end

    test "cannot publish from archived" do
      admin = platform_admin()
      workspace = create_workspace(admin)
      {:ok, defn} = create_definition(workspace, admin)

      {:ok, defn} =
        defn
        |> Ash.Changeset.for_update(:publish, %{}, actor: admin)
        |> Ash.update(tenant: workspace.id, actor: admin)

      {:ok, defn} =
        defn
        |> Ash.Changeset.for_update(:archive, %{}, actor: admin)
        |> Ash.update(tenant: workspace.id, actor: admin)

      assert {:error, _} =
               defn
               |> Ash.Changeset.for_update(:publish, %{}, actor: admin)
               |> Ash.update(tenant: workspace.id, actor: admin)
    end

    test "cannot publish from non-draft (already published)" do
      admin = platform_admin()
      workspace = create_workspace(admin)
      {:ok, defn} = create_definition(workspace, admin)

      {:ok, published} =
        defn
        |> Ash.Changeset.for_update(:publish, %{}, actor: admin)
        |> Ash.update(tenant: workspace.id, actor: admin)

      assert {:error, _} =
               published
               |> Ash.Changeset.for_update(:publish, %{}, actor: admin)
               |> Ash.update(tenant: workspace.id, actor: admin)
    end
  end

  describe "version snapshot (D-A2)" do
    test "new_version creates draft v+1 from published definition" do
      admin = platform_admin()
      workspace = create_workspace(admin)
      {:ok, defn} = create_definition(workspace, admin)
      assert defn.version == 1

      {:ok, published} =
        defn
        |> Ash.Changeset.for_update(:publish, %{}, actor: admin)
        |> Ash.update(tenant: workspace.id, actor: admin)

      assert {:ok, v2_draft} =
               WorkflowDefinition
               |> Ash.Changeset.for_create(:new_version, %{source_definition_id: published.id},
                 tenant: workspace.id,
                 actor: admin
               )
               |> Ash.create(tenant: workspace.id, actor: admin)

      assert v2_draft.version == 2
      assert v2_draft.status == :draft
      assert v2_draft.name == published.name
    end

    test "new_version rejects non-published source" do
      admin = platform_admin()
      workspace = create_workspace(admin)
      {:ok, defn} = create_definition(workspace, admin)

      assert {:error, _} =
               WorkflowDefinition
               |> Ash.Changeset.for_create(:new_version, %{source_definition_id: defn.id},
                 tenant: workspace.id,
                 actor: admin
               )
               |> Ash.create(tenant: workspace.id, actor: admin)
    end

    test "published v1 unaffected by new v2 draft" do
      admin = platform_admin()
      workspace = create_workspace(admin)
      {:ok, defn} = create_definition(workspace, admin, %{node_def: %{steps: ["v1_step"]}})

      {:ok, published} =
        defn
        |> Ash.Changeset.for_update(:publish, %{}, actor: admin)
        |> Ash.update(tenant: workspace.id, actor: admin)

      # 出 v2 draft
      {:ok, _v2} =
        WorkflowDefinition
        |> Ash.Changeset.for_create(:new_version, %{source_definition_id: published.id},
          tenant: workspace.id,
          actor: admin
        )
        |> Ash.create(tenant: workspace.id, actor: admin)

      # 重新读 v1 published，node_def 不变（Postgres jsonb 读回为 string key）
      reloaded = Ash.get!(WorkflowDefinition, published.id, tenant: workspace.id, actor: admin)
      assert reloaded.node_def == %{"steps" => ["v1_step"]}
      assert reloaded.version == 1
    end
  end

  describe "type enum (全 6 个)" do
    test "accepts all 6 type values" do
      admin = platform_admin()
      workspace = create_workspace(admin)

      for t <- [:platform_ops, :learning, :enrollment, :sponsorship, :speaker_invitation, :research] do
        assert {:ok, defn} = create_definition(workspace, admin, %{name: "wf-#{t}", type: t})
        assert defn.type == t
      end
    end

    test "rejects invalid type" do
      admin = platform_admin()
      workspace = create_workspace(admin)

      assert {:error, _} = create_definition(workspace, admin, %{type: :invalid_type})
    end
  end

  describe "Step as independent resource" do
    test "step belongs to definition, keyed by step_key" do
      admin = platform_admin()
      workspace = create_workspace(admin)
      {:ok, defn} = create_definition(workspace, admin)

      assert {:ok, step} =
               Step
               |> Ash.Changeset.for_create(:create, %{
                 definition_id: defn.id,
                 step_key: "outline_design",
                 title: "大纲设计",
                 type: :manual,
                 action: "Elixir.Cgc2046.Workflows.Actions.OutlineDesign"
               })
               |> Ash.create(tenant: workspace.id, actor: admin)

      assert step.type == :manual
      assert step.definition_id == defn.id
    end

    test "step_key unique per definition" do
      admin = platform_admin()
      workspace = create_workspace(admin)
      {:ok, defn} = create_definition(workspace, admin)

      attrs = %{definition_id: defn.id, step_key: "dup", title: "A", type: :auto}

      assert {:ok, _} =
               Step
               |> Ash.Changeset.for_create(:create, attrs)
               |> Ash.create(tenant: workspace.id, actor: admin)

      assert {:error, %Ash.Error.Invalid{errors: errors}} =
               Step
               |> Ash.Changeset.for_create(:create, attrs)
               |> Ash.create(tenant: workspace.id, actor: admin)

      assert Enum.any?(errors, &match?(%Ash.Error.Changes.InvalidAttribute{}, &1))
    end

    test "definition has_many steps" do
      admin = platform_admin()
      workspace = create_workspace(admin)
      {:ok, defn} = create_definition(workspace, admin)

      for key <- ["s1", "s2"] do
        Step
        |> Ash.Changeset.for_create(:create, %{
          definition_id: defn.id,
          step_key: key,
          title: key,
          type: :auto
        })
        |> Ash.create!(tenant: workspace.id, actor: admin)
      end

      loaded = Ash.load!(defn, :steps, tenant: workspace.id, actor: admin)
      assert length(loaded.steps) == 2
    end
  end

  describe "tenant isolation" do
    test "cross-workspace definition not visible" do
      admin = platform_admin()
      ws_a = create_workspace(admin)
      ws_b = create_workspace(admin)

      {:ok, _defn_a} = create_definition(ws_a, admin, %{name: "isolated-wf"})

      # ws_b 查不到 ws_a 的定义
      results =
        WorkflowDefinition
        |> Ash.Query.for_read(:read)
        |> Ash.Query.filter(name == "isolated-wf")
        |> Ash.read!(tenant: ws_b.id, actor: admin)

      assert results == []
    end
  end

  describe "authorization" do
    test "non-platform-admin non-member cannot create definition" do
      admin = platform_admin()
      workspace = create_workspace(admin)
      outsider = register_user(@outsider_email)

      assert {:error, %Ash.Error.Forbidden{}} =
               WorkflowDefinition
               |> Ash.Changeset.for_create(:create, %{
                 name: "forbidden",
                 type: :research
               })
               |> Ash.create(tenant: workspace.id, actor: outsider)
    end

    # H3 回归：非成员（非平台管理员）读不到其它租户的 definition。
    # 未修复前 read policy 是 actor_present()，任何登录用户都能跨租户读到。
    # 修复后非成员被拒（Ash 对 get policy 失败返回 Forbidden 或 NotFound，取决于评估路径，
    # 都表示读不到——核心断言是「读不到数据」而非具体错误类型）。
    test "non-member non-platform-admin cannot read definition (H3)" do
      admin = platform_admin()
      workspace = create_workspace(admin)
      {:ok, defn} = create_definition(workspace, admin)
      outsider = register_user(@outsider_email)

      assert {:error, _} =
               Ash.get(WorkflowDefinition, defn.id, tenant: workspace.id, actor: outsider)
    end
  end

  describe "cross-tenant new_version (H2)" do
    # H2 回归：new_version 的 source_definition_id 不能指向其它租户的 definition。
    # 未修复前 Ash.get 不传 tenant，global?(true) 下能跨租户读 source。
    test "new_version rejects source from another workspace" do
      admin = platform_admin()
      ws_a = create_workspace(admin)
      ws_b = create_workspace(admin)

      # ws_a 有 published 定义
      {:ok, defn_a} = create_definition(ws_a, admin, %{name: "ws-a-wf"})

      {:ok, published_a} =
        defn_a
        |> Ash.Changeset.for_update(:publish, %{}, actor: admin)
        |> Ash.update(tenant: ws_a.id, actor: admin)

      # ws_b 试图用 ws_a 的定义 id 出 new_version → 必须被拒
      assert {:error, _} =
               WorkflowDefinition
               |> Ash.Changeset.for_create(:new_version, %{source_definition_id: published_a.id},
                 tenant: ws_b.id,
                 actor: admin
               )
               |> Ash.create(tenant: ws_b.id, actor: admin)
    end

    test "new_version requires tenant" do
      admin = platform_admin()
      workspace = create_workspace(admin)
      {:ok, defn} = create_definition(workspace, admin)

      {:ok, published} =
        defn
        |> Ash.Changeset.for_update(:publish, %{}, actor: admin)
        |> Ash.update(tenant: workspace.id, actor: admin)

      # 不传 tenant → 报错（而非全表读）
      assert {:error, _} =
               WorkflowDefinition
               |> Ash.Changeset.for_create(:new_version, %{source_definition_id: published.id},
                 actor: admin
               )
               |> Ash.create(actor: admin)
    end
  end
end
