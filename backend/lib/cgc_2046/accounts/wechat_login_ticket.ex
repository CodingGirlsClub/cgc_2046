defmodule Cgc2046.Accounts.WechatLoginTicket do
  @moduledoc """
  微信扫码登录票据（plan 002 U4）：`wechat_login_tickets` 表。

  - `state`：uuid，前端持有的会话标识（qrconnect 的 state 参数），唯一，
    单次使用、10 分钟过期
  - `openid` / `unionid`：换码结果（needs_binding 起落库）
  - `access_token`：sensitive，绑定完成前的凭证（不落日志）
  - `status`：`:pending`（已发码未回调）→ `:needs_binding`（回调但未命中
    已有 identity）→ `:consumed`（登录完成）/ `:expired`
  - 消费/状态迁移全部原子 UPDATE（WHERE status + expires_at）

  内部资源（#209 惯例）：无 GraphQL 面，模块函数封装操作。
  """
  use Ash.Resource,
    data_layer: AshPostgres.DataLayer,
    extensions: [AshAdmin.Resource],
    authorizers: [Ash.Policy.Authorizer],
    domain: Cgc2046.GlobalApi

  @ticket_ttl_seconds 600

  attributes do
    uuid_primary_key(:id)

    attribute(:state, :string,
      allow_nil?: false,
      public?: true,
      description: "会话标识（qrconnect state），单次使用"
    )

    attribute(:openid, :string,
      allow_nil?: true,
      public?: true,
      description: "微信网站应用 openid（换码后落库）"
    )

    attribute(:unionid, :string,
      allow_nil?: true,
      public?: true,
      description: "微信 UnionID（跨应用匹配用，可空）"
    )

    attribute(:access_token, :string,
      allow_nil?: true,
      public?: false,
      sensitive?: true,
      description: "sns access_token（绑定完成前凭证，sensitive 不落日志）"
    )

    attribute(:status, :atom,
      allow_nil?: false,
      public?: true,
      default: :pending,
      constraints: [one_of: [:pending, :needs_binding, :consumed, :expired]],
      description: "票据状态机"
    )

    attribute(:expires_at, :utc_datetime,
      allow_nil?: false,
      public?: true,
      description: "过期时间（创建 +10 分钟）"
    )

    create_timestamp(:inserted_at)
    update_timestamp(:updated_at)
  end

  actions do
    default_accept([:state, :expires_at])
    defaults([:read])
  end

  identities do
    identity(:unique_state, [:state])
  end

  postgres do
    table("wechat_login_tickets")
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
  发新票：生成 uuid state，pending，10 分钟过期。
  """
  @spec issue() :: {:ok, %{state: String.t(), expires_at: DateTime.t()}} | {:error, term()}
  def issue do
    state = Ecto.UUID.generate()
    now = DateTime.utc_now()
    expires_at = DateTime.add(now, @ticket_ttl_seconds, :second)

    row = %{
      id: Cgc2046.Repo.uuid!(Ecto.UUID.generate()),
      state: state,
      openid: nil,
      unionid: nil,
      access_token: nil,
      status: "pending",
      expires_at: expires_at,
      inserted_at: now,
      updated_at: now
    }

    case Cgc2046.Repo.insert_all("wechat_login_tickets", [row]) do
      {1, _} -> {:ok, %{state: state, expires_at: expires_at}}
      other -> {:error, {:ticket_insert_failed, other}}
    end
  end

  @doc false
  @spec ticket_ttl_seconds :: pos_integer()
  def ticket_ttl_seconds, do: @ticket_ttl_seconds

  @doc """
  原子迁移到 needs_binding：命中 pending + 未过期 → 落 openid/unionid/access_token。

  返回 `{:ok, ticket_row}` / `{:error, :ticket_invalid}`（不存在/已用/过期/状态
  不符——统一语义）。
  """
  @spec mark_needs_binding(String.t(), map()) :: {:ok, map()} | {:error, :ticket_invalid}
  def mark_needs_binding(state, %{openid: openid, unionid: unionid, access_token: at}) do
    now = DateTime.utc_now() |> DateTime.truncate(:second)

    {:ok, %Postgrex.Result{num_rows: rows, rows: returned}} =
      Ecto.Adapters.SQL.query(
        Cgc2046.Repo,
        """
        UPDATE wechat_login_tickets
        SET status = 'needs_binding', openid = $2, unionid = $3,
            access_token = $4, updated_at = $5
        WHERE state = $1 AND status = 'pending' AND expires_at > $5
        RETURNING id, state, openid, unionid, status, expires_at
        """,
        [state, openid, unionid, at, now]
      )

    case rows do
      1 ->
        [id, state, openid, unionid, status, expires_at] = hd(returned)

        {:ok,
         %{
           id: id,
           state: state,
           openid: openid,
           unionid: unionid,
           status: status,
           expires_at: expires_at
         }}

      _ ->
        {:error, :ticket_invalid}
    end
  end

  @doc """
  原子消费：命中 needs_binding + 未过期 → consumed。

  返回 `{:ok, ticket_row}`（含 openid/unionid/access_token）/ `{:error, :ticket_invalid}`。
  """
  @spec consume_for_binding(String.t()) :: {:ok, map()} | {:error, :ticket_invalid}
  def consume_for_binding(state) do
    now = DateTime.utc_now() |> DateTime.truncate(:second)

    {:ok, %Postgrex.Result{num_rows: rows, rows: returned}} =
      Ecto.Adapters.SQL.query(
        Cgc2046.Repo,
        """
        UPDATE wechat_login_tickets
        SET status = 'consumed', updated_at = $2
        WHERE state = $1 AND status = 'needs_binding' AND expires_at > $2
        RETURNING id, state, openid, unionid, access_token, expires_at
        """,
        [state, now]
      )

    case rows do
      1 ->
        [id, state, openid, unionid, access_token, expires_at] = hd(returned)

        {:ok,
         %{
           id: id,
           state: state,
           openid: openid,
           unionid: unionid,
           access_token: access_token,
           expires_at: expires_at
         }}

      _ ->
        {:error, :ticket_invalid}
    end
  end

  @doc """
  读取 pending 票（signInWithWechat 验 state 用；不迁移状态——命中 identity
  的迁移在 consume_now/2）。
  """
  @spec fetch_pending(String.t()) :: {:ok, map()} | {:error, :ticket_invalid}
  def fetch_pending(state) do
    {:ok, %Postgrex.Result{rows: rows}} =
      Ecto.Adapters.SQL.query(
        Cgc2046.Repo,
        """
        SELECT id, state, expires_at FROM wechat_login_tickets
        WHERE state = $1 AND status = 'pending' AND expires_at > now()
        """,
        [state]
      )

    case rows do
      [[id, state, expires_at]] ->
        {:ok, %{id: id, state: state, expires_at: expires_at}}

      _ ->
        {:error, :ticket_invalid}
    end
  end

  @doc """
  原子消费 pending 票（已绑定直登路径）：命中 pending + 未过期 → consumed。
  """
  @spec consume_now(String.t()) :: :ok | {:error, :ticket_invalid}
  def consume_now(state) do
    now = DateTime.utc_now() |> DateTime.truncate(:second)

    {:ok, %Postgrex.Result{num_rows: rows}} =
      Ecto.Adapters.SQL.query(
        Cgc2046.Repo,
        """
        UPDATE wechat_login_tickets
        SET status = 'consumed', updated_at = $2
        WHERE state = $1 AND status = 'pending' AND expires_at > $2
        """,
        [state, now]
      )

    if rows == 1, do: :ok, else: {:error, :ticket_invalid}
  end
end
