defmodule Cgc2046.Accounts.PhoneVerificationCode do
  @moduledoc """
  手机验证码（plan 002 U3）：`phone_verification_codes` 表。

  - `phone`：归一化规范形（`+区号号码`，PhoneNumber 单源）
  - `code_hash`：`SHA256(phone <> ":" <> code)`——明文码不落库
  - `purpose`：`:login`（验证码登录）/ `:wechat_bind`（微信扫码绑定）
  - `expires_at`：5 分钟
  - `attempts_left`：错码 3 次后失效（防爆破）
  - `consumed_at`：单次使用；原子消费（DB 单条 UPDATE，防并发重放）
  - `send_request_id`：SendCloud 幂等键（透传渠道）

  生命周期：发新码作废同 phone+purpose 全部活跃码（`invalidate_active/2`）；
  消费走 `consume_valid/3` 原子 UPDATE（WHERE consumed_at IS NULL AND
  attempts_left > 0 AND expires_at > now()）。过期行懒清理（v1：消费失败即弃，
  不再扫描全表）。

  内部资源（#209 SignalIdempotency 惯例）：无 GraphQL 面、无 actor 面，
  模块函数封装全部操作，policy 默认拒绝仅 admin 可读。
  """
  use Ash.Resource,
    data_layer: AshPostgres.DataLayer,
    extensions: [AshAdmin.Resource],
    authorizers: [Ash.Policy.Authorizer],
    domain: Cgc2046.GlobalApi

  @code_ttl_seconds 300
  @max_attempts 3

  attributes do
    uuid_primary_key(:id)

    attribute(:phone, :string,
      allow_nil?: false,
      public?: true,
      sensitive?: true,
      description: "手机号（归一化规范形，明文存储与 users.phone 同口径）"
    )

    attribute(:code_hash, :string,
      allow_nil?: false,
      public?: false,
      sensitive?: true,
      description: "SHA256(phone <> \":\" <> code)，明文验证码不落库"
    )

    attribute(:purpose, :atom,
      allow_nil?: false,
      public?: true,
      constraints: [one_of: [:login, :wechat_bind]],
      description: "用途：login 验证码登录 / wechat_bind 微信扫码绑定"
    )

    attribute(:expires_at, :utc_datetime,
      allow_nil?: false,
      public?: true,
      description: "过期时间（创建 +5 分钟）"
    )

    attribute(:attempts_left, :integer,
      allow_nil?: false,
      public?: true,
      default: @max_attempts,
      description: "剩余尝试次数（错码递减，0 即失效）"
    )

    attribute(:consumed_at, :utc_datetime,
      allow_nil?: true,
      public?: true,
      description: "消费时间（非空即已用，单次使用）"
    )

    attribute(:send_request_id, :string,
      allow_nil?: false,
      public?: true,
      description: "SendCloud 幂等键"
    )

    create_timestamp(:inserted_at)
    update_timestamp(:updated_at)
  end

  actions do
    default_accept([:phone, :code_hash, :purpose, :expires_at, :send_request_id])
    defaults([:read])
  end

  postgres do
    table("phone_verification_codes")
    repo(Cgc2046.Repo)
  end

  policies do
    # 内部资源：仅 platform_admin 经 AshAdmin 观测；非 admin default-deny（#209）
    policy action_type(:read) do
      authorize_if(Cgc2046.Policies.PlatformAdmin)
    end
  end

  admin do
    resource_group(:accounts)
  end

  # ── 模块函数（内部操作面）──────────────────────────────────────────────

  @doc """
  生成 6 位数字码并落库；作废同 phone+purpose 全部活跃码（发新码作废旧码）。

  返回明文码（供发送，不落库）。`:dev_sandbox` 模式（SMS 未配置的 dev）由
  调用方 Logger 输出。
  """
  @spec issue(String.t(), :login | :wechat_bind) :: {:ok, String.t()} | {:error, term()}
  def issue(phone, purpose) when is_binary(phone) and purpose in [:login, :wechat_bind] do
    code = generate_code()
    now = DateTime.utc_now()

    row = %{
      id: Cgc2046.Repo.uuid!(Ecto.UUID.generate()),
      phone: phone,
      code_hash: hash_code(phone, code),
      purpose: Atom.to_string(purpose),
      expires_at: DateTime.add(now, @code_ttl_seconds, :second),
      attempts_left: @max_attempts,
      consumed_at: nil,
      send_request_id: generate_request_id(),
      inserted_at: now,
      updated_at: now
    }

    case Cgc2046.Repo.insert_all("phone_verification_codes", [row]) do
      {1, _} ->
        invalidate_active(phone, purpose, row[:id])
        {:ok, code}

      other ->
        {:error, {:code_insert_failed, other}}
    end
  end

  @doc """
  原子消费：单条 UPDATE 校验 hash + 未消费 + 有余次 + 未过期，命中即
  attempts_left-1 并置 consumed_at（+1 次错码扣次不消费，仍单条 UPDATE）。

  返回 `:ok`（消费成功）/ `{:error, :invalid_code}`（错码，attempts-1）/
  `{:error, :code_not_available}`（无可用码：不存在/过期/耗尽/已消费——
  统一语义，防枚举）。
  """
  @spec consume_valid(String.t(), String.t(), :login | :wechat_bind) ::
          :ok | {:error, :invalid_code} | {:error, :code_not_available}
  def consume_valid(phone, code, purpose)
      when is_binary(phone) and is_binary(code) and purpose in [:login, :wechat_bind] do
    now = DateTime.utc_now() |> DateTime.truncate(:second)
    hash = hash_code(phone, code)

    # 两步原子 UPDATE：
    # 1) 命中正确 hash 且可用 → 消费（consumed_at 置 now）
    # 2) 未命中（活跃码存在）→ 错码扣次（attempts-1，不消费）
    case consume_match(phone, purpose, hash, now) do
      {:rows, 1} -> :ok
      {:rows, _} -> decrement_attempt(phone, purpose, now)
    end
  end

  defp consume_match(phone, purpose, hash, now) do
    {:ok, %Postgrex.Result{num_rows: rows}} =
      Ecto.Adapters.SQL.query(
        Cgc2046.Repo,
        """
        UPDATE phone_verification_codes
        SET attempts_left = attempts_left - 1,
            consumed_at = $4,
            updated_at = $4
        WHERE phone = $1
          AND purpose = $2
          AND consumed_at IS NULL
          AND expires_at > $4
          AND attempts_left > 0
          AND code_hash = $3
        """,
        [phone, Atom.to_string(purpose), hash, now]
      )

    {:rows, rows}
  end

  defp decrement_attempt(phone, purpose, now) do
    {:ok, %Postgrex.Result{num_rows: rows}} =
      Ecto.Adapters.SQL.query(
        Cgc2046.Repo,
        """
        UPDATE phone_verification_codes
        SET attempts_left = attempts_left - 1,
            updated_at = $3
        WHERE phone = $1
          AND purpose = $2
          AND consumed_at IS NULL
          AND expires_at > $3
          AND attempts_left > 0
        """,
        [phone, Atom.to_string(purpose), now]
      )

    if rows > 0, do: {:error, :invalid_code}, else: {:error, :code_not_available}
  end

  @doc """
  作废同 phone+purpose 全部活跃码（除 `except_id`）——发新码时调用。
  """
  @spec invalidate_active(String.t(), :login | :wechat_bind, Ecto.UUID.t()) :: :ok
  def invalidate_active(phone, purpose, except_id)
      when is_binary(phone) and purpose in [:login, :wechat_bind] do
    now = DateTime.utc_now() |> DateTime.truncate(:second)

    {:ok, _} =
      Ecto.Adapters.SQL.query(
        Cgc2046.Repo,
        """
        UPDATE phone_verification_codes
        SET consumed_at = $4, updated_at = $4
        WHERE phone = $1
          AND purpose = $2::text::phone_verification_purpose
          AND consumed_at IS NULL
          AND id <> $3::uuid
        """,
        [phone, Atom.to_string(purpose), except_id, now]
      )

    :ok
  end

  @doc false
  @spec code_ttl_seconds :: pos_integer()
  def code_ttl_seconds, do: @code_ttl_seconds

  # 6 位数字码：crypto 强随机，均匀取模（10^6 无偏区间内）
  defp generate_code do
    n = :binary.decode_unsigned(:crypto.strong_rand_bytes(3))

    n
    |> rem(1_000_000)
    |> Integer.to_string()
    |> String.pad_leading(6, "0")
  end

  defp hash_code(phone, code),
    do: :crypto.hash(:sha256, phone <> ":" <> code) |> Base.encode16(case: :lower)

  defp generate_request_id, do: Ecto.UUID.generate()
end
