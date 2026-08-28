defmodule Cgc2046.Workflows.SignalIdempotency do
  @moduledoc """
  信号幂等键登记表（Slice E 首批共享基础设施）。

  承载 POC-2 G2 B3 硬约束：幂等键去重表**不得由 action 执行进程自建 ETS**
  （进程退出后 named table 随 owner 销毁 → 幂等失效）；生产用 Postgres 唯一
  约束（本表）或 Redis（SETNX/EXPIRE）。报名/赞助/邀请/教研四份 workflow
  共用本表（docs/00-CGC平台设计总纲.md:177 与 §6 模式库、报名 §4.3、
  赞助 §8、邀请 §8、教研 §4.3 的共同规定）。

  ## 用法

      case SignalIdempotency.claim("enrollment.completed", "enrollment.completed:" <> id, workspace_id) do
        :ok -> # 首次登记，执行副作用
        {:error, :already_claimed} -> # 同键已登记，跳过
      end

  去重以 Postgres 唯一索引 `(signal_type, idempotency_key)` 兜底，并发登记
  至多一行成功；`workspace_id` 仅作观测（可空），不影响唯一性。

  ## 授权面（#209）

  写入路径：`claim/3` 以 Repo.insert_all 原始 SQL 登记（唯一索引原子判定，
  不经 Ash action）；读路径：仅 platform_admin（AshAdmin 观测面）；非 admin
  default-deny（fail-closed）。
  """

  use Ash.Resource,
    data_layer: AshPostgres.DataLayer,
    authorizers: [Ash.Policy.Authorizer],
    domain: Cgc2046.Workflows

  alias Cgc2046.Repo

  attributes do
    uuid_primary_key(:id)

    attribute(:workspace_id, :uuid,
      public?: true,
      writable?: true,
      description: "登记时的工作台 ID（观测用，可空；不参与唯一性）"
    )

    attribute(:signal_type, :string,
      allow_nil?: false,
      public?: true,
      writable?: true,
      description: "信号类型（如 \"enrollment.completed\"）"
    )

    attribute(:idempotency_key, :string,
      allow_nil?: false,
      public?: true,
      writable?: true,
      description: "幂等键（如 \"enrollment.completed:<enrollment_id>\"）"
    )

    attribute(:inserted_at, :utc_datetime_usec,
      allow_nil?: false,
      public?: true,
      writable?: true,
      description: "登记时间"
    )
  end

  multitenancy do
    strategy(:attribute)
    attribute(:workspace_id)
    global?(true)
  end

  identities do
    identity(:unique_signal_key, [:signal_type, :idempotency_key])
  end

  actions do
    default_accept([:workspace_id, :signal_type, :idempotency_key, :inserted_at])
    defaults([:read])
  end

  policies do
    # platform_admin 可读幂等登记（AshAdmin 观测面）；非 admin default-deny（#209）
    policy action_type(:read) do
      authorize_if(Cgc2046.Accounts.Policies.PlatformAdmin)
    end
  end

  postgres do
    table("signal_idempotency")
    repo(Cgc2046.Repo)
  end

  @doc """
  尝试登记幂等键。返回 `:ok`（首次登记）或 `{:error, :already_claimed}`
  （同 `(signal_type, idempotency_key)` 已存在）。并发下由唯一索引保证至多
  一方登记成功。
  """
  @spec claim(String.t(), String.t(), String.t() | nil) :: :ok | {:error, :already_claimed}
  def claim(signal_type, idempotency_key, workspace_id \\ nil) do
    row = %{
      id: Repo.uuid!(Ecto.UUID.generate()),
      workspace_id: workspace_id && Repo.uuid!(workspace_id),
      signal_type: signal_type,
      idempotency_key: idempotency_key,
      inserted_at: DateTime.utc_now()
    }

    case Repo.insert_all("signal_idempotency", [row],
           on_conflict: :nothing,
           conflict_target: [:signal_type, :idempotency_key]
         ) do
      {1, _} -> :ok
      {0, _} -> {:error, :already_claimed}
    end
  end
end
