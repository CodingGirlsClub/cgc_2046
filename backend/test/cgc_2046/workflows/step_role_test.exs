defmodule Cgc2046.Workflows.StepRoleTest do
  use Cgc2046Web.ConnCase, async: false

  alias Cgc2046.Accounts.User
  alias Cgc2046.Accounts.Workspace
  alias Cgc2046.Accounts.Role
  alias Cgc2046.Accounts.WorkspaceMembership
  alias Cgc2046.Accounts.MembershipRole
  alias Cgc2046.Workflows.WorkflowDefinition
  alias Cgc2046.Workflows.WorkflowRun
  alias Cgc2046.Workflows.SignalLog
  alias Cgc2046.Workflows.Step
  alias Cgc2046.Workflows.StepRole
  alias Cgc2046.Workflows.StepHandlerRegistry
  alias Cgc2046.Workflows.TestActions
  alias AshAuthentication.Info, as: AuthInfo

  require Ash.Query

  setup do
    # 注册测试 step handlers（ADR-0003 两阶段初始化）
    StepHandlerRegistry.register(TestActions.Uppercase)
    StepHandlerRegistry.register(TestActions.AppendExclamation)
    :ok
  end

  @admin_email "srole-admin@example.com"
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
    slug = "srole-ws-#{System.unique_integer([:positive])}"

    assert {:ok, workspace} =
             Workspace
             |> Ash.Changeset.for_create(:create, %{slug: slug, name: "StepRole WS"})
             |> Ash.create(actor: admin)

    workspace
  end

  # workspace create 时已 seed 六角色（workspace.ex after_action），按 name 取 role_id
  defp role_by_name(workspace, name) do
    assert {:ok, role} =
             Role
             |> Ash.Query.filter(name == ^name)
             |> Ash.read_one(tenant: workspace.id, authorize?: false)

    role
  end

  # 建非 owner 成员（volunteer 等）：Membership + MembershipRole（参照 workspace.ex owner 建立模式）
  defp add_member(workspace, user, role_name) do
    role = role_by_name(workspace, role_name)

    assert {:ok, membership} =
             WorkspaceMembership
             |> Ash.Changeset.for_create(:create, %{user_id: user.id})
             |> Ash.create(tenant: workspace.id, authorize?: false)

    assert {:ok, _} =
             MembershipRole
             |> Ash.Changeset.for_create(:create, %{
               membership_id: membership.id,
               role_id: role.id
             })
             |> Ash.create(tenant: workspace.id, authorize?: false)

    membership
  end

  defp create_definition(workspace, actor, attrs \\ %{}) do
    defaults = %{
      name: "StepRole workflow",
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

  defp publish_definition(defn, workspace, actor) do
    defn
    |> Ash.Changeset.for_update(:publish, %{}, actor: actor)
    |> Ash.update(tenant: workspace.id, actor: actor)
  end

  defp create_run(workspace, actor, defn, attrs \\ %{}) do
    defaults = %{
      definition_id: defn.id,
      definition_version: defn.version,
      input_snapshot: %{"topic" => "t1"}
    }

    WorkflowRun
    |> Ash.Changeset.for_create(:create, Map.merge(defaults, attrs),
      tenant: workspace.id,
      actor: actor
    )
    |> Ash.create(tenant: workspace.id, actor: actor)
  end

  # 建 Step 行（独立资源，#34 骨架；StepRole 经 step_id 关联）
  defp create_step(workspace, actor, defn, attrs \\ %{}) do
    defaults = %{
      definition_id: defn.id,
      step_key: "approval",
      title: "审批",
      type: :manual
    }

    Step
    |> Ash.Changeset.for_create(:create, Map.merge(defaults, attrs),
      tenant: workspace.id,
      actor: actor
    )
    |> Ash.create(tenant: workspace.id, actor: actor)
  end

  # 建 StepRole 行：step 可被哪些角色执行
  defp create_step_role(workspace, actor, step, role_names) do
    for role_name <- role_names do
      role = role_by_name(workspace, role_name)

      assert {:ok, step_role} =
               StepRole
               |> Ash.Changeset.for_create(
                 :create,
                 %{
                   step_id: step.id,
                   role_id: role.id
                 },
                 tenant: workspace.id,
                 actor: actor
               )
               |> Ash.create(tenant: workspace.id, actor: actor)

      step_role
    end
  end

  # 自动步骤 + 人工步骤门控：uppercase → (manual approval) → append_exclamation
  defp gated_node_def do
    %{
      "steps" => [
        %{
          "id" => "uppercase",
          "type" => "auto",
          "action" => "Elixir.Cgc2046.Workflows.TestActions.Uppercase"
        },
        %{"id" => "approval", "type" => "manual"},
        %{
          "id" => "append_exclamation",
          "type" => "auto",
          "action" => "Elixir.Cgc2046.Workflows.TestActions.AppendExclamation"
        }
      ]
    }
  end

  # 建 gated workflow + Step/StepRole 行，返回 {run, step}
  defp setup_gated_run(workspace, admin, role_names) do
    {:ok, defn} = create_definition(workspace, admin, %{node_def: gated_node_def()})
    {:ok, published} = publish_definition(defn, workspace, admin)
    {:ok, step} = create_step(workspace, admin, defn)
    create_step_role(workspace, admin, step, role_names)
    {:ok, run} = create_run(workspace, admin, published, %{input_snapshot: %{"text" => "hi"}})
    {run, step}
  end

  # start_run 到 waiting（auto 步骤不授权，正常执行）
  defp start_to_waiting(run, workspace, actor) do
    {:ok, waiting} =
      run
      |> Ash.Changeset.for_update(:start_run, %{}, actor: actor)
      |> Ash.update(tenant: workspace.id, actor: actor)

    assert waiting.status == :waiting
    waiting
  end

  describe "StepRole 授权（#38）" do
    test "无权限执行被拒：信号发起人角色不在 step 执行角色集" do
      admin = platform_admin()
      workspace = create_workspace(admin)
      volunteer = register_user("srole-volunteer@example.com")
      add_member(workspace, volunteer, :volunteer)

      # approval 仅授权 :owner
      {run, _step} = setup_gated_run(workspace, admin, [:owner])
      waiting = start_to_waiting(run, workspace, admin)

      # volunteer 发信号 → 拒绝，run 保持 waiting
      assert {:error, %Ash.Error.Invalid{errors: errors}} =
               waiting
               |> Ash.Changeset.for_update(
                 :resume_signal,
                 %{
                   signal_type: "workflow.approval"
                 },
                 actor: volunteer
               )
               |> Ash.update(tenant: workspace.id, actor: volunteer)

      assert Enum.any?(errors, &(&1.message =~ "unauthorized to signal step approval"))

      reloaded = Ash.get!(WorkflowRun, run.id, tenant: workspace.id, actor: admin)
      assert reloaded.status == :waiting

      # 被拒信号不写 SignalLog（信号未生效，避免误导审计）
      assert {:ok, logs} =
               SignalLog
               |> Ash.Query.filter(run_id == ^run.id)
               |> Ash.read(tenant: workspace.id, actor: admin)

      assert logs == []
    end

    test "伪造 actor_id 越权被拒：volunteer 冒充 owner 发信号不放行（#4）" do
      admin = platform_admin()
      workspace = create_workspace(admin)
      volunteer = register_user("srole-forger@example.com")
      add_member(workspace, volunteer, :volunteer)

      # approval 仅授权 :owner——volunteer 无权放行
      {run, _step} = setup_gated_run(workspace, admin, [:owner])
      waiting = start_to_waiting(run, workspace, admin)

      # #4 回归：resume_signal 不接受客户端 actor_id（已移除），授权只看认证 actor。
      # volunteer 即使尝试伪造 owner 身份（旧版传 actor_id: admin.id）也无法放行。
      assert {:error, %Ash.Error.Invalid{errors: errors}} =
               waiting
               |> Ash.Changeset.for_update(
                 :resume_signal,
                 %{
                   signal_type: "workflow.approval"
                 },
                 actor: volunteer
               )
               |> Ash.update(tenant: workspace.id, actor: volunteer)

      assert Enum.any?(errors, &(&1.message =~ "unauthorized to signal step approval"))

      # 越权信号不生效：run 保持 waiting，且不写 SignalLog
      reloaded = Ash.get!(WorkflowRun, run.id, tenant: workspace.id, actor: admin)
      assert reloaded.status == :waiting

      assert {:ok, logs} =
               SignalLog
               |> Ash.Query.filter(run_id == ^run.id)
               |> Ash.read(tenant: workspace.id, actor: admin)

      assert logs == []
    end

    test "无认证 actor 发信号被拒：resume_signal 要求认证 actor（#4 补）" do
      admin = platform_admin()
      workspace = create_workspace(admin)

      # approval 仅授权 :owner
      {run, _step} = setup_gated_run(workspace, admin, [:owner])
      waiting = start_to_waiting(run, workspace, admin)

      # 不传 actor（无认证身份）→ 拒绝，run 保持 waiting
      assert {:error, %Ash.Error.Invalid{errors: errors}} =
               waiting
               |> Ash.Changeset.for_update(:resume_signal, %{signal_type: "workflow.approval"})
               |> Ash.update(tenant: workspace.id)

      assert Enum.any?(errors, &(&1.message =~ "resume_signal requires an authenticated actor"))

      reloaded = Ash.get!(WorkflowRun, run.id, tenant: workspace.id, actor: admin)
      assert reloaded.status == :waiting
    end

    test "多角色并集命中放行：volunteer 在 step 执行角色集内" do
      admin = platform_admin()
      workspace = create_workspace(admin)
      volunteer = register_user("srole-volunteer2@example.com")
      add_member(workspace, volunteer, :volunteer)

      # approval 授权 [:owner, :volunteer]（并集命中）
      {run, _step} = setup_gated_run(workspace, admin, [:owner, :volunteer])
      waiting = start_to_waiting(run, workspace, admin)

      {:ok, succeeded} =
        waiting
        |> Ash.Changeset.for_update(
          :resume_signal,
          %{
            signal_type: "workflow.approval",
            payload: %{approved_by: "volunteer"}
          },
          actor: volunteer
        )
        |> Ash.update(tenant: workspace.id, actor: volunteer)

      assert succeeded.status == :succeeded
      assert succeeded.facts["append_exclamation"] == %{"text" => "HI!"}

      # 放行信号已写 SignalLog（审计）
      assert {:ok, logs} =
               SignalLog
               |> Ash.Query.filter(run_id == ^run.id)
               |> Ash.read(tenant: workspace.id, actor: admin)

      assert [log] = logs
      assert log.signal_type == "workflow.approval"
      assert log.actor_id == volunteer.id
    end

    test "Owner/Admin 豁免：owner 发信号不受 step 角色集限制" do
      admin = platform_admin()
      workspace = create_workspace(admin)

      # approval 仅授权 :volunteer，owner 仍可放行（矩阵 §3.4 全放行）
      {run, _step} = setup_gated_run(workspace, admin, [:volunteer])
      waiting = start_to_waiting(run, workspace, admin)

      {:ok, succeeded} =
        waiting
        |> Ash.Changeset.for_update(
          :resume_signal,
          %{
            signal_type: "workflow.approval"
          },
          actor: admin
        )
        |> Ash.update(tenant: workspace.id, actor: admin)

      assert succeeded.status == :succeeded
    end

    test "无 StepRole 配置放行：未建 Step/StepRole 行不限制" do
      admin = platform_admin()
      workspace = create_workspace(admin)
      member = register_user("srole-member@example.com")
      add_member(workspace, member, :member)

      # 不建 Step/StepRole 行（human_step_test 同款路径）
      {:ok, defn} = create_definition(workspace, admin, %{node_def: gated_node_def()})
      {:ok, published} = publish_definition(defn, workspace, admin)
      {:ok, run} = create_run(workspace, admin, published, %{input_snapshot: %{"text" => "hi"}})
      waiting = start_to_waiting(run, workspace, admin)

      {:ok, succeeded} =
        waiting
        |> Ash.Changeset.for_update(
          :resume_signal,
          %{
            signal_type: "workflow.approval"
          },
          actor: member
        )
        |> Ash.update(tenant: workspace.id, actor: member)

      assert succeeded.status == :succeeded
    end

    test "auto 步骤不授权：引擎执行不受 StepRole 限制" do
      admin = platform_admin()
      workspace = create_workspace(admin)
      volunteer = register_user("srole-volunteer3@example.com")
      add_member(workspace, volunteer, :volunteer)

      {:ok, defn} = create_definition(workspace, admin, %{node_def: gated_node_def()})
      {:ok, published} = publish_definition(defn, workspace, admin)

      # uppercase（auto）仅授权 :owner——引擎执行不授权（§4.3），volunteer 仍可跑
      {:ok, _step} =
        create_step(workspace, admin, defn, %{
          step_key: "uppercase",
          title: "大写",
          type: :auto,
          action: "Elixir.Cgc2046.Workflows.TestActions.Uppercase"
        })

      create_step_role(workspace, admin, _step, [:owner])

      {:ok, run} = create_run(workspace, admin, published, %{input_snapshot: %{"text" => "hi"}})

      {:ok, waiting} =
        run
        |> Ash.Changeset.for_update(:start_run, %{}, actor: volunteer)
        |> Ash.update(tenant: workspace.id, actor: volunteer)

      assert waiting.status == :waiting
      assert waiting.facts["uppercase"] == %{"text" => "HI"}
    end
  end
end
