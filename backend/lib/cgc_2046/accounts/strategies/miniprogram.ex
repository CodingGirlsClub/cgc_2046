defmodule Cgc2046.Accounts.Strategies.Miniprogram do
  @moduledoc """
  小程序平台登录策略（`:miniprogram`，Phase 1 身份基座）。

  流程（全部由 `SignInPreparation` 在 read action 内完成）：
  code2session（Req + Req.Test mock）→ openid/unionid/session_key
  → session_key 解密平台手机号 → phone 锚定 find-or-create User（部分唯一索引 + 竞态重读）
  → upsert UserIdentity（provider/uid/unionid）→ 吊销该 subject 旧 token（重登吊销）
  → 签发带 `platform` claim 的 JWT（存 metadata `:token`，经 httpOnly cookie 交付）。

  红线：session_key 永不出后端（不进响应 / 日志 / DB / error reason）。

  ## 用法

      authentication do
        strategies do
          miniprogram do
            identity_resource Cgc2046.Accounts.UserIdentity
          end
        end
      end
  """

  alias Ash.Resource
  alias AshAuthentication.Strategy.Custom
  alias Spark.Dsl.{Entity, Transformer}

  @entity %Entity{
    name: :miniprogram,
    describe: "小程序平台登录策略（code2session + 手机号锚定统一身份）",
    examples: [
      """
      strategies do
        miniprogram do
          identity_resource Cgc2046.Accounts.UserIdentity
        end
      end
      """
    ],
    target: __MODULE__,
    args: [{:optional, :name, :miniprogram}],
    schema: [
      name: [
        type: :atom,
        doc: "策略名",
        required: true
      ],
      sign_in_action_name: [
        type: :atom,
        doc: "登录 read action 名",
        required: false,
        default: :sign_in_with_miniprogram
      ],
      identity_resource: [
        type: {:behaviour, Ash.Resource},
        doc: "平台身份绑定资源（provider/uid/unionid/user_id）",
        required: true
      ]
    ]
  }

  use Custom, entity: @entity

  defstruct [
    :name,
    :sign_in_action_name,
    :identity_resource,
    :resource,
    :strategy_module,
    :__spark_metadata__
  ]

  @impl Custom
  def transform(strategy, dsl_state) do
    with {:ok, dsl_state} <-
           AshAuthentication.Utils.maybe_build_action(
             dsl_state,
             strategy.sign_in_action_name,
             &build_sign_in_action(&1, strategy)
           ) do
      {:ok, register_strategy_actions([strategy.sign_in_action_name], dsl_state, strategy)}
    end
  end

  defp build_sign_in_action(_dsl_state, strategy) do
    arguments = [
      Transformer.build_entity!(Resource.Dsl, [:actions, :read], :argument,
        name: :platform,
        type: :atom,
        allow_nil?: false,
        constraints: [one_of: [:wechat, :tt, :xhs]],
        description: "小程序平台标识（wechat / tt / xhs）"
      ),
      Transformer.build_entity!(Resource.Dsl, [:actions, :read], :argument,
        name: :code,
        type: :string,
        allow_nil?: false,
        sensitive?: true,
        description: "wx.login / tt.login / xhs.login 返回的临时登录凭证"
      ),
      Transformer.build_entity!(Resource.Dsl, [:actions, :read], :argument,
        name: :encrypted_data,
        type: :string,
        allow_nil?: false,
        sensitive?: true,
        description: "getPhoneNumber 加密数据"
      ),
      Transformer.build_entity!(Resource.Dsl, [:actions, :read], :argument,
        name: :iv,
        type: :string,
        allow_nil?: false,
        sensitive?: true,
        description: "getPhoneNumber 加密初始向量"
      )
    ]

    preparations = [
      Transformer.build_entity!(Resource.Dsl, [:actions, :read], :prepare,
        preparation: Cgc2046.Accounts.Strategies.Miniprogram.SignInPreparation
      )
    ]

    metadata = [
      Transformer.build_entity!(Resource.Dsl, [:actions, :read], :metadata,
        name: :token,
        type: :string,
        allow_nil?: false,
        description: "登录 JWT（claims 含 platform；经 httpOnly cookie 交付，不进响应体）"
      )
    ]

    Transformer.build_entity(Resource.Dsl, [:actions], :read,
      name: strategy.sign_in_action_name,
      arguments: arguments,
      preparations: preparations,
      metadata: metadata,
      get?: true,
      description: "小程序平台一键登录：code2session → 手机号锚定 find-or-create → 签发平台 JWT"
    )
  end
end

defimpl AshAuthentication.Strategy, for: Cgc2046.Accounts.Strategies.Miniprogram do
  @moduledoc false

  import AshAuthentication.Plug.Helpers, only: [store_authentication_result: 2]

  alias Ash.Query
  alias AshAuthentication.{Errors, Info, Strategy}
  alias Cgc2046.Accounts.Strategies.Miniprogram

  @impl Strategy
  def name(strategy), do: strategy.name

  @impl Strategy
  def phases(_strategy), do: [:sign_in]

  @impl Strategy
  def actions(_strategy), do: [:sign_in]

  @impl Strategy
  def routes(strategy) do
    subject_name = Info.authentication_subject_name!(strategy.resource)
    [{"/#{subject_name}/#{strategy.name}/sign_in", :sign_in}]
  end

  @impl Strategy
  def method_for_phase(_strategy, :sign_in), do: :post

  @impl Strategy
  def plug(strategy, :sign_in, conn) do
    params = Map.take(conn.params, ["platform", "code", "encrypted_data", "iv"])
    result = action(strategy, :sign_in, params, [])
    store_authentication_result(conn, result)
  end

  @impl Strategy
  def action(%Miniprogram{} = strategy, :sign_in, params, options) do
    {context, options} = Keyword.pop(options, :context, %{})

    context =
      context
      |> Map.new()
      |> Map.merge(%{private: %{ash_authentication?: true}})

    options = Keyword.put_new_lazy(options, :domain, fn -> Info.domain!(strategy.resource) end)

    strategy.resource
    |> Query.new()
    |> Query.set_context(context)
    |> Query.for_read(strategy.sign_in_action_name, params, options)
    |> Ash.read()
    |> case do
      {:ok, [user]} ->
        {:ok, user}

      {:ok, []} ->
        {:error,
         Errors.AuthenticationFailed.exception(
           strategy: strategy,
           caused_by: %{
             module: __MODULE__,
             strategy: strategy,
             action: :sign_in,
             message: "Query returned no users"
           }
         )}

      {:ok, _users} ->
        {:error,
         Errors.AuthenticationFailed.exception(
           strategy: strategy,
           caused_by: %{
             module: __MODULE__,
             strategy: strategy,
             action: :sign_in,
             message: "Query returned too many users"
           }
         )}

      # 与 password 策略同构：action 层把错误统一收敛为裸 AuthenticationFailed
      # （read 管道会把 forbidden 类错误再包一层 Ash.Error.Forbidden，此处归一），
      # 保持 ash_graphql / ash_authentication_phoenix 的 401 映射语义。
      {:error, error} when is_struct(error, Errors.AuthenticationFailed) ->
        {:error, error}

      {:error, error} when is_exception(error) ->
        {:error, Errors.AuthenticationFailed.exception(strategy: strategy, caused_by: error)}

      {:error, error} ->
        {:error,
         Errors.AuthenticationFailed.exception(
           strategy: strategy,
           caused_by: %{
             module: __MODULE__,
             strategy: strategy,
             action: :sign_in,
             message: "Query returned error: #{inspect(error)}"
           }
         )}
    end
  end

  @impl Strategy
  def tokens_required?(_strategy), do: true
end
