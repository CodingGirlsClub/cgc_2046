defmodule Cgc2046Web.GraphqlSchema.Flashback.Mutations do
  @moduledoc """
  闪念间（In a Flash）写面上半：首程 token 面与愿望/留言 mutation
  （enter … delete_wish_comment）。
  """

  use Absinthe.Schema.Notation

  import Cgc2046Web.GraphqlSchema.Helpers
  import Cgc2046Web.GraphqlSchema.Flashback.Helpers

  object :flashback_mutations do
    # ── 闪念间（In a Flash）首程 token 面（U2，KTD2：链接即身份，免登录）────
    # 全部手写 field + 显式 RateLimit（手写 field 不经 middleware/3 回调，同
    # acceptInvitation 先例）；token 不进 next 参数、不跨 locale 跳转传递。
    # 业务实现单源 Cgc2046.Flashback.Tokens（含错误码字面量，进 #241 契约）。

    @desc "闪念间首程进入（R1/R2）：token 分流记忆线/圆梦线；失效原因可区分（not_found/claimed/revoked），写 link_opened 行为事件"
    field :flashback_enter, :flashback_enter_result do
      arg(:token, non_null(:string))

      # 阈值 30/15min：完整首程（enter→revealed→submit→quote→send）5 次 +
      # 回访/重试/注册发码余量；默认 5 次会让合法旅程必然撞限（e2e 实测）
      middleware(Cgc2046Web.Plugs.RateLimit, key_path: [:token], max_attempts: 30)

      resolve(fn _, %{token: token}, _ ->
        flashback_call(fn -> Cgc2046.Flashback.Tokens.enter(token) end)
      end)
    end

    @desc "认领显影完成（四率之 revealed；其余三事件由后端在对应 mutation 内写入）"
    field :flashback_mark_revealed, :flashback_touch_result do
      arg(:token, non_null(:string))

      # 阈值 30/15min：完整首程（enter→revealed→submit→quote→send）5 次 +
      # 回访/重试/注册发码余量；默认 5 次会让合法旅程必然撞限（e2e 实测）
      middleware(Cgc2046Web.Plugs.RateLimit, key_path: [:token], max_attempts: 30)

      resolve(fn _, %{token: token}, _ ->
        flashback_call(fn -> Cgc2046.Flashback.Tokens.mark_revealed(token) end)
      end)
    end

    @desc "提交「今天的你」（R8/R18/R19/R20，覆盖式；token 面写 intent_submitted）；联系方式更新走独立验证通道 flashbackUpdateContact。U9 起双入口：token 省略时按登录账号绑定档案（回访编辑不重计意图率）"
    field :flashback_submit_today, :flashback_today_result do
      arg(:token, :string)
      arg(:input, non_null(:flashback_today_input))

      # 阈值 30/15min：完整首程（enter→revealed→submit→quote→send）5 次 +
      # 回访/重试/注册发码余量；默认 5 次会让合法旅程必然撞限（e2e 实测）
      middleware(Cgc2046Web.Plugs.RateLimit, key_path: [:token], max_attempts: 30)

      resolve(fn _, args, %{context: context} ->
        flashback_call(fn ->
          with {:ok, identity} <- flashback_identity(args[:token], context) do
            case identity do
              {:token, token} ->
                Cgc2046.Flashback.Tokens.submit_today(token, today_params(args[:input]))

              {:person, person_id} ->
                Cgc2046.Flashback.Tokens.submit_today_as_person(
                  person_id,
                  today_params(args[:input])
                )
            end
          end
        end)
      end)
    end

    @desc "寄出上墙（R11，幂等；token 旅程写 sent_to_wall touch）：返回注册引导掩码回显（R27）。#931 起 token 省略时按登录账号绑定档案"
    field :flashback_send_to_wall, :flashback_send_to_wall_result do
      # #931 起双入口：token 省略时按登录账号绑定档案（认领作废 token 后的唯一入口）
      arg(:token, :string)

      # 阈值 30/15min：完整首程（enter→revealed→submit→quote→send）5 次 +
      # 回访/重试/注册发码余量；默认 5 次会让合法旅程必然撞限（e2e 实测）
      middleware(Cgc2046Web.Plugs.RateLimit, key_path: [:token], max_attempts: 30)

      resolve(fn _, args, %{context: context} ->
        flashback_call(fn ->
          with {:ok, identity} <- flashback_identity(args[:token], context) do
            case identity do
              {:token, token} -> Cgc2046.Flashback.Tokens.send_to_wall(token)
              {:person, person_id} -> Cgc2046.Flashback.Tokens.send_to_wall_as_person(person_id)
            end
          end
        end)
      end)
    end

    @desc "撤下（R30 免注册一键）：sent_to_wall_at 清回 nil，名册回到结构化卡。#931 起 token 省略时按登录账号绑定档案"
    field :flashback_retract, :flashback_retract_result do
      # #931 起双入口：token 省略时按登录账号绑定档案
      arg(:token, :string)

      # 阈值 30/15min：完整首程（enter→revealed→submit→quote→send）5 次 +
      # 回访/重试/注册发码余量；默认 5 次会让合法旅程必然撞限（e2e 实测）
      middleware(Cgc2046Web.Plugs.RateLimit, key_path: [:token], max_attempts: 30)

      resolve(fn _, args, %{context: context} ->
        flashback_call(fn ->
          with {:ok, identity} <- flashback_identity(args[:token], context) do
            case identity do
              {:token, token} -> Cgc2046.Flashback.Tokens.retract(token)
              {:person, person_id} -> Cgc2046.Flashback.Tokens.retract_as_person(person_id)
            end
          end
        end)
      end)
    end

    @desc "调整雾面区间（R16/KTD4）：只改 fog_spans，原文不可达。U9 起双入口：token 省略时按登录账号绑定档案"
    field :flashback_adjust_fog, :flashback_adjust_fog_result do
      arg(:token, :string)
      arg(:answer_id, non_null(:id))
      arg(:spans, non_null(list_of(non_null(:flashback_fog_span_input))))

      # 阈值 30/15min：完整首程（enter→revealed→submit→quote→send）5 次 +
      # 回访/重试/注册发码余量；默认 5 次会让合法旅程必然撞限（e2e 实测）
      middleware(Cgc2046Web.Plugs.RateLimit, key_path: [:token], max_attempts: 30)

      resolve(fn _, args, %{context: context} ->
        flashback_call(fn ->
          with {:ok, identity} <- flashback_identity(args[:token], context) do
            case identity do
              {:token, token} ->
                Cgc2046.Flashback.Tokens.adjust_fog(token, args[:answer_id], args[:spans])

              {:person, person_id} ->
                Cgc2046.Flashback.Tokens.adjust_fog_as_person(
                  person_id,
                  args[:answer_id],
                  args[:spans]
                )
            end
          end
        end)
      end)
    end

    # 今天的你句级雾面：field ∈ now/want/need/say，spans 与当年雾面同坐标同校验；双入口
    field :flashback_adjust_today_fog, :flashback_adjust_today_fog_result do
      arg(:token, :string)
      arg(:field, non_null(:string))
      arg(:spans, non_null(list_of(non_null(:flashback_fog_span_input))))

      middleware(Cgc2046Web.Plugs.RateLimit, key_path: [:token], max_attempts: 30)

      resolve(fn _, args, %{context: context} ->
        flashback_call(fn ->
          with {:ok, identity} <- flashback_identity(args[:token], context) do
            case identity do
              {:token, token} ->
                Cgc2046.Flashback.Tokens.adjust_today_fog(token, args[:field], args[:spans])

              {:person, person_id} ->
                Cgc2046.Flashback.Tokens.adjust_today_fog_as_person(
                  person_id,
                  args[:field],
                  args[:spans]
                )
            end
          end
        end)
      end)
    end

    @desc "金句授权（R31 两档 + 关）：level ∈ off/anonymous/credited，默认关。U9 起双入口：token 省略时按登录账号绑定档案"
    field :flashback_set_quote_license, :flashback_quote_license_result do
      arg(:token, :string)
      arg(:level, non_null(:string))
      arg(:chosen_quote_spans, list_of(:flashback_quote_span_input))
      arg(:credited_note, :string)

      # 阈值 30/15min：完整首程（enter→revealed→submit→quote→send）5 次 +
      # 回访/重试/注册发码余量；默认 5 次会让合法旅程必然撞限（e2e 实测）
      middleware(Cgc2046Web.Plugs.RateLimit, key_path: [:token], max_attempts: 30)

      resolve(fn _, %{level: level} = args, %{context: context} ->
        if level in ["off", "anonymous", "credited"] do
          # 只写客户端实际传了的字段：没传 = 保留原值，显式传 null = 清空。此前没传也按 nil 写入，
          # 小程序改档位从不传 creditedNote，每次保存都把实名补充清空
          params =
            args
            |> Map.take([:chosen_quote_spans, :credited_note])
            |> Map.put(:level, level)

          flashback_call(fn ->
            with {:ok, identity} <- flashback_identity(args[:token], context) do
              case identity do
                {:token, token} ->
                  Cgc2046.Flashback.Tokens.set_quote_license(token, params)

                {:person, person_id} ->
                  Cgc2046.Flashback.Tokens.set_quote_license_as_person(person_id, params)
              end
            end
          end)
        else
          {:error, message: "Invalid quote license level", code: "invalid_input"}
        end
      end)
    end

    @desc "卡片分享开关（#771）：开启 = 铸分享标识并放行公开链接，关闭 = 只清开关（标识保留，重开同号）。与金句授权档/公开 slug 无依赖。双入口（token 或登录账号）"
    field :flashback_set_card_sharing, :flashback_card_sharing do
      arg(:enabled, non_null(:boolean))
      arg(:token, :string)

      # 阈值 30/15min：完整首程（enter→revealed→submit→quote→send）5 次 +
      # 回访/重试/注册发码余量；默认 5 次会让合法旅程必然撞限（e2e 实测）
      middleware(Cgc2046Web.Plugs.RateLimit, key_path: [:token], max_attempts: 30)

      resolve(fn _, args, %{context: context} ->
        flashback_call(fn ->
          with {:ok, identity} <- flashback_identity(args[:token], context) do
            Cgc2046.Flashback.CardSharing.set(args[:enabled], identity)
          end
        end)
      end)
    end

    @desc "注册绑定（R27 寄出时刻一步注册）：手机验证码 → find-or-create User → 档案绑定 + 链接作废；会话 token 经 httpOnly cookie 交付"
    field :flashback_register_bind, :flashback_register_bind_result do
      arg(:token, non_null(:string))
      arg(:phone, non_null(:string))
      arg(:code, non_null(:string))

      middleware(Cgc2046Web.Plugs.RateLimit, key_path: [:phone])

      resolve(fn _, %{token: token, phone: phone, code: code}, %{context: context} ->
        flashback_call(fn ->
          Cgc2046.Flashback.Tokens.register_bind(token, phone, code, context)
        end)
      end)

      middleware(fn res, _ ->
        case res.value do
          %{__token__: token} when is_binary(token) ->
            %{res | context: Map.put(res.context, :cgc_auth_token, token)}

          _ ->
            res
        end
      end)
    end

    @desc "更新手机号（R17/KTD7 防劫持）：新通道须先验证码验证；原通道收变更通知；回显仅掩码"
    field :flashback_update_contact, :flashback_update_contact_result do
      arg(:token, non_null(:string))
      arg(:phone, non_null(:string))
      arg(:code, non_null(:string))

      middleware(Cgc2046Web.Plugs.RateLimit, key_path: [:phone])

      resolve(fn _, %{token: token, phone: phone, code: code}, _ ->
        flashback_call(fn -> Cgc2046.Flashback.Tokens.update_contact(token, phone, code) end)
      end)
    end

    @desc "删除我的档案（U10/R30/ADR-0015）：不可逆——卡从墙上撤下、链接作废、答案/回信/附议/金句授权清除、公开页下线；触达记录去个人字段。二次确认 confirm 必须为 \"DELETE\"。双入口（token 或登录账号）"
    field :flashback_delete, :flashback_delete_result do
      arg(:token, :string)
      arg(:confirm, non_null(:string))

      # 阈值 30/15min：完整首程（enter→revealed→submit→quote→send）5 次 +
      # 回访/重试/注册发码余量；默认 5 次会让合法旅程必然撞限（e2e 实测）
      middleware(Cgc2046Web.Plugs.RateLimit, key_path: [:token], max_attempts: 30)

      resolve(fn _, args, %{context: context} ->
        flashback_call(fn ->
          with {:ok, identity} <- flashback_identity(args[:token], context) do
            case identity do
              {:token, token} ->
                with {:ok, resolved} <-
                       Cgc2046.Flashback.Deletion.resolve_identity(token, nil) do
                  Cgc2046.Flashback.Deletion.delete(resolved, args[:confirm])
                end

              {:person, _person_id} ->
                with {:ok, resolved} <-
                       Cgc2046.Flashback.Deletion.resolve_identity(nil, context[:actor]) do
                  Cgc2046.Flashback.Deletion.delete(resolved, args[:confirm])
                end
            end
          end
        end)
      end)
    end

    @desc "许愿（R5/R6 + wish2 U8/KTD1/KTD11）：visibility 二选一——public 进走廊可附议留言；private 仅平台与自己可见。signatureChoice 署名快照、expectedCity 期望地归一（名单外 flashback_wish_city_unknown 带 ≤3 候选）、publicListingConsent 公开树授权（public 且 true 才写 listed_at 挂树）。每年最多 3 条（R20 年度额度，含私有与已软删，删除不退还），超限返回 flashback_wish_quota_exceeded"
    field :flashback_create_wish, :flashback_wish_result do
      arg(:token, :string)
      arg(:request_id, :id)
      arg(:content, non_null(:string))
      arg(:visibility, non_null(:string))
      @desc "署名快照：anonymous（默认，姓氏遮罩）/ display_name（实名展示——展示名语义，不暗示法定名，R17）"
      arg(:signature_choice, :string)
      @desc "期望地（Cities 名单短名；缺省取名册城市宽容归一）"
      arg(:expected_city, :string)
      @desc "公开树授权：仅 visibility=public 且 true 时愿望挂上许愿树（任何人可见）"
      arg(:public_listing_consent, :boolean)

      middleware(Cgc2046Web.Plugs.RateLimit, key_path: [:token], max_attempts: 30)

      resolve(fn _, args, %{context: context} ->
        flashback_call(fn ->
          with {:ok, identity} <- wish_identity(args[:token], context),
               {:ok, wish} <-
                 Cgc2046.Flashback.WishWriting.create(
                   identity,
                   args.content,
                   args.visibility,
                   request_id: args[:request_id],
                   signature_choice: wish_signature_choice(args[:signature_choice]),
                   expected_city: args[:expected_city],
                   public_listing_consent: args[:public_listing_consent] || false
                 ) do
            {:ok,
             %{
               id: wish.id,
               endorsement_count: 0,
               endorsed_by_me: false,
               status: wish.listing_status
             }}
          end
        end)
      end)
    end

    @desc "附议愿望（wish2 U6/KTD3 改造）：**要求登录**（旧 token/person 匿名腿下线——未登录 flashback_auth_required）；出力类型 + 留言(≤500 机审) + 回响通知意愿；返回实时计数与本人态"
    field :flashback_endorse_wish, :flashback_wish_endorse_result do
      arg(:wish_id, non_null(:id))
      @desc "出力类型（可多选）：venue / organize / speak / sponsor / other"
      arg(:contribution_types, list_of(:string))
      @desc "给平台的留言（≤500；非空过机审；仅运营可见）"
      arg(:message, :string)
      @desc "回响通知意愿（默认 false；真实授权由微信订阅消息 accept 上报，后端零 grant）"
      arg(:notify, :boolean)

      resolve(fn _, args, %{context: context} ->
        # plan U3 契约：未登录附议 → flashback_auth_required（非通用 unauthorized；
        # 小程序/前端按该 code 引导手机号一键登录）
        with_actor(
          context,
          fn actor ->
            flashback_call(fn ->
              Cgc2046.Flashback.Wishes.endorse_by_user(
                actor.id,
                args.wish_id,
                contribution_types: args[:contribution_types] || [],
                message: args[:message],
                notify: args[:notify] || false
              )
            end)
          end,
          on_nil: fn _ ->
            {:error, [message: "请先登录后再附议。", code: "flashback_auth_required"]}
          end
        )
      end)
    end

    @desc "愿望留言（R8）：公开愿望可留言讨论"
    field :flashback_add_wish_comment, :flashback_wish_result do
      arg(:token, :string)
      arg(:wish_id, non_null(:id))
      arg(:content, non_null(:string))

      middleware(Cgc2046Web.Plugs.RateLimit, key_path: [:token], max_attempts: 30)

      resolve(fn _, args, %{context: context} ->
        flashback_call(fn ->
          with {:ok, identity} <- flashback_identity(args[:token], context),
               {:ok, person_id} <- identity_person_id(identity),
               {:ok, _comments} <-
                 Cgc2046.Flashback.Wishes.add_comment(person_id, args.wish_id, args.content),
               %Cgc2046.Flashback.Wish{} = wish <-
                 Cgc2046.Repo.get(Cgc2046.Flashback.Wish, args.wish_id) do
            # add_comment 必经 fetch_public_wish(visibility=public、未删、未 hidden)。
            # listed_at/hidden_at 仍有三种合法形态(挂树/无 consent/曾 hidden 被解除——
            # 后者按现行过滤进不来),三态仍可能为 listed 或 private;走 listing_status/2
            # 与 create_wish resolver 对齐,避免把三态字符串散落在 resolver 硬编码。
            {:ok,
             %{
               endorsement_count: 0,
               endorsed_by_me: false,
               status: Cgc2046.Flashback.Wishes.listing_status(wish.visibility, wish)
             }}
          end
        end)
      end)
    end

    @desc "删除自己的许愿（R14 软删）：公开愿望删除后从走廊移除"
    field :flashback_delete_wish, :boolean do
      arg(:token, :string)
      arg(:wish_id, non_null(:id))

      resolve(fn _, args, %{context: context} ->
        flashback_call(fn ->
          with {:ok, identity} <- wish_identity(args[:token], context),
               {:ok, _wish} <-
                 Cgc2046.Flashback.Wishes.soft_delete_wish(args.wish_id, identity) do
            {:ok, true}
          end
        end)
      end)
    end

    @desc "删除自己的留言（R14 软删）"
    field :flashback_delete_wish_comment, :boolean do
      arg(:token, :string)
      arg(:comment_id, non_null(:id))

      resolve(fn _, args, %{context: context} ->
        flashback_call(fn ->
          with {:ok, identity} <- flashback_identity(args[:token], context),
               {:ok, person_id} <- identity_person_id(identity),
               {:ok, _comment} <-
                 Cgc2046.Flashback.Wishes.soft_delete_comment(args.comment_id, person_id) do
            {:ok, true}
          end
        end)
      end)
    end
  end
end
