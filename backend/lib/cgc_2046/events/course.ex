defmodule Cgc2046.Events.Course do
  @moduledoc """
  课程资源（Slice C #39，阶段 6 教研实例化最小子集）。

  领域模型（docs/01-定稿设计/领域模型定稿.md §5.2 ER）：Course 与 Event 字段同构
  （仅无场地/时间字段），教研字段一致。Phase 2 加入报名策略、容量与报名截止时间；
  `confirmed_count` 由 Enrollment 的数据库条件 UPDATE 原子维护。

  ## 教研实例化（#39）

  `launch` action：draft → open，发 `course.launched` 信号（经 JidoAdapter 信号总线），
  `Cgc2046.Workflows.ResearchInstantiator` 订阅该信号创建教研 WorkflowRun。

  ## 多租户

  multitenancy attribute :workspace_id，与 WorkflowRun 一致；workspace_id 由 tenant
  强制，不接受调用方传入。
  """

  use Ash.Resource,
    data_layer: AshPostgres.DataLayer,
    extensions: [AshGraphql.Resource, AshAdmin.Resource],
    authorizers: [Ash.Policy.Authorizer],
    domain: Cgc2046.Api

  alias Cgc2046.Repo
  alias Cgc2046.Workers.SignalPublishWorker
  alias Cgc2046.Workflows.JidoAdapter

  require Logger

  @status_values [:draft, :open, :closed, :cancelled]
  @enrollment_policy_values [:open, :request, :invite_only]

  attributes do
    uuid_primary_key(:id)

    attribute(:workspace_id, :uuid,
      allow_nil?: false,
      public?: true,
      writable?: false,
      description: "所属工作台（租户）ID"
    )

    attribute(:title, :string,
      allow_nil?: false,
      public?: true,
      writable?: true,
      description: "课程标题"
    )

    attribute(:research_enabled, :boolean,
      allow_nil?: false,
      default: true,
      public?: true,
      writable?: true,
      description: "是否启用教研 workflow"
    )

    attribute(:research_requirements, :map,
      default: %{},
      public?: true,
      writable?: true,
      description: "教研材料需求（audience/duration/sections 等），作为 run input 注入"
    )

    attribute(:status, :atom,
      allow_nil?: false,
      default: :draft,
      public?: true,
      writable?: false,
      constraints: [one_of: @status_values],
      description: "课程状态：draft 草稿 / open 已发布 / closed 已结束 / cancelled 已取消"
    )

    attribute(:workflow_run_id, :uuid,
      public?: true,
      writable?: true,
      description: "教研 workflow 产物引用（领域模型 §5.2 ER）"
    )

    attribute(:enrollment_policy, :atom,
      allow_nil?: false,
      default: :open,
      public?: true,
      writable?: true,
      constraints: [one_of: @enrollment_policy_values],
      description: "报名策略：open / request / invite_only"
    )

    attribute(:capacity, :integer,
      allow_nil?: true,
      public?: true,
      writable?: true,
      constraints: [min: 1],
      description: "报名名额上限；nil 表示不限"
    )

    attribute(:confirmed_count, :integer,
      allow_nil?: false,
      default: 0,
      public?: true,
      writable?: false,
      constraints: [min: 0],
      description: "已确认名额数（仅由 Enrollment 原子维护）"
    )

    attribute(:registration_deadline, :utc_datetime,
      allow_nil?: true,
      public?: true,
      writable?: true,
      description: "报名截止时间；nil 表示不设截止"
    )

    create_timestamp(:inserted_at)
    update_timestamp(:updated_at)
  end

  multitenancy do
    strategy(:attribute)
    attribute(:workspace_id)
    global?(true)
  end

  relationships do
    belongs_to(:workspace, Cgc2046.Accounts.Workspace,
      source_attribute: :workspace_id,
      destination_attribute: :id,
      allow_nil?: false
    )

    belongs_to(:workflow_run, Cgc2046.Workflows.WorkflowRun,
      source_attribute: :workflow_run_id,
      destination_attribute: :id,
      allow_nil?: true
    )
  end

  actions do
    default_accept([
      :title,
      :research_enabled,
      :research_requirements,
      :enrollment_policy,
      :capacity,
      :registration_deadline
    ])

    create :create do
      description("创建课程（默认 status=draft）")

      accept([
        :title,
        :research_enabled,
        :research_requirements,
        :enrollment_policy,
        :capacity,
        :registration_deadline
      ])

      change(set_attribute(:status, :draft))

      # workspace_id 由 tenant 强制（同 WorkflowRun.create 模式），不接受调用方传入
      change(fn changeset, _context ->
        case changeset.tenant do
          nil -> Ash.Changeset.add_error(changeset, "create requires a tenant (workspace_id)")
          tenant -> Ash.Changeset.force_change_attribute(changeset, :workspace_id, tenant)
        end
      end)
    end

    # draft → open：发布课程，发 course.launched 信号（教研实例化入口）。
    # 信号经 JidoAdapter 总线异步投递，ResearchInstantiator 订阅后创建教研 run。
    # #1 TOCTOU：publish 必须在事务提交后（after_transaction）执行——change 回调
    # 在 for_update 阶段（事务开始前）运行，此时订阅方读到未提交的 draft 状态，
    # ensure_launched 守卫会静默丢弃实例化。提交后发布，订阅方读到 open。
    update :launch do
      description("发布课程：draft → open，发 course.launched 信号")
      require_atomic?(false)
      accept([])

      change(fn changeset, _context ->
        case Ash.Changeset.get_data(changeset, :status) do
          :draft ->
            Ash.Changeset.force_change_attribute(changeset, :status, :open)

          status ->
            Ash.Changeset.add_error(changeset, "cannot launch from status=#{status}")
        end
      end)

      # 事务提交成功后发布信号（提交失败不发布——订阅方不会读到孤儿信号）。
      # 发布失败无法回滚事务，记 error 日志（best-effort，与 ResearchInstantiator
      # 异步路径的容错语义一致）。
      change(
        after_transaction(fn changeset, result, _context ->
          case result do
            {:ok, _record} ->
              tenant = changeset.tenant
              id = Ash.Changeset.get_data(changeset, :id)
              title = Ash.Changeset.get_data(changeset, :title)
              requirements = Ash.Changeset.get_data(changeset, :research_requirements) || %{}

              case JidoAdapter.publish(
                     "course.launched",
                     %{
                       "course_id" => id,
                       "title" => title,
                       "research_requirements" => requirements
                     },
                     tenant
                   ) do
                :ok ->
                  result

                {:error, reason} ->
                  Logger.error("course.launched publish failed for #{id}: #{inspect(reason)}")
                  result
              end

            _ ->
              result
          end
        end)
      )
    end

    # open → closed：结束课程（手动，或 registration_deadline 到点由
    # EventLifecycleWorker 自动执行）。发 course.ended 信号——E-9 #124 级联：
    # 订阅方 = 教研 run 回收 / 报名窗锁定（赞助随 Event 语义，Course 无赞助）。
    # 终态不可逆（D4 v1 语义）：closed/cancelled 无恢复 action，恢复路径 =
    # 新建课程。DB 级 compare-and-set 防陈旧/并发双成功（cron 与手动竞态，
    # codex 评审 BLOCKING 4）。
    update :close do
      description("结束课程：open → closed，发 course.ended 信号")
      require_atomic?(false)
      accept([])

      change(fn changeset, _context ->
        Ash.Changeset.before_action(changeset, fn cs ->
          case Ash.Changeset.get_data(cs, :status) do
            :open ->
              case status_transition(cs, :closed) do
                :ok ->
                  Ash.Changeset.force_change_attribute(cs, :status, :closed)

                {:error, :status_race} ->
                  Ash.Changeset.add_error(
                    cs,
                    "close failed: status changed concurrently, retry on fresh read"
                  )

                {:error, {:database, _} = reason} ->
                  Ash.Changeset.add_error(cs, reason)
              end

            status ->
              Ash.Changeset.add_error(cs, "cannot close from status=#{status}")
          end
        end)
      end)

      # 事务提交成功后发 course.ended（TOCTOU 纪律同 launch；发布失败入队重试，
      # 兑现至少一次投递——消费方 signal_idempotency 幂等去重）。
      change(
        after_transaction(fn changeset, result, _context ->
          publish_ended(changeset, result)
        end)
      )
    end

    # open → cancelled：取消课程。同样发 course.ended（D4：closed/cancelled 即 ended）。
    update :cancel do
      description("取消课程：open → cancelled，发 course.ended 信号")
      require_atomic?(false)
      accept([])

      change(fn changeset, _context ->
        Ash.Changeset.before_action(changeset, fn cs ->
          case Ash.Changeset.get_data(cs, :status) do
            :open ->
              case status_transition(cs, :cancelled) do
                :ok ->
                  Ash.Changeset.force_change_attribute(cs, :status, :cancelled)

                {:error, :status_race} ->
                  Ash.Changeset.add_error(
                    cs,
                    "cancel failed: status changed concurrently, retry on fresh read"
                  )

                {:error, {:database, _} = reason} ->
                  Ash.Changeset.add_error(cs, reason)
              end

            status ->
              Ash.Changeset.add_error(cs, "cannot cancel from status=#{status}")
          end
        end)
      end)

      change(
        after_transaction(fn changeset, result, _context ->
          publish_ended(changeset, result)
        end)
      )
    end

    defaults([:read])

    # #14：教研 run 创建后回写产物引用（ResearchInstantiator 内部调用，authorize?: false）。
    # workflow_run_id 是 writable 属性但不在任何公开 action 的 accept——只有本 action 可写。
    update :link_research_run do
      description("回写教研 workflow 产物引用（#39 实例化后）")
      require_atomic?(false)
      accept([:workflow_run_id])
    end

    # #40 展示页：按 id 取课程详情（GraphQL read_one）
    read :get_by_id do
      get_by([:id])
    end
  end

  # DB 级 compare-and-set：条件 UPDATE 原子抢占状态迁移（enrollment.expire 同款
  # 纪律）。num_rows=0 → 并发竞态（cron 与手动双拍），拒绝而非双成功双发布。
  # 成功后由调用方 force_change（Ash 后续写同值幂等，返回 record 状态正确）。
  defp status_transition(changeset, to_status) do
    sql = "UPDATE courses SET status = $1, updated_at = NOW() WHERE id = $2 AND status = $3"
    id = Ash.Changeset.get_data(changeset, :id)
    from_status = Ash.Changeset.get_data(changeset, :status)

    case Repo.query(sql, [to_string(to_status), Ecto.UUID.dump!(id), to_string(from_status)]) do
      {:ok, %{num_rows: 1}} ->
        :ok

      {:ok, %{num_rows: 0}} ->
        {:error, :status_race}

      {:error, reason} ->
        {:error, {:database, reason}}
    end
  end

  # 结束信号发布（close/cancel 共用）：事务提交成功后发 course.ended。
  # 发布失败入队 SignalPublishWorker 重试（至少一次投递），同时记 error 日志供对账。
  defp publish_ended(changeset, {:ok, _record} = result) do
    tenant = changeset.tenant
    id = Ecto.UUID.cast!(Ash.Changeset.get_data(changeset, :id))
    title = Ash.Changeset.get_data(changeset, :title)
    data = %{"course_id" => id, "title" => title}

    case JidoAdapter.publish("course.ended", data, tenant) do
      :ok ->
        result

      {:error, reason} ->
        Logger.error(
          "course.ended publish failed for #{id}: #{inspect(reason)}; enqueueing retry"
        )

        SignalPublishWorker.retry_later("course.ended", data, tenant)
        result
    end
  end

  defp publish_ended(_changeset, result), do: result

  postgres do
    table("courses")
    repo(Cgc2046.Repo)
  end

  policies do
    # 读取（H3）：经 workspace → memberships 路径，仅成员或平台管理员
    policy action_type(:read) do
      authorize_if({Cgc2046.Policies.ActorIsWorkspaceMemberVia, path: [:workspace]})
      authorize_if(Cgc2046.Policies.PlatformAdmin)
    end

    # 写操作：Owner/Admin（多角色并集）或平台管理员
    policy action_type([:create, :update]) do
      authorize_if(Cgc2046.Policies.WorkspaceActorIsOwnerOrAdmin)
      authorize_if(Cgc2046.Policies.PlatformAdmin)
    end
  end

  graphql do
    type(:course)

    queries do
      list(:list_courses, :read, description: "工作台的课程列表（#40 展示页）")
      read_one(:get_course, :get_by_id, description: "按 id 获取课程（#40）")
    end
  end

  admin do
    # #113 ops 面优化：导航分组 + 列表列裁剪（默认全列横向爆炸；敏感/超大字段不列出）
    resource_group(:events)
    label_field(:title)

    table_columns([
      :id,
      :workspace_id,
      :title,
      :status,
      :capacity,
      :confirmed_count,
      :registration_deadline,
      :inserted_at
    ])
  end
end
