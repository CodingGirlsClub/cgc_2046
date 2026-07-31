defmodule Cgc2046.Workspaces.ApiToken do
  @moduledoc """
  ApiToken(机器/扩展凭证,T07,spec §3):绑定 user_id + workspace_id + 能力域
  scopes 的 API token,供 OpenClacky 扩展(cgc-bridge)访问平台 REST
  (`Authorization: Bearer <token>`)。

  与会话 JWT 的区别:
  - **非 JWT**:平台只存 `token_hash`(SHA-256),**明文不落库**;签发时明文仅
    返回一次,丢失只能重新签发。
  - **绑定 workspace**:认证时校验请求目标 workspace 与 token 绑定一致(不一致 403)。
  - **即时撤销**:撤销 = `revoked_at` 置位;每请求白名单查表(hash 匹配 +
    `revoked_at is nil` + `expires_at > now`),撤销/过期即失效(401)。

  实现说明:
  - 本资源是**全局资源**(domain `Cgc2046.GlobalApi`),不启用 attribute 多租户
    —— 认证时只有 token 明文、没有 tenant 上下文,必须跨租户按 hash 查表;
    `workspace_id` 是普通属性,用于绑定校验与 action 层 RBAC。
  - 签发/撤销是普通 Ash action,受 RBAC:签发 = workspace 成员(为自己签发,
    `user_id` 强制 = actor.id);撤销 = 仅本人(`user_id == actor.id`)。
    因全局资源无 tenant context,授权在 before_action 用 `Rbac.member?/2`
    与属主判定完成(policy 兜底 forbid)。
  - 明文生成在 `issue/3` 模块函数(生成 → hash → `Ash.create!`),不在 action
    内生成,保证明文只存在于调用栈内存,不落库。
  """

  use Ash.Resource,
    data_layer: AshPostgres.DataLayer,
    authorizers: [Ash.Policy.Authorizer],
    domain: Cgc2046.GlobalApi

  @valid_scopes ~w(read workflow:write agent:write)
  @default_ttl_days 30

  attributes do
    uuid_primary_key :id

    attribute :user_id, :uuid,
      allow_nil?: false,
      public?: true

    attribute :workspace_id, :uuid,
      allow_nil?: false,
      public?: true

    attribute :name, :string,
      allow_nil?: false,
      public?: true

    attribute :scopes, {:array, :string},
      allow_nil?: false,
      default: ["read"],
      public?: true

    attribute :token_hash, :string,
      allow_nil?: false,
      sensitive?: true,
      public?: false

    attribute :expires_at, :utc_datetime_usec,
      allow_nil?: false,
      public?: true

    attribute :revoked_at, :utc_datetime_usec,
      allow_nil?: true,
      public?: true

    create_timestamp :inserted_at
    update_timestamp :updated_at
  end

  actions do
    read :read do
      primary? true
    end

    create :issue do
      primary? true
      accept [:name, :scopes, :expires_at, :workspace_id]

      validate fn changeset, _context ->
        scopes = Ash.Changeset.get_attribute(changeset, :scopes) || []
        invalid = scopes -- @valid_scopes

        if invalid == [] do
          :ok
        else
          {:error,
           "invalid scopes: #{Enum.join(invalid, ", ")} (allowed: #{Enum.join(@valid_scopes, ", ")})"}
        end
      end

      validate fn changeset, _context ->
        case Ash.Changeset.get_attribute(changeset, :expires_at) do
          nil ->
            {:error, "expires_at is required"}

          expires_at ->
            if DateTime.compare(expires_at, DateTime.utc_now()) == :gt do
              :ok
            else
              {:error, "expires_at must be in the future"}
            end
        end
      end

      change before_action(fn changeset, context ->
               if context.authorize? != false do
                 ws_id = Ash.Changeset.get_attribute(changeset, :workspace_id)

                 if is_binary(ws_id) and Cgc2046.Rbac.member?(context.actor, ws_id) do
                   changeset
                   |> Ash.Changeset.force_change_attribute(:user_id, context.actor.id)
                 else
                   Ash.Changeset.add_error(changeset, Ash.Error.Forbidden.exception([]))
                 end
               else
                 changeset
               end
             end)
    end

    update :revoke do
      primary? true
      require_atomic? false

      change before_action(fn changeset, context ->
               if context.authorize? != false do
                 if changeset.data.user_id == context.actor.id do
                   Ash.Changeset.force_change_attribute(
                     changeset,
                     :revoked_at,
                     DateTime.utc_now()
                   )
                 else
                   Ash.Changeset.add_error(changeset, Ash.Error.Forbidden.exception([]))
                 end
               else
                 changeset
               end
             end)
    end
  end

  policies do
    policy action_type(:read) do
      authorize_if expr(user_id == ^actor(:id))
      forbid_if always()
    end

    # 签发:认证用户可发起,action 层 before_action 用 Rbac.member? 校验成员并
    # 强制 user_id = actor.id(不满足返回 Forbidden/403)—— 全局资源无 tenant
    # context,成员校验无法在 policy 完成,故在 action 层把关(spec §3 受 RBAC)。
    policy action_type(:create) do
      authorize_if always()
    end

    # 撤销:仅 token 属主本人(user_id == actor.id)
    policy action_type(:update) do
      authorize_if expr(user_id == ^actor(:id))
      forbid_if always()
    end
  end

  postgres do
    table "api_tokens"
    repo Cgc2046.Repo
  end

  @doc "生成明文 API token(URL-safe 随机串)。"
  def generate_token do
    "cgc_" <> Base.url_encode64(:crypto.strong_rand_bytes(32), padding: false)
  end

  @doc "计算 token 的 SHA-256 hash(平台落库值)。"
  def hash_token(plain_token) do
    :crypto.hash(:sha256, plain_token) |> Base.encode16(case: :lower)
  end

  @doc """
  签发 API token:生成明文 → 存 hash → 创建记录,返回 `{record, plain_token}`。

  明文只在返回中出现一次,调用方必须立即展示/保存;后续任何操作只能靠
  明文本身(或撤销)。授权由 `:issue` action 完成(成员校验 + user_id 强制)。
  token_hash 通过 `Ash.Changeset.force_change_attribute` 注入(不在 accept,
  客户端无法伪造 hash)。
  """
  def issue(actor, attrs) do
    plain = generate_token()

    changeset =
      __MODULE__
      |> Ash.Changeset.for_create(:issue, attrs, actor: actor)
      |> Ash.Changeset.force_change_attribute(:token_hash, hash_token(plain))

    case Ash.create(changeset) do
      {:ok, record} -> {:ok, record, plain}
      {:error, error} -> {:error, error}
    end
  end

  @doc "默认有效期(30 天)。"
  def default_ttl_days, do: @default_ttl_days

  @doc "合法 scopes 列表。"
  def valid_scopes, do: @valid_scopes
end
