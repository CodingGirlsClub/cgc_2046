defmodule Cgc2046.Accounts.UserIdentity do
  @moduledoc """
  平台身份绑定（Phase 1 身份基座，Q1）：全局 User 与小程序平台身份的关联。

  - `provider`：平台标识（`:wechat` / `:tt` / `:xhs`）
  - `uid`：平台侧用户唯一标识（openid）
  - `unionid`：平台生态内跨应用统一标识（微信/抖音 UnionID 机制；为 V2 视频号/V3 企业微信预留，可空）
  - `user_id`：锚定的全局 User

  唯一约束 `(provider, uid)`：同一平台账号只绑定一个 User。
  登录即挂 Identity（`:upsert` action，ON CONFLICT 更新 unionid/user_id——
  平台账号当前验证手机号是 User 锚，换绑手机号后 Identity 随新锚重指向）。

  不暴露 GraphQL；session_key 等会话材料一律不落库（红线）。
  """
  use Ash.Resource,
    data_layer: AshPostgres.DataLayer,
    extensions: [AshAdmin.Resource],
    authorizers: [Ash.Policy.Authorizer],
    domain: Cgc2046.Accounts

  attributes do
    uuid_primary_key(:id)

    attribute(:provider, :atom,
      allow_nil?: false,
      public?: true,
      writable?: true,
      constraints: [one_of: [:wechat, :tt, :xhs, :wechat_web]],
      description: "平台标识（:wechat/:tt/:xhs 小程序；:wechat_web 开放平台网站应用，plan 002 U4）"
    )

    attribute(:uid, :string,
      allow_nil?: false,
      public?: true,
      writable?: true,
      description: "平台侧 openid"
    )

    attribute(:unionid, :string,
      allow_nil?: true,
      public?: true,
      writable?: true,
      description: "平台 UnionID（可空，平台满足 UnionID 条件时返回）"
    )

    create_timestamp(:inserted_at)
    update_timestamp(:updated_at)
  end

  relationships do
    belongs_to(:user, Cgc2046.Accounts.User, allow_nil?: false)
  end

  actions do
    defaults([:read])

    create :upsert do
      description("登录即挂 Identity：按 (provider, uid) upsert；冲突时更新 unionid/user_id（手机号锚定重指向）")

      accept([:provider, :uid, :unionid, :user_id])
      upsert?(true)
      upsert_identity(:unique_provider_uid)
      upsert_fields([:unionid, :user_id])
    end
  end

  identities do
    identity(:unique_provider_uid, [:provider, :uid])
  end

  postgres do
    table("user_identities")
    repo(Cgc2046.Repo)
  end

  policies do
    # 仅策略内部经 ash_authentication 私有 context 调用（无 actor 面、无 GraphQL 面）
    bypass AshAuthentication.Checks.AshAuthenticationInteraction do
      authorize_if(always())
    end
  end

  admin do
    # #113 ops 面优化：导航分组
    resource_group(:accounts)
  end
end
