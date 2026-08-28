defmodule Cgc2046.Accounts.PhoneVerificationCode do
  @moduledoc """
  手机验证码（plan 002 U3）：`phone_verification_codes` 表。

  - `phone`：归一化规范形（`+区号号码`，PhoneNumber 单源）
  - `code_hash`：`SHA256(phone <> ":" <> code)`——明文码不落库
  - `purpose`：`:login`（验证码登录）/ `:wechat_bind`（微信扫码绑定）/ `:register`（手机号注册）/ `:change_phone`（设置页绑定/换绑手机号）
  - `expires_at`：5 分钟
  - `attempts_left`：错码 3 次后失效（防爆破）
  - `consumed_at`：单次使用；原子消费（DB 单条 UPDATE，防并发重放）
  - `send_request_id`：SendCloud 幂等键（透传渠道）

  生命周期（#253 方案 A）：重发不作废旧码——新旧并存且都有效；消费走
  `consume_valid/3`（任一活跃码 hash 命中 → 成功并作废全部活跃码；错码
  仅对最新码递减 attempts，3 次错作废）。过期/耗尽行由 #252
  LoginArtifactPrunerWorker 每小时清理（expires_at < now()-1d）。

  内部资源（#209 SignalIdempotency 惯例）：无 GraphQL 面、无 actor 面，
  模块函数封装全部操作，policy 默认拒绝仅 admin 可读。
  """
  use Ash.Resource,
    data_layer: AshPostgres.DataLayer,
    extensions: [AshAdmin.Resource],
    authorizers: [Ash.Policy.Authorizer],
    domain: Cgc2046.Accounts

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
      constraints: [one_of: [:login, :wechat_bind, :register, :change_phone]],
      description: "用途：login 验证码登录 / wechat_bind 微信扫码绑定 / register 手机号注册 / change_phone 绑定或换绑手机号"
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
  生成 6 位数字码并落库（#253 方案 A：重发不作废旧码——新旧并存，消费
  语义见 `consume_valid/3`）。

  返回 `{:ok, code, send_request_id}`——明文码供发送（不落库），
  send_request_id 是落库的渠道幂等键，供 deliver 上送（重试不重复发）。
  `:dev_sandbox` 模式（SMS 未配置的 dev）由调用方 Logger 输出。
  """
  @spec issue(String.t(), :login | :wechat_bind | :register | :change_phone) ::
          {:ok, String.t(), String.t()} | {:error, term()}
  def issue(phone, purpose)
      when is_binary(phone) and purpose in [:login, :wechat_bind, :register, :change_phone] do
    code = generate_code()
    now = DateTime.utc_now()
    send_request_id = generate_request_id()

    row = %{
      id: Cgc2046.Repo.uuid!(Ecto.UUID.generate()),
      phone: phone,
      code_hash: hash_code(phone, code),
      purpose: Atom.to_string(purpose),
      expires_at: DateTime.add(now, @code_ttl_seconds, :second),
      attempts_left: @max_attempts,
      consumed_at: nil,
      send_request_id: send_request_id,
      inserted_at: now,
      updated_at: now
    }

    case Cgc2046.Repo.insert_all("phone_verification_codes", [row]) do
      {1, _} -> {:ok, code, send_request_id}
      other -> {:error, {:code_insert_failed, other}}
    end
  end

  @doc """
  原子消费（#253 方案 A：多码并存）。

  活跃码集合 = 同 phone+purpose 下未消费、未过期、attempts>0 的全部行。
  集合内任一 code_hash 匹配 → 成功，并**作废全部活跃码**（含未匹配的，
  单次登录会话语义）；无匹配 → 对**最新一码**递减 attempts（3 次错作废；
  只扣最新——攻击者拿不到任何明文码，若对全部递减，攻击者的错尝试会
  加速合法用户旧码死亡，与方案 A 目标相悖）。

  返回 `:ok`（消费成功）/ `{:error, :invalid_code}`（错码，最新码 attempts-1）/
  `{:error, :code_not_available}`（无活跃码：不存在/过期/耗尽/已消费——
  统一语义，防枚举）。
  """
  @spec consume_valid(String.t(), String.t(), :login | :wechat_bind | :register | :change_phone) ::
          :ok | {:error, :invalid_code} | {:error, :code_not_available}
  def consume_valid(phone, code, purpose)
      when is_binary(phone) and is_binary(code) and
             purpose in [:login, :wechat_bind, :register, :change_phone] do
    now = DateTime.utc_now() |> DateTime.truncate(:second)
    hash = hash_code(phone, code)

    case consume_match_any(phone, purpose, hash, now) do
      {:rows, 0} -> decrement_latest_attempt(phone, purpose, now)
      {:rows, _} -> :ok
    end
  end

  # 任一活跃码 hash 命中 → 消费命中行 + 作废全部活跃行（含未命中——单次
  # 会话语义）。两条 UPDATE 由调用方顺序执行：第一条消费命中行，第二条
  # 清余下活跃行；并发双消费时第二条命中 0 行（已被第一条路径清空），
  # 结果收敛一致（后到者 hash 不再匹配任何活跃码 → invalid/not_available）。
  defp consume_match_any(phone, purpose, hash, now) do
    {:ok, %Postgrex.Result{num_rows: matched}} =
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

    if matched > 0 do
      # 作废余下活跃码（登录已完成，全部失效）
      {:ok, _} =
        Ecto.Adapters.SQL.query(
          Cgc2046.Repo,
          """
          UPDATE phone_verification_codes
          SET consumed_at = $3, updated_at = $3
          WHERE phone = $1
            AND purpose = $2
            AND consumed_at IS NULL
            AND expires_at > $3
          """,
          [phone, Atom.to_string(purpose), now]
        )
    end

    {:rows, matched}
  end

  # 错码扣次：仅最新活跃码（inserted_at 最大）——防爆破语义保持 3 次错作废，
  # 且不把旧码一并烧掉（方案 A 目标：重发后旧码仍可用）。
  defp decrement_latest_attempt(phone, purpose, now) do
    {:ok, %Postgrex.Result{num_rows: rows}} =
      Ecto.Adapters.SQL.query(
        Cgc2046.Repo,
        """
        UPDATE phone_verification_codes
        SET attempts_left = attempts_left - 1,
            updated_at = $3
        WHERE id = (
          SELECT id FROM phone_verification_codes
          WHERE phone = $1
            AND purpose = $2
            AND consumed_at IS NULL
            AND expires_at > $3
            AND attempts_left > 0
          ORDER BY inserted_at DESC
          LIMIT 1
        )
        """,
        [phone, Atom.to_string(purpose), now]
      )

    if rows > 0, do: {:error, :invalid_code}, else: {:error, :code_not_available}
  end

  @doc false
  @spec code_ttl_seconds :: pos_integer()
  def code_ttl_seconds, do: @code_ttl_seconds

  # 6 位数字码：rejection sampling（2^24 mod 10^6 ≈ 6% 相对偏差区间外重采样，
  # advisor02 A7——3 字节随机数均匀覆盖 [0, 16_777_216)，超出 16×10^6 的
  # 尾部丢弃重采，保证无偏）
  @code_space 1_000_000
  @code_reject_below 16 * @code_space

  defp generate_code do
    n = :binary.decode_unsigned(:crypto.strong_rand_bytes(3))

    if n >= @code_reject_below do
      generate_code()
    else
      n
      |> rem(@code_space)
      |> Integer.to_string()
      |> String.pad_leading(6, "0")
    end
  end

  defp hash_code(phone, code),
    do: :crypto.hash(:sha256, phone <> ":" <> code) |> Base.encode16(case: :lower)

  defp generate_request_id, do: Ecto.UUID.generate()
end
