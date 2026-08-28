defmodule Cgc2046.Admission.CapacityLedger do
  @moduledoc """
  名额账本（ADR-0009 PR⑤ U6；R12-R16；KD2；KTD4/KTD5/KTD7）。

  每个 offering（Event/Course）唯一一行，Admission 独占写权：占位 / 释放的
  原子 CAS 收编于本表（原 `events/courses.confirmed_count` 跨 context 写点
  清零）；offering 上的 `confirmed_count` 退化为展示投影（U7 起由
  `capacity.synced` 信号最终一致同步，Events/Courses 各自订阅自写）。

  ## 字段语义

  - `status` / `capacity` / `registration_deadline`：offering 侧缓存，经
    `*.launched` / `offering.capacity_changed` / `*.ended` 信号回查 Offering
    端口覆盖式更新（KTD4/KTD5，永取最新值，乱序自收敛）。
  - `occupancy`：权威占位计数，仅由 `reserve/2` / `release/2` CAS 改写。
  - `sync_version`：随 occupancy 每次变更单调 +1，同步推进 `capacity.synced` 投影
    （只接受更大版本，覆盖式幂等 + 乱序收敛；缓存字段更新不推进版本）。

  ## 写路径（全部裸 SQL，本模块唯一持有）

  - `reserve/2`：懒建 upsert 兜底（KTD5，无行时 SELECT offering 现值建行，
    与 launched 订阅建行竞态由 `(offering_kind, offering_id)` 唯一索引吸收）
    + CAS `occupancy+1`，守卫三条件复刻原 offering 行语义（`status='open'`、
    `registration_deadline` 未过、`occupancy < capacity`）。
  - `release/2`：CAS `occupancy-1`（`occupancy > 0` 守卫，同原
    `confirmed_count > 0`）。
    reserve / release 写成功后同事务发布 `capacity.synced`（R15；报名占位、
    取消释放、支付超时释放三路径同点收敛于本模块）。
  - `sync_from_offering/1`：订阅方回写缓存字段（occupancy / sync_version
    不动）。

  invite_only 双 CAS 锁序（KTD7）：账本行永远先于 invite_batches 行获取
  （Enrollment prepare_policy 内 reserve → consume_invite_quota 顺序不变）。

  ## 授权面

  纯内部资源：不进 GraphQL（无 graphql 块 / 无 AshGraphql 扩展）；读仅
  platform_admin（观测），写路径全部裸 SQL 不经 Ash action（SignalIdempotency
  同款纪律）。
  """

  use Ash.Resource,
    data_layer: AshPostgres.DataLayer,
    authorizers: [Ash.Policy.Authorizer],
    domain: Cgc2046.Admission

  require Ash.Query

  alias Cgc2046.Repo

  @offering_kinds [:event, :course]
  # offering status 缓存 = Event/Course 状态机全集（draft/open/closed/cancelled）
  @status_values [:draft, :open, :closed, :cancelled]

  attributes do
    uuid_primary_key(:id)

    attribute(:workspace_id, :uuid,
      allow_nil?: false,
      public?: true,
      writable?: false
    )

    attribute(:offering_kind, :atom,
      allow_nil?: false,
      public?: true,
      writable?: false,
      constraints: [one_of: @offering_kinds]
    )

    attribute(:offering_id, :uuid, allow_nil?: false, public?: true, writable?: false)

    attribute(:status, :atom,
      allow_nil?: false,
      public?: true,
      writable?: false,
      constraints: [one_of: @status_values]
    )

    attribute(:capacity, :integer, public?: true, writable?: false)

    attribute(:registration_deadline, :utc_datetime, public?: true, writable?: false)

    attribute(:occupancy, :integer,
      allow_nil?: false,
      default: 0,
      public?: true,
      writable?: false
    )

    attribute(:sync_version, :integer,
      allow_nil?: false,
      default: 0,
      public?: true,
      writable?: false
    )

    create_timestamp(:inserted_at, public?: true)
    update_timestamp(:updated_at)
  end

  multitenancy do
    strategy(:attribute)
    attribute(:workspace_id)
    global?(true)
  end

  relationships do
    belongs_to(:workspace, Cgc2046.Accounts.Workspace, define_attribute?: false)
  end

  identities do
    # R12/KTD5：每个 offering 唯一一行；建行双路（launched 订阅 + 报名懒建）
    # 竞态由本唯一索引幂等吸收
    identity(:unique_offering, [:offering_kind, :offering_id])
  end

  actions do
    defaults([:read])
  end

  postgres do
    table("admission_capacity_ledgers")
    repo(Cgc2046.Repo)
  end

  policies do
    # platform_admin 可读账本行（观测面）；非 admin default-deny（#209 同款）
    policy action_type(:read) do
      authorize_if(Cgc2046.Policies.PlatformAdmin)
    end
  end

  # ── 占位 / 释放（R14：CAS 三条件守卫复刻）────────────────────────────────

  @doc """
  原子占用一个名额：懒建 upsert 兜底（KTD5）后 CAS `occupancy+1`。
  守卫复刻原 offering 行三条件：`status='open'`、`registration_deadline` 未过、
  `capacity` 无限或 `occupancy < capacity`。

  返回 `{:ok, occupancy}`（占位后计数，即 Enrollment `capacity_seq` 语义）/
  `{:error, :capacity_full_or_registration_closed}`（CAS 拒绝）/
  `{:error, {:database, reason}}`。
  """
  @spec reserve(:event | :course, String.t()) ::
          {:ok, integer()} | {:error, :capacity_full_or_registration_closed | {:database, term()}}
  def reserve(kind, offering_id) when kind in @offering_kinds do
    with :ok <- ensure_row(kind, offering_id) do
      sql = """
      UPDATE admission_capacity_ledgers
      SET occupancy = occupancy + 1, sync_version = sync_version + 1, updated_at = NOW()
      WHERE offering_kind = $1 AND offering_id = $2
        AND status = 'open'
        AND (registration_deadline IS NULL OR registration_deadline > NOW())
        AND (capacity IS NULL OR occupancy < capacity)
      RETURNING occupancy, sync_version, workspace_id
      """

      case Repo.query(sql, [Atom.to_string(kind), Repo.uuid!(offering_id)]) do
        {:ok, %{rows: [[occupancy, sync_version, workspace_id]]}} ->
          emit_synced(kind, offering_id, occupancy, sync_version, workspace_id)
          {:ok, occupancy}

        {:ok, %{rows: []}} ->
          {:error, :capacity_full_or_registration_closed}

        {:error, reason} ->
          {:error, {:database, reason}}
      end
    end
  end

  @doc """
  原子释放一个名额（`occupancy > 0` 守卫，同原 `confirmed_count > 0` 语义）。

  `nil` 目标 = 报名从未占位（pending 取消），无名额可释，`:ok`。
  返回 `:ok` / `{:error, :capacity_counter_invalid}`（无行或计数已为 0）/
  `{:error, {:database, reason}}`。
  """
  @spec release({:event | :course, String.t()} | nil) ::
          :ok | {:error, :capacity_counter_invalid | {:database, term()}}
  def release(nil), do: :ok

  def release({kind, offering_id}) when kind in @offering_kinds do
    case Repo.query(
           """
           UPDATE admission_capacity_ledgers
           SET occupancy = occupancy - 1, sync_version = sync_version + 1, updated_at = NOW()
           WHERE offering_kind = $1 AND offering_id = $2 AND occupancy > 0
           RETURNING occupancy, sync_version, workspace_id
           """,
           [Atom.to_string(kind), Repo.uuid!(offering_id)]
         ) do
      {:ok, %{rows: [[occupancy, sync_version, workspace_id]]}} ->
        emit_synced(kind, offering_id, occupancy, sync_version, workspace_id)
        :ok

      {:ok, %{rows: []}} ->
        {:error, :capacity_counter_invalid}

      {:error, reason} ->
        {:error, {:database, reason}}
    end
  end

  # ── 信号同步（KTD4/KTD5：回查 Offering 覆盖式写缓存）──────────────────────

  @doc """
  从 Offering 实体回写账本缓存（launched 建行 / capacity_changed 更新 /
  ended 回查共用）：upsert——无行建行（occupancy/sync_version 归零起步），
  有行覆盖 `status` / `capacity` / `registration_deadline` 三缓存字段，
  occupancy 与 sync_version 不动。覆盖值取自调用方刚读的实体（永远最新），
  重投 / 乱序自收敛。
  """
  @spec sync_from_offering(Cgc2046.Events.Event.t() | Cgc2046.Courses.Course.t()) ::
          :ok | {:error, term()}
  def sync_from_offering(entity) do
    kind = Cgc2046.Offering.kind(entity)

    case Repo.query(
           """
           INSERT INTO admission_capacity_ledgers
             (id, workspace_id, offering_kind, offering_id, status, capacity,
              registration_deadline, occupancy, sync_version, inserted_at, updated_at)
           VALUES (gen_random_uuid(), $1, $2, $3, $4, $5, $6, 0, 0, NOW(), NOW())
           ON CONFLICT (offering_kind, offering_id) DO UPDATE
           SET status = EXCLUDED.status,
               capacity = EXCLUDED.capacity,
               registration_deadline = EXCLUDED.registration_deadline,
               updated_at = NOW()
           """,
           [
             Repo.uuid!(entity.workspace_id),
             Atom.to_string(kind),
             Repo.uuid!(entity.id),
             Atom.to_string(entity.status),
             entity.capacity,
             entity.registration_deadline
           ]
         ) do
      {:ok, _} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  @doc """
  按 offering 读取账本行（测试 / 对账读取面）。
  返回 `{:ok, ledger}` / `{:error, :not_found}`。
  """
  @spec fetch_by_offering(:event | :course, String.t()) ::
          {:ok, __MODULE__.t()} | {:error, :not_found}
  def fetch_by_offering(kind, offering_id) when kind in @offering_kinds do
    __MODULE__
    |> Ash.Query.filter(offering_kind == ^kind and offering_id == ^offering_id)
    |> Ash.read_one(authorize?: false)
    |> case do
      {:ok, nil} -> {:error, :not_found}
      {:ok, ledger} -> {:ok, ledger}
      {:error, _} -> {:error, :not_found}
    end
  end

  # R15：账本写成功后同事务发布 capacity.synced（SignalEmitter 同款事务内
  # outbox——job 与账本行同提交；入队失败 raise 回滚整体，消费方按
  # sync_version 覆盖式收敛）。payload 键走 `event_id`/`course_id` 信号惯例
  # （Offering.fetch_by_signal_payload 同款），occupancy + sync_version 为
  # 本次 CAS RETURNING 的权威值；idempotency_key / workspace_id 注入规范与
  # SignalEmitter 一致（emit_completed 先例）。
  defp emit_synced(kind, offering_id, occupancy, sync_version, workspace_id) do
    target_key = if kind == :event, do: "event_id", else: "course_id"

    data = %{
      target_key => offering_id,
      "occupancy" => occupancy,
      "sync_version" => sync_version,
      "idempotency_key" => "capacity.synced:#{offering_id}",
      # RETURNING 的 uuid 列为 16 字节原始二进制，入 Oban JSON 载荷前转字符串
      "workspace_id" => Ecto.UUID.load!(workspace_id)
    }

    Cgc2046.Workers.SignalPublishWorker.enqueue_in_transaction(
      "capacity.synced",
      data,
      Ecto.UUID.load!(workspace_id)
    )
  end

  # 懒建兜底（KTD5）：无账本行时从 offering 行取最新 status/capacity/deadline
  # 建行（同事务 eligible_target 已 FOR SHARE 该行，读到的即最新已提交值）；
  # 与 launched 订阅建行的竞态由 (offering_kind, offering_id) 唯一索引吸收。
  defp ensure_row(kind, offering_id) do
    table = if kind == :event, do: "events", else: "courses"

    sql = """
    INSERT INTO admission_capacity_ledgers
      (id, workspace_id, offering_kind, offering_id, status, capacity,
       registration_deadline, occupancy, sync_version, inserted_at, updated_at)
    SELECT gen_random_uuid(), o.workspace_id, $2, o.id, o.status, o.capacity,
           o.registration_deadline, 0, 0, NOW(), NOW()
    FROM #{table} o
    WHERE o.id = $1
    ON CONFLICT (offering_kind, offering_id) DO NOTHING
    """

    case Repo.query(sql, [Repo.uuid!(offering_id), Atom.to_string(kind)]) do
      {:ok, _} -> :ok
      {:error, reason} -> {:error, {:database, reason}}
    end
  end
end
