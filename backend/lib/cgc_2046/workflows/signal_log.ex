defmodule Cgc2046.Workflows.SignalLog do
  @moduledoc """
  收到的外部信号日志资源（Slice C #37，阶段 4）。

  领域模型（docs/01-定稿设计/领域模型定稿.md §5.1/§8）：SignalLog 属引擎 context，
  记录引擎 run 收到的外部信号（signal type/payload/时间/发起人），审计与溯源用
  （§8 审计原则：引擎侧事件入 Thread journal，SignalLog 为产品层审计视图）。

  ## ADR-0003 纪律

  引擎核心（`Cgc2046.Workflows.Engine`）不写本资源——引擎只发 telemetry 事件；
  SignalLog 写入由产品层 action（`WorkflowRun.resume_signal`）负责。

  ## 多租户

  multitenancy attribute :workspace_id（与 WorkflowRun 一致）；`run_id` 关联
  WorkflowRun（不加 FK 约束——signal 日志在 run 删除后仍保留审计）。
  """

  use Ash.Resource,
    data_layer: AshPostgres.DataLayer,
    extensions: [AshGraphql.Resource],
    authorizers: [Ash.Policy.Authorizer],
    domain: Cgc2046.Api

  attributes do
    uuid_primary_key(:id)

    attribute(:workspace_id, :uuid,
      allow_nil?: false,
      public?: true,
      writable?: false,
      description: "所属工作台（租户）ID"
    )

    attribute(:run_id, :uuid,
      allow_nil?: false,
      public?: true,
      writable?: true,
      description: "收到信号的 WorkflowRun ID（不加 FK 约束，run 删除后保留审计）"
    )

    attribute(:signal_type, :string,
      allow_nil?: false,
      public?: true,
      writable?: true,
      description: "信号类型（如 \"workflow.approval\"，约定 \"workflow.<step_key>\"）"
    )

    attribute(:payload, :map,
      public?: true,
      writable?: true,
      default: %{},
      description: "信号 payload（如 %{\"approved_by\" => \"u1\"}）"
    )

    attribute(:actor_id, :uuid,
      public?: true,
      writable?: true,
      description: "发起信号的用户 ID（阶段 5 StepRole 授权用，可空）"
    )

    attribute(:received_at, :utc_datetime_usec,
      allow_nil?: false,
      public?: true,
      writable?: false,
      description: "信号接收时间（创建时写入）"
    )

    create_timestamp(:inserted_at)
  end

  multitenancy do
    strategy(:attribute)
    attribute(:workspace_id)
    global?(true)
  end

  relationships do
    # define_attribute?: false——run_id 已手动定义（signal 日志在 run 删除后仍保留
    # 审计，不加 FK 约束；belongs_to 仅用于 policy 链 relates_to_actor_via）
    belongs_to(:run, Cgc2046.Workflows.WorkflowRun,
      source_attribute: :run_id,
      destination_attribute: :id,
      define_attribute?: false,
      allow_nil?: false
    )
  end

  actions do
    default_accept([:run_id, :signal_type, :payload, :actor_id])

    create :create do
      description("记录收到的外部信号")
      accept([:run_id, :signal_type, :payload, :actor_id])

      change(set_attribute(:received_at, DateTime.utc_now()))

      # workspace_id 由 tenant 强制（同 WorkflowRun.create 模式），不接受调用方传入
      change(fn changeset, _context ->
        case changeset.tenant do
          nil -> Ash.Changeset.add_error(changeset, "create requires a tenant (workspace_id)")
          tenant -> Ash.Changeset.force_change_attribute(changeset, :workspace_id, tenant)
        end
      end)
    end

    defaults([:read])
  end

  postgres do
    table("signal_logs")
    repo(Cgc2046.Repo)

    # run_id 不加 FK 约束（signal 日志在 run 删除后仍保留审计，计划 §步骤 3）；
    # belongs_to 仅用于 policy 链 relates_to_actor_via
    references do
      reference(:run, ignore?: true)
    end

    # #18：按 workspace + run 过滤信号日志的审计查询索引（原先只在迁移手加，
    # Ash codegen 不可见，snapshot squash 会丢）。
    custom_indexes do
      index([:workspace_id, :run_id])
    end
  end

  policies do
    # 读取（H3）：经 run → definition → workspace → memberships 路径，仅成员或平台管理员
    policy action_type(:read) do
      authorize_if(relates_to_actor_via([:run, :definition, :workspace, :memberships, :user]))
      authorize_if(actor_attribute_equals(:is_platform_admin, true))
    end

    # 写操作：Owner/Admin（多角色并集）或平台管理员
    policy action_type([:create, :update]) do
      authorize_if(Cgc2046.Policies.WorkspaceActorIsOwnerOrAdmin)
      authorize_if(actor_attribute_equals(:is_platform_admin, true))
    end
  end

  graphql do
    type(:signal_log)
  end
end
