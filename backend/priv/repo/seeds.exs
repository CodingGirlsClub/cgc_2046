# 幂等种子（mix run priv/repo/seeds.exs，ecto.setup 自动执行）。
#
# 1. 默认 workspace 2046 + 五角色（ADR-0004 §3.5；原 20260808000000 迁移内藏
#    种子的语义收编至此——migration 回归纯 schema）。workspace :create 的
#    after_action 以 Role.role_descriptions/0 为单源自动 seed 角色；member 已
#    退役（ADR-0006），不做存量用户回填（注册流程自带 2046 入座，见
#    MembershipContext.admit_to_default_workspace/1）。
# 2. owner 成员资格：归属首个平台管理员（migration 08000000 同语义）；fresh DB
#    无用户/无平台管理员时安全跳过（ADR-0004：后续首个平台管理员可认领）。
# 3. 课程 issue 学习闭环种子(切片 H U5, #180)：教研/学习 workflow 定义(单 manual
#    step 协议容器, published)；role-agent-journeys-v2 S5 加「课程教研 workflow」
#    定义(course_preparation,课程创建即经 course.created 信号实例化 prep run)。
#    #348 修复后产品单源 = Workspace :create after_action(新 workspace 自动
#    seed 三份定义,见 accounts/workspace.ex seed_workflow_definitions/1);
#    本节保留默认 workspace 的存量幂等补种(修复前建的 DB 靠 mix run 补)。
#    角色 playbook 以 Mcp.Playbooks 版本化模块常量
#    为载体(role-agent-journeys-v2 S1，经 get_role_playbook 分发)，
#    此处仅打印确认落位。

alias Cgc2046.Accounts.MembershipContext
alias Cgc2046.Accounts.User
alias Cgc2046.Accounts.Workspace
alias Cgc2046.Mcp.Playbooks
alias Cgc2046.Workflows.WorkflowDefinition
alias Cgc2046.Workflows.ProtocolDefinitions

require Ash.Query

# ── 1. 默认 workspace 2046（幂等：存在即复用）──────────────────────
{:ok, workspace} =
  case Workspace
       |> Ash.Query.for_read(:get_by_slug, %{slug: "2046"})
       |> Ash.read_one(authorize?: false) do
    {:ok, nil} ->
      # 无 actor 调用：create after_action 只 seed 五角色，不建 Owner 成员资格；
      # sponsorship_enabled=false 对齐 ADR-0004 的默认社区约定。
      {:ok, ws} =
        Workspace
        |> Ash.Changeset.for_create(
          :create,
          %{slug: "2046", name: "2046 社区", join_policy: :open, sponsorship_enabled: false},
          authorize?: false
        )
        |> Ash.create(authorize?: false)

      IO.puts("[seeds] created default workspace 2046 (5 roles seeded)")
      {:ok, ws}

    {:ok, ws} ->
      IO.puts("[seeds] default workspace 2046 exists; reuse")
      {:ok, ws}
  end

# ── 2. owner → 首个平台管理员（fresh DB 无用户时安全跳过）──────────
case User
     |> Ash.Query.filter(is_platform_admin == true)
     |> Ash.Query.sort(inserted_at: :asc)
     |> Ash.Query.limit(1)
     |> Ash.read(authorize?: false) do
  {:ok, []} ->
    IO.puts("[seeds] no platform admin yet; owner seat open for future claim")

  {:ok, [admin]} ->
    # 首个平台管理员非成员时入座 owner；已入座（含经注册自动加入的无标签成员）
    # 则幂等跳过——认领走 reassign_owner / assign_roles 管理路径。
    case MembershipContext.admit_member(admin.id, workspace.id, [:owner],
           on_conflict: :idempotent
         ) do
      {:ok, _membership} ->
        IO.puts("[seeds] owner seat granted to first platform admin #{admin.id}")

      {:error, reason} ->
        IO.puts("[seeds] owner seat skipped: #{inspect(reason)}")
    end

  {:error, reason} ->
    IO.puts("[seeds] platform admin lookup failed: #{inspect(reason)}")
end

# ── 3. 学习闭环 workflow 定义（幂等，存在即跳过）───────────────────
definitions = ProtocolDefinitions.definitions()

Enum.each(definitions, fn attrs ->
  existing =
    WorkflowDefinition
    |> Ash.Query.filter(name == ^attrs.name and type == ^attrs.type and status == :published)
    |> Ash.read_one(authorize?: false, tenant: workspace.id)

  case existing do
    {:ok, nil} ->
      {:ok, defn} =
        WorkflowDefinition
        |> Ash.Changeset.for_create(
          :create,
          Map.merge(attrs, %{input_schema: %{}}),
          tenant: workspace.id,
          authorize?: false
        )
        |> Ash.create(tenant: workspace.id, authorize?: false)

      {:ok, _published} =
        defn
        |> Ash.Changeset.for_update(:publish, %{}, authorize?: false)
        |> Ash.update(tenant: workspace.id, authorize?: false)

      IO.puts("[seeds] published #{attrs.type} definition: #{attrs.name}")

    {:ok, _} ->
      IO.puts("[seeds] #{attrs.type} definition already published; skip")

    {:error, reason} ->
      IO.puts("[seeds] definition lookup failed: #{inspect(reason)}")
  end
end)

# 角色 playbook 种子:模块常量已是幂等载体(重复运行同一文本);
# 打印确认落位(Agent 资源落地后切库,roadmap plan 020)。
Enum.each(Playbooks.roles(), fn role ->
  {:ok, playbook} = Playbooks.fetch(role)

  IO.puts(
    "[seeds] role playbook #{role}: v#{playbook.version} (#{byte_size(playbook.content)} bytes)"
  )
end)
