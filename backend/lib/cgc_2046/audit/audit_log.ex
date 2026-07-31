defmodule Cgc2046.Audit.AuditLog do
  @moduledoc """
  AuditLog(全局资源,T05,spec §11):每次 API 请求(成功或失败)落一条审计记录。

  字段:actor_id/client/action/resource/workspace_id/ip/result/created_at。
  - actor_id 可空(401 未认证请求无 actor)
  - workspace_id 可空(全局操作如登录失败无 workspace)
  - result 存 HTTP 状态码字符串(如 "200" / "403")

  写入仅系统内部(审计中间件,`authorize?: false`);外部禁止 create(destroy 无)。
  读隔离由 `Cgc2046.Rbac.Checks.AuditLogVisible` 行级 filter 保证:
  用户查自己的,Owner/Admin 查 workspace 的(spec §11)。
  """

  use Ash.Resource,
    data_layer: AshPostgres.DataLayer,
    authorizers: [Ash.Policy.Authorizer],
    domain: Cgc2046.GlobalApi

  attributes do
    uuid_primary_key :id

    attribute :actor_id, :uuid,
      allow_nil?: true,
      public?: true

    attribute :client, :string,
      allow_nil?: true,
      public?: true

    attribute :action, :string,
      allow_nil?: false,
      public?: true

    attribute :resource, :string,
      allow_nil?: true,
      public?: true

    attribute :workspace_id, :uuid,
      allow_nil?: true,
      public?: true

    attribute :ip, :string,
      allow_nil?: true,
      public?: true

    attribute :result, :string,
      allow_nil?: false,
      public?: true

    create_timestamp :inserted_at, public?: true
    update_timestamp :updated_at, public?: true
  end

  actions do
    defaults [:read]

    create :create do
      primary? true
      accept [:actor_id, :client, :action, :resource, :workspace_id, :ip, :result]
    end
  end

  policies do
    policy action_type(:read) do
      authorize_if Cgc2046.Rbac.Checks.AuditLogVisible
      forbid_if always()
    end

    # 外部一律禁止写;审计写入走中间件 authorize?: false
    policy action_type(:create) do
      forbid_if always()
    end
  end

  postgres do
    table "audit_logs"
    repo Cgc2046.Repo
  end
end
