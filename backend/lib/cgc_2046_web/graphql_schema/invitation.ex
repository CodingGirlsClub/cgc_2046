defmodule Cgc2046Web.GraphqlSchema.Invitation do
  @moduledoc """
  工作台邀请与小程序入席 GraphQL 面（`generate_mini_program_code` /
  `admit_member_by_token` / `accept_invitation` 及其结果/输入类型）；
  注：`validate_invitation` 的 `middleware/3` 限流回调由 Absinthe 框架只对根
  `GraphqlSchema` 模块调用，故留在根 schema。
  """

  use Absinthe.Schema.Notation

  import Cgc2046Web.GraphqlSchema.Helpers

  object :miniprogram_code_result do
    field(:invitation_id, non_null(:id))
    field(:platform, non_null(:string))
    field(:scene, non_null(:string))
    field(:code_base64, non_null(:string))
    field(:expires_at, non_null(:datetime))
  end

  # acceptInvitation 手写 resolver 的类型（#96）：与自动生成的同名同形，
  # API 形态不变（acceptInvitation(id: ID!, input: AcceptInvitationInput!): AcceptInvitationResult!）。
  input_object :accept_invitation_input do
    @desc "acceptInvitation 输入：token 为明文邀请令牌（accept 须复验）"
    field(:token, non_null(:string))
  end

  object :accept_invitation_result do
    @desc "acceptInvitation 返回：result 为已接受邀请记录；errors 为业务错误"
    field(:result, :invitation)
    field(:errors, non_null(list_of(non_null(:mutation_error))))
  end

  object :invitation_mutations do
    @desc "Owner/Admin 创建一次性工作台邀请小程序码"
    field :generate_mini_program_code, :miniprogram_code_result do
      arg(:workspace_id, non_null(:id))
      arg(:platform, non_null(:string))

      middleware(Cgc2046Web.Plugs.RateLimit, key_path: [:workspace_id])

      resolve(fn _, %{workspace_id: workspace_id, platform: platform}, %{context: context} ->
        with_actor(context, fn actor ->
          case Cgc2046.Accounts.MiniprogramCode.generate(workspace_id, actor, platform) do
            {:ok, result} ->
              {:ok, result}

            {:error, :forbidden} ->
              {:error, message: "Forbidden", code: "forbidden"}

            {:error, :invalid_platform} ->
              {:error, message: "Invalid platform", code: "invalid_platform"}

            {:error, :daily_quota_exhausted} ->
              {:error, message: "Daily quota exhausted", code: "daily_quota_exhausted"}

            # 锁超时/死锁（#621）：BusinessError 原样出面（message 逐字 + 独立 code），
            # 不落下面 code_generation_failed 兜底——可自愈并发冲突不是"生成失败"。
            {:error, %Cgc2046.Errors.BusinessError{code: code, message: message}} ->
              {:error, message: message, code: code}

            {:error, _} ->
              {:error, message: "Code generation failed", code: "code_generation_failed"}
          end
        end)
      end)
    end

    @desc "使用一次性小程序 scene 接受工作台邀请"
    field :admit_member_by_token, :invitation do
      arg(:scene, non_null(:string))

      middleware(Cgc2046Web.Plugs.RateLimit, key_path: [:scene])

      resolve(fn _, %{scene: scene}, %{context: context} ->
        cond do
          is_nil(context[:actor]) ->
            {:error, unauthorized_error()}

          not Cgc2046.Accounts.MiniprogramCode.valid_scene?(scene) ->
            {:error, message: "Invalid scene", code: "invalid_scene"}

          true ->
            actor = context[:actor]

            # #217 旁路读取（A 类·凭证即凭据）：一次性小程序 scene 码经
            # code_for_scene 校验（scene + 未过期精确匹配）换得 invitation_id，
            # Ash.get 直读定位（Invitation read policy 是 inviter/Owner-Admin
            # 视角，受邀者被拒成 not_found 到不了 action）；随后 for_update 带
            # actor 走 accept_miniprogram 的 actor_present 门禁，before_action
            # scene 复验（已用/过期 → invalid_or_expired_scene）。
            with {:ok, code} <- Cgc2046.Accounts.MiniprogramCode.code_for_scene(scene),
                 {:ok, invitation} <-
                   Ash.get(Cgc2046.Accounts.Invitation, code.invitation_id, authorize?: false),
                 {:ok, accepted} <-
                   invitation
                   |> Ash.Changeset.for_update(:accept_miniprogram, %{scene: scene})
                   |> Ash.update(actor: actor) do
              {:ok, accepted}
            else
              {:error, :invalid_scene} ->
                {:error, message: "Invalid scene", code: "invalid_scene"}

              {:error, :invalid_or_expired_scene} ->
                {:error,
                 message: "Invitation has already been used or scene has expired",
                 code: "invalid_or_expired_scene"}

              {:error, error} ->
                {:error,
                 to_ash_graphql_errors(
                   error,
                   context,
                   :accept_miniprogram,
                   Cgc2046.Accounts.Invitation
                 )}
            end
        end
      end)
    end

    @desc "接受邀请→建 Membership + 预授权角色入座（#96：手写 resolver 绕过 read policy 记录加载）"
    field :accept_invitation, :accept_invitation_result do
      arg(:id, non_null(:id))
      arg(:input, non_null(:accept_invitation_input))

      # 手写 field 不经过 middleware/3 回调（那是 AshGraphql 自动 mutation 的接线），
      # 与 admit_member_by_token 一致显式挂载；限流 key 与自动 mutation 相同（input.token）。
      middleware(Cgc2046Web.Plugs.RateLimit, key_path: [:input, :token])

      resolve(fn _, %{id: id, input: %{token: token}}, %{context: context} ->
        with_actor(context, fn actor ->
          # #96：AshGraphql update mutation 的 read-before-write 用 :read action 加载记录
          # （read policy 下推成 inviter_id == actor.id），受邀者被拒成 not_found，到不了
          # accept action。这里改为 id + token_hash 双因子定位 + authorize?: false 加载：
          # 两个条件都匹配才放行（token 是凭证，与 validateInvitation 信息面一致），
          # 不匹配返回 not_found，不泄露邀请存在性。accept action 的
          # authorize_if(actor_present()) 与 before_action token 复验仍完整生效。
          # TokenCredential.fetch 以 extra_filter: [id: id] 保留双因子，nil 塌缩为
          # :invalid_token，由调用方映射回 accept_not_found_errors（not_found 语义）。
          with {:ok, invitation} <-
                 Cgc2046.Accounts.TokenCredential.fetch(Cgc2046.Accounts.Invitation, token,
                   id: id
                 ),
               {:ok, accepted} <-
                 invitation
                 |> Ash.Changeset.for_update(:accept, %{token: token})
                 |> Ash.update(actor: actor) do
            {:ok, %{result: accepted, errors: []}}
          else
            {:error, :invalid_token} ->
              {:ok, %{result: nil, errors: accept_not_found_errors(context, id)}}

            {:error, error} ->
              {:ok,
               %{
                 result: nil,
                 errors:
                   to_ash_graphql_errors(
                     error,
                     context,
                     :accept,
                     Cgc2046.Accounts.Invitation
                   )
               }}
          end
        end)
      end)
    end
  end

  # acceptInvitation 的 not_found：id+token 双因子不匹配时返回，与 AshGraphql 自动 mutation
  # 的 NotFound 映射一致（message "could not be found" / code "not_found"），复用同一序列化路径。
  defp accept_not_found_errors(context, id) do
    error =
      Ash.Error.Query.NotFound.exception(
        primary_key: %{id: id},
        resource: Cgc2046.Accounts.Invitation
      )

    to_ash_graphql_errors(error, context, :accept, Cgc2046.Accounts.Invitation)
  end
end
