defmodule Cgc2046Web.GraphqlSchema do
  @moduledoc """
  网站端 GraphQL 出口(Absinthe schema)。

  由 AshGraphql 基于注册在两个域(`Cgc2046.GlobalApi` / `Cgc2046.Api`)中的
  资源自动生成,并保留脚手架自带的 `ping` 占位查询作为链路探活。

  T01 阶段无资源,先验证 schema 可生成(`mix ash.codegen`);资源随票据
  注册后自动进入 schema。
  """

  use Absinthe.Schema

  use AshGraphql,
    domains: [Cgc2046.GlobalApi, Cgc2046.Api],
    generate_sdl_file: "priv/graphql/schema.graphql"

  query do
    @desc "Placeholder query until the first resource is added"
    field :ping, :string do
      resolve(fn _, _, _ ->
        {:ok, "pong"}
      end)
    end
  end

  mutation do
    @desc "注册新用户并返回认证 token(全局账号)"
    field :sign_up, :auth_result do
      arg(:email, non_null(:string))
      arg(:password, non_null(:string))

      resolve(&Cgc2046Web.AuthResolver.sign_up/2)
    end

    @desc "登录并返回认证 token(全局账号)"
    field :sign_in, :auth_result do
      arg(:email, non_null(:string))
      arg(:password, non_null(:string))

      resolve(&Cgc2046Web.AuthResolver.sign_in/2)
    end
  end

  object :auth_result do
    field :token, non_null(:string)
    field :user, non_null(:user)
  end

  object :user do
    field :id, non_null(:id)
    field :email, non_null(:string)
  end
end
