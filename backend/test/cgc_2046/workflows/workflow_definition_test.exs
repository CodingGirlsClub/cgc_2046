defmodule Cgc2046.Workflows.WorkflowDefinitionTest do
  use Cgc2046Web.ConnCase, async: true

  alias Cgc2046.Accounts.Role
  alias Cgc2046.AccountsFixtures, as: Fixtures
  alias Cgc2046.Workflows.WorkflowDefinition
  alias Cgc2046.Workflows.Step

  require Ash.Query

  defp create_definition(workspace, actor, attrs \\ %{}) do
    defaults = %{
      name: "教研 workflow",
      type: :curriculum,
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
      admin = Fixtures.platform_admin("wfdef")
      workspace = Fixtures.create_workspace(admin)
      {:ok, defn} = create_definition(workspace, admin)

      assert defn.status == :draft
      assert defn.version == 1
    end

    test "draft → published → archived" do
      admin = Fixtures.platform_admin("wfdef")
      workspace = Fixtures.create_workspace(admin)
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
      admin = Fixtures.platform_admin("wfdef")
      workspace = Fixtures.create_workspace(admin)
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
      admin = Fixtures.platform_admin("wfdef")
      workspace = Fixtures.create_workspace(admin)
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
      admin = Fixtures.platform_admin("wfdef")
      workspace = Fixtures.create_workspace(admin)
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

    test "new_version copies Step/StepRole rows (#15)" do
      admin = Fixtures.platform_admin("wfdef")
      workspace = Fixtures.create_workspace(admin)
      {:ok, defn} = create_definition(workspace, admin)

      # 给源定义建 manual Step + StepRole（角色绑定：owner 可执行审批）
      {:ok, step} =
        Step
        |> Ash.Changeset.for_create(
          :create,
          %{
            definition_id: defn.id,
            step_key: "approval",
            title: "审批",
            type: :manual
          },
          tenant: workspace.id,
          actor: admin
        )
        |> Ash.create(tenant: workspace.id, actor: admin)

      {:ok, owner_role} =
        Role
        |> Ash.Query.filter(name == ^"owner")
        |> Ash.read_one(tenant: workspace.id, authorize?: false)

      assert {:ok, _step_role} =
               Cgc2046.Workflows.StepRole
               |> Ash.Changeset.for_create(
                 :create,
                 %{step_id: step.id, role_id: owner_role.id},
                 tenant: workspace.id,
                 actor: admin
               )
               |> Ash.create(tenant: workspace.id, actor: admin)

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

      # Step 行复制到新定义（definition_id 换新，step_key 保留）
      assert {:ok, v2_steps} =
               Ash.Query.filter(Step, definition_id == ^v2_draft.id)
               |> Ash.read(tenant: workspace.id, actor: admin, authorize?: false)

      assert [copied_step] = v2_steps
      assert copied_step.step_key == "approval"
      assert copied_step.type == :manual
      refute copied_step.id == step.id

      # StepRole 关联复制：新 step 的 role 映射存在（role_id 指向同一 Role 集合）
      assert {:ok, v2_step_roles} =
               Ash.Query.filter(Cgc2046.Workflows.StepRole, step_id == ^copied_step.id)
               |> Ash.read(tenant: workspace.id, actor: admin, authorize?: false)

      assert v2_step_roles != []
    end

    test "new_version rejects non-published source" do
      admin = Fixtures.platform_admin("wfdef")
      workspace = Fixtures.create_workspace(admin)
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
      admin = Fixtures.platform_admin("wfdef")
      workspace = Fixtures.create_workspace(admin)
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

  describe "type enum (全 5 个，R3 删 platform_ops)" do
    test "accepts all 5 type values" do
      admin = Fixtures.platform_admin("wfdef")
      workspace = Fixtures.create_workspace(admin)

      for t <- [
            :learning,
            :enrollment,
            :sponsorship,
            :speaker_invitation,
            :curriculum
          ] do
        assert {:ok, defn} = create_definition(workspace, admin, %{name: "wf-#{t}", type: t})
        assert defn.type == t
      end
    end

    test "rejects removed platform_ops (R3) and invalid types" do
      admin = Fixtures.platform_admin("wfdef")
      workspace = Fixtures.create_workspace(admin)

      assert {:error, _} =
               create_definition(workspace, admin, %{name: "wf-ops", type: :platform_ops})
    end

    test "rejects retired research type" do
      admin = Fixtures.platform_admin("wfdef")
      workspace = Fixtures.create_workspace(admin)

      assert {:error, _} =
               create_definition(workspace, admin, %{name: "wf-research", type: :research})
    end

    test "rejects invalid type" do
      admin = Fixtures.platform_admin("wfdef")
      workspace = Fixtures.create_workspace(admin)

      assert {:error, _} = create_definition(workspace, admin, %{name: "wf-bad", type: :nope})
    end
  end

  describe "Step as independent resource" do
    test "step belongs to definition, keyed by step_key" do
      admin = Fixtures.platform_admin("wfdef")
      workspace = Fixtures.create_workspace(admin)
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
      admin = Fixtures.platform_admin("wfdef")
      workspace = Fixtures.create_workspace(admin)
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
      admin = Fixtures.platform_admin("wfdef")
      workspace = Fixtures.create_workspace(admin)
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
      admin = Fixtures.platform_admin("wfdef")
      ws_a = Fixtures.create_workspace(admin)
      ws_b = Fixtures.create_workspace(admin)

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
      admin = Fixtures.platform_admin("wfdef")
      workspace = Fixtures.create_workspace(admin)
      outsider = Fixtures.register_user("wfdef-outsider")

      assert {:error, %Ash.Error.Forbidden{}} =
               WorkflowDefinition
               |> Ash.Changeset.for_create(:create, %{
                 name: "forbidden",
                 type: :curriculum
               })
               |> Ash.create(tenant: workspace.id, actor: outsider)
    end

    # H3 回归：非成员（非平台管理员）读不到其它租户的 definition。
    # 未修复前 read policy 是 actor_present()，任何登录用户都能跨租户读到。
    # 修复后非成员被拒（Ash 对 get policy 失败返回 Forbidden 或 NotFound，取决于评估路径，
    # 都表示读不到——核心断言是「读不到数据」而非具体错误类型）。
    test "non-member non-platform-admin cannot read definition (H3)" do
      admin = Fixtures.platform_admin("wfdef")
      workspace = Fixtures.create_workspace(admin)
      {:ok, defn} = create_definition(workspace, admin)
      outsider = Fixtures.register_user("wfdef-outsider")

      assert {:error, _} =
               Ash.get(WorkflowDefinition, defn.id, tenant: workspace.id, actor: outsider)
    end
  end

  describe "cross-tenant new_version (H2)" do
    # H2 回归：new_version 的 source_definition_id 不能指向其它租户的 definition。
    # 未修复前 Ash.get 不传 tenant，global?(true) 下能跨租户读 source。
    test "new_version rejects source from another workspace" do
      admin = Fixtures.platform_admin("wfdef")
      ws_a = Fixtures.create_workspace(admin)
      ws_b = Fixtures.create_workspace(admin)

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
      admin = Fixtures.platform_admin("wfdef")
      workspace = Fixtures.create_workspace(admin)
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
