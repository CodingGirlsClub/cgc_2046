defmodule Cgc2046Web.GraphqlSchema.Flashback.WishMutations do
  @moduledoc """
  闪念间（In a Flash）写面下半：兑换 / 找回、管理面（PlatformAdmin）、
  wish2 公开与 admin mutation（redeem … wish2 admin）。
  """

  use Absinthe.Schema.Notation

  import Cgc2046Web.GraphqlSchema.Helpers
  import Cgc2046Web.GraphqlSchema.Flashback.Helpers

  object :flashback_wish_mutations do
    field :flashback_redeem, :flashback_redeem_result do
      arg(:token, :string)
      arg(:channel_note, non_null(:string))

      # 阈值 30/15min：完整首程（enter→revealed→submit→quote→send）5 次 +
      # 回访/重试/注册发码余量；默认 5 次会让合法旅程必然撞限（e2e 实测）
      middleware(Cgc2046Web.Plugs.RateLimit, key_path: [:token], max_attempts: 30)

      resolve(fn _, args, %{context: context} ->
        flashback_call(fn ->
          with {:ok, identity} <- flashback_identity(args[:token], context),
               {:ok, person_id} <- identity_person_id(identity) do
            Cgc2046.Flashback.AdminStats.submit(person_id, args[:channel_note])
          end
        end)
      end)
    end

    @desc "自助找回·发起（U6/R21/KTD7）：手机精确匹配→邮箱兜底；命中与未命中同形返回（不泄露存在性）；双窗口限流。手机通道暂停时手机号同形返回、不发码"
    field :flashback_recover, :flashback_recover_result do
      arg(:identifier, non_null(:string))

      middleware(Cgc2046Web.Plugs.RateLimit, key_path: [:identifier])

      resolve(fn _, %{identifier: identifier}, %{context: context} ->
        flashback_call(fn ->
          Cgc2046.Flashback.Recover.initiate(identifier, context_ip(context))
        end)
      end)
    end

    @desc "自助找回·验证（U6/R21）：手机验证码通过 → find-or-create User + 绑定全部匹配档案（token 全部作废，R1）；返回脱敏卡列表（你的 N 张卡）。手机通道暂停时一律 invalid_or_expired_code"
    field :flashback_recover_verify, :flashback_recover_verify_result do
      arg(:identifier, non_null(:string))
      arg(:code, non_null(:string))

      middleware(Cgc2046Web.Plugs.RateLimit, key_path: [:identifier])

      resolve(fn _, %{identifier: identifier, code: code}, %{context: context} ->
        flashback_call(fn ->
          Cgc2046.Flashback.Recover.verify(identifier, code, context)
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

    @desc "自助找回·验证（已登录，#932）：手机验证码通过 → 匹配档案绑定到当前登录账号（不 find-or-create、不换会话）；号码或档案已属于另一个账号 → flashback_recover_account_conflict（不静默合并）；发起沿用 flashbackRecover。手机通道暂停时一律 invalid_or_expired_code"
    field :flashback_recover_verify_for_account, :flashback_recover_verify_result do
      arg(:identifier, non_null(:string))
      arg(:code, non_null(:string))

      middleware(Cgc2046Web.Plugs.RateLimit, key_path: [:identifier])

      resolve(fn _, %{identifier: identifier, code: code}, %{context: context} ->
        with_actor(context, fn actor ->
          flashback_call(fn ->
            Cgc2046.Flashback.Recover.verify_for_user(identifier, code, actor)
          end)
        end)
      end)
    end

    @desc "自助找回·贴链接（已登录，小程序邮箱通道）：找回邮件里的入口链接（或其中的 fb_ token）贴回来 → 同邮箱的全部档案绑定到当前登录账号并作废链接；档案已属于另一个账号 → flashback_recover_account_conflict；链接无效 / 已用过 → flashback_token_*"
    field :flashback_recover_claim_for_account, :flashback_recover_verify_result do
      arg(:link, non_null(:string))

      middleware(Cgc2046Web.Plugs.RateLimit, key_path: [:link])

      resolve(fn _, %{link: link}, %{context: context} ->
        with_actor(context, fn actor ->
          flashback_call(fn ->
            Cgc2046.Flashback.Recover.claim_link_for_user(link, actor)
          end)
        end)
      end)
    end

    # ── 闪念间管理面（U7/U8/U11，KTD5：PlatformAdmin gate——非管理员被拒，变异验证钉住）──

    @desc "兑换状态流转（U11/R25，PlatformAdmin）：pending→contacted→settled|rejected 人工处理；非法转移 fail-closed"
    field :flashback_admin_update_redemption, :flashback_redemption_update_result do
      arg(:id, non_null(:id))
      arg(:status, non_null(:string))
      arg(:handled_note, :string)

      resolve(fn _, args, %{context: context} ->
        with_admin(context, fn _actor ->
          flashback_call(fn ->
            Cgc2046.Flashback.AdminStats.update_status(
              args[:id],
              args[:status],
              Map.get(args, :handled_note)
            )
          end)
        end)
      end)
    end

    @desc "闪念间·单人重发（R2/R10，PlatformAdmin；有副作用，属 Mutation）：不可重发者带原因业务错误（R5 拒绝表）；resend-* 独立批次"
    field :flashback_admin_resend_outreach, :flashback_outreach_dispatch_result do
      arg(:person_id, non_null(:id))
      arg(:template, non_null(:string))
      arg(:channel, :string)

      resolve(fn _, args, %{context: context} ->
        with_admin(context, fn actor ->
          with {:ok, channel} <-
                 Cgc2046.Flashback.Outreach.Dispatch.parse_channel(Map.get(args, :channel, "all")) do
            # 治理留痕单源在 Dispatch（R2）。
            Cgc2046.Flashback.Outreach.Dispatch.resend_for_person(
              args[:person_id],
              args[:template],
              channel,
              actor
            )
          else
            {:error, :invalid_channel} ->
              {:error,
               %{code: "flashback_invalid_input", message: "channel must be one of all|email|sms"}}
          end
        end)
      end)
    end

    @desc "闪念间·批量触达（U8/R23，PlatformAdmin）：按场次解析可触达校友（未退订）逐人入 outreach 队列（错峰限速、幂等可重跑）；channel 三档 = all（email 优先/phone 兜底）| email | sms（R11）；token 铸造在 worker 内完成"
    field :flashback_admin_send_outreach, :flashback_outreach_dispatch_result do
      arg(:archive_key, non_null(:string))
      arg(:template, non_null(:string))
      arg(:channel, :string)

      @desc "campaign 批次号（跨 archive 全量发时显式共用——同人只收一封；默认 archive-<key> 批次互不感知）"
      arg(:batch, :string)

      resolve(fn _, %{archive_key: archive_key, template: template} = args, %{context: context} ->
        with_admin(context, fn actor ->
          flashback_call(fn ->
            with {:ok, channel} <-
                   Cgc2046.Flashback.Outreach.Dispatch.parse_channel(
                     Map.get(args, :channel, "all")
                   ) do
              # 治理留痕单源在 Dispatch（R1）。
              Cgc2046.Flashback.Outreach.Dispatch.enqueue_for_archive(
                archive_key,
                template,
                channel,
                Keyword.merge(if(args[:batch], do: [batch: args[:batch]], else: []), actor: actor)
              )
            else
              {:error, :invalid_channel} ->
                {:error,
                 %{
                   code: "flashback_invalid_input",
                   message: "channel must be one of all|email|sms"
                 }}
            end
          end)
        end)
      end)
    end

    @desc "微信一键收好（R27 小程序路径）：已登录用户绑定档案——带 token 收该链接的档案（并作废链接）；不带 token 按登录手机/邮箱自动匹配未认领档案"
    field :flashback_claim, :flashback_claim_result do
      arg(:token, :string)

      resolve(fn _, args, %{context: context} ->
        flashback_call(fn ->
          Cgc2046.Flashback.Tokens.claim_for_user(context[:actor], Map.get(args, :token))
        end)
      end)
    end

    @desc "金句点赞/取消（R36/R37）：公开无登录——voterKey（u:<user_id> / a:<device_uuid>）客户端生成去重，IP 窗口 + voterKey 窗口双层限频；返回该句实时计数"
    field :flashback_like_quote, :flashback_quote_like_result do
      arg(:quote_id, non_null(:id))
      arg(:voter_key, non_null(:string))
      @desc "true=点赞（幂等）；false=取消（幂等）"
      arg(:liked, non_null(:boolean))

      resolve(fn _, args, %{context: context} ->
        flashback_call(fn ->
          Cgc2046.Flashback.Likes.set_like(
            args.quote_id,
            args.voter_key,
            args.liked,
            context_ip(context)
          )
        end)
      end)
    end

    @desc "金句下线开关（R38，PlatformAdmin）：hidden_at 置位/清空——置位后立即从金句墙与实名档案页消失（人工红线处理，无审核流水线）"
    field :flashback_admin_set_quote_hidden, :flashback_quote_hidden_result do
      arg(:person_id, non_null(:id))
      @desc "true=下线；false=恢复"
      arg(:hidden, non_null(:boolean))

      resolve(fn _, args, %{context: context} ->
        with_admin(context, fn actor ->
          flashback_call(fn ->
            with {:ok, person_id} <- validate_like_person_id(args.person_id) do
              Cgc2046.Flashback.QuoteLicenses.set_hidden(actor, person_id, args.hidden)
            end
          end)
        end)
      end)
    end

    # ── wish2 公开 mutations（U6 KTD2/KTD3/KTD9）──────────────────────

    @desc "期待/取消期待（wish2 U6/KTD2）：公开无登录——voterKey（u:/a:）去重；登录 actor 传 anonVoterKey 时服务端合并匿名行；双窗限频（30/min voter + 60/h IP）"
    field :flashback_expect_wish, :flashback_wish_expect_result do
      arg(:wish_id, non_null(:id))
      @desc "true=期待（幂等）；false=取消（幂等）"
      arg(:expected, non_null(:boolean))
      @desc "匿名设备键 a:<device_uuid>（登录 actor 可不传——服务端强制 u:）"
      arg(:anon_voter_key, :string)
      @desc "登录态设备键（登录 actor 期待时传，服务端用它替代 anon 键做合并）"
      arg(:voter_key, :string)

      middleware(Cgc2046Web.Plugs.RateLimit, key_path: [:wish_id])

      resolve(fn _, args, %{context: context} ->
        flashback_call(fn ->
          Cgc2046.Flashback.WishExpectations.set_expectation(
            args.wish_id,
            args.expected,
            actor_user_id: actor_user_id(context),
            anon_voter_key: args[:anon_voter_key] || anon_key_from(args[:voter_key]),
            remote_ip: context_ip(context)
          )
        end)
      end)
    end

    @desc "取消附议（wish2 U6/KTD3）：要求登录；删 u: 行；期待数不动（双指标分离）"
    field :flashback_cancel_endorse_wish, :flashback_wish_endorse_result do
      arg(:wish_id, non_null(:id))

      resolve(fn _, args, %{context: context} ->
        with_actor(
          context,
          fn actor ->
            flashback_call(fn ->
              Cgc2046.Flashback.Wishes.cancel_endorse_by_user(actor.id, args.wish_id)
            end)
          end,
          on_nil: fn _ ->
            {:error, [message: "请先登录后再操作。", code: "flashback_auth_required"]}
          end
        )
      end)
    end

    @desc "举报愿望（wish2 U6/KTD5）：匿名可报——reason 预设 + 补充 ≤200；10/15min/IP 限频；举报是治理信号不进排序（举报≠踩）"
    field :flashback_report_wish, :flashback_report_result do
      arg(:wish_id, non_null(:id))
      @desc "预设理由：spam / irrelevant / scam / inappropriate / other"
      arg(:reason_type, non_null(:string))
      @desc "补充说明（≤200 字，可选）"
      arg(:reason_free, :string)
      @desc "匿名设备键（登录 actor 不用传）"
      arg(:anon_voter_key, :string)

      resolve(fn _, args, %{context: context} ->
        flashback_call(fn ->
          with {:ok, report} <-
                 Cgc2046.Flashback.Reports.report(
                   "wish",
                   args.wish_id,
                   args.reason_type,
                   actor_user_id: actor_user_id(context),
                   anon_voter_key: args[:anon_voter_key],
                   reason_free: args[:reason_free],
                   remote_ip: context_ip(context)
                 ) do
            {:ok, %{report_id: report.id, status: report.status}}
          end
        end)
      end)
    end

    # ── wish2 admin mutations（U5 scope 补挂——platform admin only）────

    @desc "下架/恢复愿望（wish2 U5/KTD5 PlatformAdmin）：hidden=true 联动置位作者信用字段 wishes_review_required_at；false 只清 hidden_at 不动信用"
    field :flashback_admin_set_wish_hidden, :flashback_wish_hidden_result do
      arg(:wish_id, non_null(:id))
      @desc "true=下架；false=恢复"
      arg(:hidden, non_null(:boolean))

      resolve(fn _, args, %{context: context} ->
        with_admin(context, fn actor ->
          flashback_call(fn ->
            with {:ok, wish} <-
                   Cgc2046.Flashback.Reports.set_wish_hidden(args.wish_id, actor.id, args.hidden) do
              {:ok, %{wish_id: wish.id, hidden: not is_nil(wish.hidden_at)}}
            end
          end)
        end)
      end)
    end

    @desc "放行待审愿望 = 挂树（#817 PlatformAdmin）：置 listed_at + 清 hidden_at；仅作者授权过挂树（listing_consent_at）的公开愿望可放行，无授权证据被拒（授权不扩大红线）；不动作者信用字段；已挂树幂等"
    field :flashback_admin_approve_wish_listing, :flashback_wish_listing_approve_result do
      arg(:wish_id, non_null(:id))

      resolve(fn _, args, %{context: context} ->
        with_admin(context, fn actor ->
          flashback_call(fn ->
            with {:ok, wish} <-
                   Cgc2046.Flashback.Reports.approve_wish_listing(args.wish_id, actor.id) do
              {:ok,
               %{
                 wish_id: wish.id,
                 listed_at: wish.listed_at,
                 status: Cgc2046.Flashback.Wishes.listing_status(wish.visibility, wish)
               }}
            end
          end)
        end)
      end)
    end

    @desc "创建愿望回响草稿（#834，PlatformAdmin；仅当前公开挂树且可见的愿望）"
    field :flashback_admin_create_wish_echo, :flashback_admin_wish_echo do
      arg(:wish_id, non_null(:id))
      arg(:content, non_null(:string))

      resolve(fn _, args, %{context: context} ->
        with_admin(context, fn _actor ->
          flashback_call(fn ->
            Cgc2046.Flashback.WishEchoes.create_draft(args.wish_id, args.content)
          end)
        end)
      end)
    end

    @desc "修改回响草稿（#834，PlatformAdmin；仅 draft 可修改）"
    field :flashback_admin_update_wish_echo_draft, :flashback_admin_wish_echo do
      arg(:echo_id, non_null(:id))
      arg(:content, non_null(:string))

      resolve(fn _, args, %{context: context} ->
        with_admin(context, fn _actor ->
          flashback_call(fn ->
            Cgc2046.Flashback.WishEchoes.update_draft(args.echo_id, args.content)
          end)
        end)
      end)
    end

    @desc "首次发布回响（#834，PlatformAdmin；再次校验愿望仍挂树可见）"
    field :flashback_admin_publish_wish_echo, :flashback_admin_wish_echo do
      arg(:echo_id, non_null(:id))

      resolve(fn _, args, %{context: context} ->
        with_admin(context, fn actor ->
          flashback_call(fn ->
            Cgc2046.Flashback.WishEchoes.publish(args.echo_id, actor.id)
          end)
        end)
      end)
    end

    @desc "原地更正已发布回响（#834，不触发首次通知）"
    field :flashback_admin_correct_wish_echo, :flashback_admin_wish_echo do
      arg(:echo_id, non_null(:id))
      arg(:content, non_null(:string))

      resolve(fn _, args, %{context: context} ->
        with_admin(context, fn _actor ->
          flashback_call(fn ->
            Cgc2046.Flashback.WishEchoes.correct(args.echo_id, args.content)
          end)
        end)
      end)
    end

    @desc "撤回已发布回响（#834，终态）"
    field :flashback_admin_revoke_wish_echo, :flashback_admin_wish_echo do
      arg(:echo_id, non_null(:id))

      resolve(fn _, args, %{context: context} ->
        with_admin(context, fn _actor ->
          flashback_call(fn ->
            Cgc2046.Flashback.WishEchoes.revoke(args.echo_id)
          end)
        end)
      end)
    end

    @desc "驳回举报（wish2 U5 PlatformAdmin）：status=dismissed"
    field :flashback_admin_dismiss_report, :flashback_report_result do
      arg(:report_id, non_null(:id))

      resolve(fn _, args, %{context: context} ->
        with_admin(context, fn actor ->
          flashback_call(fn ->
            with {:ok, report} <-
                   Cgc2046.Flashback.Reports.dismiss_report(args.report_id, actor.id) do
              {:ok, %{report_id: report.id, status: report.status}}
            end
          end)
        end)
      end)
    end

    @desc "批准举报（wish2 U5 PlatformAdmin）：status=actioned + 联动下架目标愿望 + 作者信用置位"
    field :flashback_admin_approve_report, :flashback_report_result do
      arg(:report_id, non_null(:id))

      resolve(fn _, args, %{context: context} ->
        with_admin(context, fn actor ->
          flashback_call(fn ->
            with {:ok, report} <-
                   Cgc2046.Flashback.Reports.approve_report(args.report_id, actor.id) do
              {:ok, %{report_id: report.id, status: report.status}}
            end
          end)
        end)
      end)
    end
  end
end
