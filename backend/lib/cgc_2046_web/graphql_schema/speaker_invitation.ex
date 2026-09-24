defmodule Cgc2046Web.GraphqlSchema.SpeakerInvitation do
  @moduledoc """
  SpeakerInvitation 域（E-4 #49）GraphQL 面：query / mutation 字段、卡片与 payload 类型；
  手写 resolver 的两个专用 helper（decide_speaker_invitation / speaker_invitation_action_result）
  仅本域使用，留在本文件。
  """

  use Absinthe.Schema.Notation

  import Cgc2046Web.GraphqlSchema.Helpers
  require Logger

  object :speaker_invitation_queries do
    # ── SpeakerInvitation（E-4 #49）──

    @desc "邀请卡片（Speaker 着陆页，无需登录）：token 公开校验，返回邀请主题/时间 + Event 公开信息 + viewerIsInviter；无效/过期/已用 token 统一错误，不泄露其它邀请"
    field :speaker_invitation_card, :speaker_invitation_card do
      arg(:token, non_null(:string))

      resolve(fn _, %{token: token}, %{context: context} ->
        case Cgc2046.Events.SpeakerInvitations.card(token, context[:actor]) do
          {:ok, card} ->
            {:ok, card}

          {:error, _reason} ->
            {:error,
             message: "invitation token is invalid, expired or already used",
             code: "invalid_token"}
        end
      end)
    end

    @desc "某 Event 的 Speaker 邀请列表（仅 Owner/Admin 或平台管理员，read policy 兜底）"
    field :speaker_invitations, non_null(list_of(non_null(:speaker_invitation))) do
      arg(:event_id, non_null(:id))

      resolve(fn _, %{event_id: event_id}, %{context: context} ->
        with_actor(context, fn actor ->
          case Cgc2046.Events.SpeakerInvitations.list_for_event(event_id, actor) do
            {:ok, invitations} ->
              {:ok, invitations}

            {:error, reason} when reason in [:forbidden, :event_not_found] ->
              {:error, [message: "event not found", code: "not_found"]}

            {:error, reason} ->
              # 内部 reason 不透传客户端（#241 F9，SecurityReview 遗留）
              Logger.warning("[speaker_invitations] list_for_event failed: #{inspect(reason)}")
              {:error, [message: "invalid request", code: "invalid"]}
          end
        end)
      end)
    end
  end

  object :speaker_invitation_mutations do
    # ── SpeakerInvitation（E-4 #49；手写 resolver 绕过 read policy 记录加载，同 accept_invitation #96 先例）──

    @desc "Owner/Admin 创建 Speaker 邀请；明文 token 仅经 plainToken 返回一次（库中只存 SHA256 哈希）"
    field :create_speaker_invitation, :create_speaker_invitation_payload do
      arg(:input, non_null(:create_speaker_invitation_input))

      resolve(fn _, %{input: input}, %{context: context} ->
        with %{workspace_id: workspace_id} <- input,
             actor when not is_nil(actor) <- context[:actor],
             {:ok, invitation, plain_token} <-
               Cgc2046.Events.SpeakerInvitation.issue(
                 map_input(input, [
                   :event_id,
                   :speaker_name,
                   :speaker_email,
                   :topic,
                   :scheduled_at,
                   :note,
                   :expires_at
                 ]),
                 actor,
                 workspace_id
               ) do
          {:ok, %{result: invitation, plain_token: plain_token, errors: []}}
        else
          %{} ->
            {:error, [message: "workspaceId is required", code: "invalid_input"]}

          nil ->
            {:error, unauthorized_error()}

          {:error, error} ->
            {:ok,
             %{
               result: nil,
               plain_token: nil,
               errors:
                 to_ash_graphql_errors(
                   error,
                   context,
                   :create_invitation,
                   Cgc2046.Events.SpeakerInvitation,
                   Cgc2046.Events
                 )
             }}
        end
      end)
    end

    @desc "Owner/Admin 重发邀请/重新生成链接：旧链接即刻作废，新明文 token 仅经 plainToken 返回一次；有邮箱的同时异步发出新邮件（尽力而为，不承诺送达）"
    field :resend_speaker_invitation, :resend_speaker_invitation_payload do
      arg(:id, non_null(:id))

      resolve(fn _, %{id: id}, %{context: context} ->
        with_actor(context, fn actor ->
          case Ash.get(Cgc2046.Events.SpeakerInvitation, id, authorize?: false) do
            {:ok, %Cgc2046.Events.SpeakerInvitation{} = invitation} ->
              case Cgc2046.Events.SpeakerInvitation.resend(invitation, actor) do
                {:ok, updated, plain_token} ->
                  {:ok, %{result: updated, plain_token: plain_token, errors: []}}

                {:error, error} ->
                  {:ok,
                   %{
                     result: nil,
                     plain_token: nil,
                     errors:
                       to_ash_graphql_errors(
                         error,
                         context,
                         :resend_invitation,
                         Cgc2046.Events.SpeakerInvitation,
                         Cgc2046.Events
                       )
                   }}
              end

            _ ->
              # id 不存在：与 AshGraphql NotFound 映射同形（message/code），不泄露存在性
              {:ok,
               %{
                 result: nil,
                 plain_token: nil,
                 errors: [%{message: "could not be found", code: "not_found"}]
               }}
          end
        end)
      end)
    end

    @desc "Speaker 用邀请 token 接受邀请（着陆页；token 一次性，接受后失效）"
    field :accept_speaker_invitation, :speaker_invitation_action_payload do
      arg(:token, non_null(:string))

      # 手写 field 不经过 middleware/3 回调，与 admit_member_by_token 一致显式挂载；
      # 限流按 IP+token 计（5 次/15 分钟，复用 RateLimit plug）。
      middleware(Cgc2046Web.Plugs.RateLimit, key_path: [:token])

      resolve(fn _, %{token: token}, context ->
        decide_speaker_invitation(context, token, :accept_invitation)
      end)
    end

    @desc "Speaker 用邀请 token 婉拒邀请（着陆页；token 一次性，婉拒后失效）"
    field :decline_speaker_invitation, :speaker_invitation_action_payload do
      arg(:token, non_null(:string))

      middleware(Cgc2046Web.Plugs.RateLimit, key_path: [:token])

      resolve(fn _, %{token: token}, context ->
        decide_speaker_invitation(context, token, :decline_invitation)
      end)
    end

    @desc "Speaker 保存分享材料（落 WorkflowRun.facts[materials]；Speaker 本人自助或 Owner/Admin 兜底；materials 为 JSON 字符串）"
    field :save_speaker_materials, :speaker_invitation_action_payload do
      arg(:invitation_id, non_null(:id))
      arg(:materials, non_null(:json_string))

      resolve(fn _, %{invitation_id: id, materials: materials}, %{context: context} ->
        with_actor(context, fn actor ->
          # #217 旁路读取（B 类·action 层授权）：read policy 仅 Owner/Admin/
          # PlatformAdmin 视角，Speaker 本人非成员读不到自己的邀请，故 get
          # 直读定位；随后 for_update(:save_materials) 带 actor 走 action
          # policy（speaker_user_id == actor.id 本人 或 Owner/Admin 兜底）。
          case Ash.get(Cgc2046.Events.SpeakerInvitation, id, authorize?: false) do
            {:ok, invitation} when not is_nil(invitation) ->
              invitation
              |> Ash.Changeset.for_update(:save_materials, %{materials: materials},
                actor: actor,
                tenant: invitation.workspace_id
              )
              |> Ash.update(tenant: invitation.workspace_id, actor: actor)
              |> speaker_invitation_action_result(context, :save_materials)

            _ ->
              {:ok,
               %{result: nil, errors: [%{message: "invitation not found", code: "not_found"}]}}
          end
        end)
      end)
    end

    @desc "材料产出后完成邀请（Speaker 本人自助或 Owner/Admin 兜底；accepted → completed）"
    field :complete_speaker_invitation, :speaker_invitation_action_payload do
      arg(:id, non_null(:id))

      resolve(fn _, %{id: id}, %{context: context} ->
        with_actor(context, fn actor ->
          # #217 旁路读取（B 类·action 层授权）：同 save_speaker_materials——
          # get 直读定位，for_update(:complete_speaking) 带 actor 走 action
          # policy（Speaker 本人 或 Owner/Admin 兜底）。
          case Ash.get(Cgc2046.Events.SpeakerInvitation, id, authorize?: false) do
            {:ok, invitation} when not is_nil(invitation) ->
              invitation
              |> Ash.Changeset.for_update(:complete_speaking, %{},
                actor: actor,
                tenant: invitation.workspace_id
              )
              |> Ash.update(tenant: invitation.workspace_id, actor: actor)
              |> speaker_invitation_action_result(context, :complete_speaking)

            _ ->
              {:ok,
               %{result: nil, errors: [%{message: "invitation not found", code: "not_found"}]}}
          end
        end)
      end)
    end
  end

  # ── SpeakerInvitation（E-4 #49；record 类型由 AshGraphql 自动生成 :speaker_invitation，
  # 此处只定义卡片/输入/payload 类型；token_hash 已 hide_fields）──

  object :speaker_invitation_card do
    @desc "token 公开卡片：邀请主题/时间 + Event 公开信息（D2 白名单，不泄露其它邀请）"
    field(:status, non_null(:string))
    field(:topic, :string)
    field(:scheduled_at, :datetime)

    @desc "当前登录用户是否为发出人（匿名为 false；不泄露 invitedBy）"
    field(:viewer_is_inviter, non_null(:boolean))
    field(:event, non_null(:speaker_invitation_card_event))
  end

  object :speaker_invitation_card_event do
    field(:id, non_null(:id))
    field(:slug, :string)
    field(:title, non_null(:string))
    field(:description, :string)
    field(:status, non_null(:string))
  end

  input_object :create_speaker_invitation_input do
    @desc "createSpeakerInvitation 输入：workspaceId + eventId + speakerName 必填，其余可选"
    field(:workspace_id, non_null(:id))
    field(:event_id, non_null(:id))
    field(:speaker_name, non_null(:string))
    field(:speaker_email, :string)
    field(:topic, :string)
    field(:scheduled_at, :datetime)
    field(:note, :string)
    field(:expires_at, :datetime)
  end

  object :create_speaker_invitation_payload do
    @desc "createSpeakerInvitation 返回：result 为邀请记录；plainToken 明文仅此一次"
    field(:result, :speaker_invitation)
    field(:plain_token, :string)
    field(:errors, non_null(list_of(non_null(:mutation_error))))
  end

  object :resend_speaker_invitation_payload do
    @desc "resendSpeakerInvitation 返回：result 为邀请记录；plainToken 新明文仅此一次"
    field(:result, :speaker_invitation)
    field(:plain_token, :string)
    field(:errors, non_null(list_of(non_null(:mutation_error))))
  end

  object :speaker_invitation_action_payload do
    @desc "accept/decline/saveSpeakerMaterials/completeSpeakerInvitation 返回：result + errors 两段式"
    field(:result, :speaker_invitation)
    field(:errors, non_null(list_of(non_null(:mutation_error))))
  end

  # SpeakerInvitation 决策（accept/decline）的 SDL adapter：领域编排在
  # `Events.SpeakerInvitation.decide/3`（token 即凭据定位 + action 复验）；
  # 此处只映射 payload 形状——无效 token 与已用/过期同形返回 payload errors
  # （不防枚举），未登录走 unauthorized 顶层 error。
  defp decide_speaker_invitation(%{context: context}, token, action) do
    case Cgc2046.Events.SpeakerInvitation.decide(context[:actor], token, action) do
      {:ok, invitation} ->
        {:ok, %{result: invitation, errors: []}}

      {:error, :unauthorized} ->
        {:error, unauthorized_error()}

      {:error, :invalid_token} ->
        {:ok,
         %{
           result: nil,
           errors: [
             %{
               message: "invitation token is invalid, expired or already used",
               code: "invalid_token"
             }
           ]
         }}

      {:error, error} ->
        speaker_invitation_action_result({:error, error}, context, action)
    end
  end

  # SpeakerInvitation action 结果 → payload（result + errors 两段式，同 sign_up 错误协议）
  defp speaker_invitation_action_result({:ok, invitation}, _context, _action) do
    {:ok, %{result: invitation, errors: []}}
  end

  defp speaker_invitation_action_result({:error, error}, context, action) do
    {:ok,
     %{
       result: nil,
       errors:
         to_ash_graphql_errors(
           error,
           context,
           action,
           Cgc2046.Events.SpeakerInvitation,
           Cgc2046.Events
         )
     }}
  end
end
