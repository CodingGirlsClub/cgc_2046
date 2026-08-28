defmodule Cgc2046.Learning.LearningRecord do
  @moduledoc """
  学习记录资源(切片 H U2, #180):个人学习记忆库原子数据。

  一行 = 一条 checklist 条目的完成记录(挂人不挂报名,Q1):

  - 唯一键 `(course_id, user_id, issue_id, item_id)` upsert 最新为准,不留
    历史版本(退款重报记忆不清零,AE1);
  - `enrollment_id` / `run_id` 审计列:记录当时哪个报名/哪个 run 写的,不参与
    唯一性;
  - `issue_id` / `item_id` 字符串宽存,无内容外键(KTD4:id 稳定纪律——内容
    编辑不破坏进行中学员);
  - 课程终态拦截在工具层(U3,`save_learning_records` 校验 course status),
    资源层不拦;记录行永不动(账本不删)。

  issue 三态(Todo / In Progress / Done)由记录派生,不提供手动切换——
  状态是投影不是手柄(设计 §3)。
  """

  use Ash.Resource,
    data_layer: AshPostgres.DataLayer,
    extensions: [AshAdmin.Resource],
    authorizers: [Ash.Policy.Authorizer],
    domain: Cgc2046.Learning

  attributes do
    uuid_primary_key(:id)

    attribute(:workspace_id, :uuid,
      allow_nil?: false,
      public?: true,
      writable?: false,
      description: "所属工作台(租户)ID"
    )

    attribute(:course_id, :uuid,
      allow_nil?: false,
      public?: true,
      writable?: true,
      description: "课程 ID(记忆归属锚,挂人不挂报名)"
    )

    attribute(:user_id, :uuid,
      allow_nil?: false,
      public?: true,
      writable?: true,
      description: "学员用户 ID(记忆持有者)"
    )

    attribute(:issue_id, :string,
      allow_nil?: false,
      public?: true,
      writable?: true,
      description: "issue 卡 id(宽存字符串,id 稳定纪律)"
    )

    attribute(:item_id, :string,
      allow_nil?: false,
      public?: true,
      writable?: true,
      description: "checklist 条目 id(宽存字符串,id 稳定纪律)"
    )

    attribute(:done, :boolean,
      allow_nil?: false,
      default: false,
      public?: true,
      writable?: true,
      description: "该条目是否达成(状态三态投影的唯一事实源)"
    )

    attribute(:evidence, :string,
      public?: true,
      writable?: true,
      description: "一句证据摘要;handwork 条目 = 产物运行/检查结论"
    )

    attribute(:recorded_at, :utc_datetime_usec,
      allow_nil?: false,
      public?: true,
      writable?: true,
      description: "记录时间"
    )

    attribute(:enrollment_id, :uuid,
      public?: true,
      writable?: true,
      description: "审计列:记录当时的报名 ID(不参与唯一性)"
    )

    attribute(:run_id, :uuid,
      public?: true,
      writable?: true,
      description: "审计列:记录当时的 run ID(不参与唯一性)"
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
    # 供成员授权路径(path: [:workspace]);记忆归属的真实锚是
    # (course_id, user_id),workspace 关系只承载租户归属
    belongs_to(:workspace, Cgc2046.Accounts.Workspace,
      source_attribute: :workspace_id,
      destination_attribute: :id,
      allow_nil?: false
    )

    belongs_to(:course, Cgc2046.Courses.Course,
      source_attribute: :course_id,
      destination_attribute: :id,
      allow_nil?: false
    )
  end

  actions do
    default_accept([:course_id, :user_id, :issue_id, :item_id, :done, :evidence, :recorded_at])

    # 单条 upsert(记忆写入):同键命中则覆盖 done/evidence/recorded_at +
    # 审计列(最新为准)。
    create :upsert_record do
      description("写入一条学习记录(同键 upsert 最新为准;批量入口为 upsert_records)")

      accept([
        :course_id,
        :user_id,
        :issue_id,
        :item_id,
        :done,
        :evidence,
        :recorded_at,
        :enrollment_id,
        :run_id
      ])

      upsert?(true)
      upsert_identity(:unique_key)
      upsert_fields([:done, :evidence, :recorded_at, :enrollment_id, :run_id])
    end

    # 批量 upsert(MCP save_learning_records 一次会话多条,U3):逐条走
    # upsert_record 语义,任一失败整批返回错误(调用方决定部分重试面;工具层
    # 一次性事务无并发扣减场景,plan U2 Approach 明示无需裸 SQL 配套)。
    create :upsert_records do
      description("批量写入学习记录(逐条 upsert;任一失败即停,整批随事务回滚)")

      accept([])

      # 占位行自身也走 upsert(F2 同键二次写路径):不带则占位 insert 撞
      # 唯一索引(course_id has already been taken)。占位行取首条记录字段,
      # 同键命中即更新——与 after_action 首条 upsert 结果一致,行数不增。
      upsert?(true)
      upsert_identity(:unique_key)
      upsert_fields([:done, :evidence, :recorded_at, :enrollment_id, :run_id])

      argument(:records, {:array, :map},
        allow_nil?: false,
        description: "记录列表(%{course_id, user_id, issue_id, item_id, done, evidence, ...})"
      )

      change(fn changeset, _context ->
        records = Ash.Changeset.get_argument(changeset, :records) || []

        changeset
        |> Ash.Changeset.put_context(:upsert_records_input, records)
        |> Ash.Changeset.before_action(fn cs ->
          # 占位行:满足非空校验让主 changeset 可插;真实批量由 after_action
          # 逐条 upsert(占位行随之成为首条的同键 upsert,无额外行)
          placeholder = Map.new(placeholder_attrs(records))

          Enum.reduce(placeholder, cs, fn {k, v}, acc ->
            Ash.Changeset.force_change_attribute(acc, k, v)
          end)
        end)
      end)

      change(
        after_action(fn changeset, result, _context ->
          records = changeset.context[:upsert_records_input] || []
          tenant = changeset.tenant
          actor = changeset.context[:private][:actor]

          case batch_upsert(records, tenant, actor) do
            {:ok, rows} -> {:ok, rows}
            {:error, reason} -> {:error, reason}
          end
        end)
      )
    end

    defaults([:read])
  end

  identities do
    # all_tenants?:记忆唯一键全局(course_id 全局唯一;跨 enrollment 延续),
    # 否则 :attribute 多租户会把 workspace_id 并入冲突目标
    identity(:unique_key, [:course_id, :user_id, :issue_id, :item_id], all_tenants?: true)
  end

  postgres do
    table("learning_records")
    repo(Cgc2046.Repo)

    custom_indexes do
      index([:workspace_id])
      index([:user_id])
    end
  end

  policies do
    # 读取:learner 本人(记忆持有者)∪ workspace 成员(tutor 看进度账本)∪
    # 平台管理员。本人判定用 SimpleCheck(expr)而非逐行 filter——读面按
    # user_id == actor.id 过滤在工具层做恒锚(见 save_step_output 家族纪律)。
    policy action_type(:read) do
      authorize_if(expr(user_id == ^actor(:id)))
      authorize_if({Cgc2046.Accounts.Policies.ActorIsWorkspaceMemberVia, path: [:workspace]})
      authorize_if(Cgc2046.Accounts.Policies.PlatformAdmin)
    end

    # 写入:learner 本人(MCP 工具经工具层授权后传 actor)∪ 成员门槛兜底;
    # 课程终态拦截在工具层,资源层不拦(U2 Approach)
    policy action_type(:create) do
      authorize_if(expr(user_id == ^actor(:id)))
      authorize_if({Cgc2046.Accounts.Policies.ActorIsWorkspaceMemberVia, path: [:workspace]})
      authorize_if(Cgc2046.Accounts.Policies.PlatformAdmin)
    end
  end

  admin do
    # #113 ops 面优化:导航分组 + 列表列裁剪
    resource_group(:learning)
    label_field(:issue_id)

    table_columns([
      :id,
      :workspace_id,
      :course_id,
      :user_id,
      :issue_id,
      :item_id,
      :done,
      :recorded_at
    ])
  end

  # --- 私有实现 ----------------------------------------------------------------

  # 批量 upsert 逐条执行:中途失败即停并返回错误(Ash create 事务包裹时,
  # after_action 抛错/返回 error 会回滚整批,含占位行)。
  defp batch_upsert(records, tenant, actor) do
    Enum.reduce_while(records, {:ok, []}, fn record, {:ok, acc} ->
      changeset =
        __MODULE__
        |> Ash.Changeset.for_create(:upsert_record, record,
          tenant: tenant,
          authorize?: false
        )

      case Ash.create(changeset, tenant: tenant, authorize?: false, actor: actor) do
        {:ok, row} -> {:cont, {:ok, [row | acc]}}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
    |> case do
      {:ok, rows} -> {:ok, Enum.reverse(rows)}
      {:error, reason} -> {:error, reason}
    end
  end

  # upsert_records 的占位行属性:取首条记录的必填字段(同键——首条 upsert 时
  # 覆盖占位行,不产生额外行);空列表在工具层已拒绝,兜底合成合法形状
  defp placeholder_attrs([first | _]) when is_map(first) do
    [
      {:course_id, first[:course_id] || first["course_id"]},
      {:user_id, first[:user_id] || first["user_id"]},
      {:issue_id, first[:issue_id] || first["issue_id"]},
      {:item_id, first[:item_id] || first["item_id"]},
      {:done, first[:done] || first["done"] || false},
      {:recorded_at, first[:recorded_at] || first["recorded_at"] || DateTime.utc_now()}
    ]
  end

  defp placeholder_attrs(_) do
    [
      {:course_id, Ecto.UUID.generate()},
      {:user_id, Ecto.UUID.generate()},
      {:issue_id, "placeholder"},
      {:item_id, "placeholder"},
      {:done, false},
      {:recorded_at, DateTime.utc_now()}
    ]
  end
end
