defmodule Cgc2046Web.GraphqlSchema.Flashback.Queries do
  @moduledoc """
  闪念间（In a Flash）读面 query 字段：首程/档案、公开层、愿望树与
  admin 治理读面（看板 / 触达批次 / 兑换）。
  """

  use Absinthe.Schema.Notation

  import Cgc2046Web.GraphqlSchema.Helpers
  import Cgc2046Web.GraphqlSchema.Flashback.Helpers

  object :flashback_queries do
    @desc "闪念间圆梦线 CTA 两态（U4/R9）：本城最近一场可报名公开场次；未命中时前端落 Initiative 公开页。匿名可读，仅指路字段"
    field :flashback_dream_target, :flashback_dream_target do
      arg(:city, :string)

      resolve(fn _, args, _ ->
        {:ok, Cgc2046.Flashback.Public.dream_target(Map.get(args, :city))}
      end)
    end

    @desc "闪念间时间胶囊（U5/R12/R13）：token 或登录态（绑定账号）双入口的校友层投影；失效三态同 enter"
    field :flashback_capsule, :flashback_capsule do
      arg(:token, :string)
      @desc "城市钉筛选（R34）：非空时名册与行动板按城市过滤；cities 始终全量"
      arg(:city, :string)

      resolve(fn _, args, %{context: context} ->
        flashback_call(fn ->
          with {:ok, resolved} <-
                 Cgc2046.Flashback.AlumniProjection.resolve_person(
                   Map.get(args, :token),
                   context[:actor]
                 ),
               {:ok, capsule} <-
                 Cgc2046.Flashback.AlumniProjection.capsule(resolved, Map.get(args, :city)) do
            {:ok, capsule}
          end
        end)
      end)
    end

    @desc "相册（#933）：所有已登录用户可读每一场的名册（未寄出者只有姓氏遮罩）；未登录 → flashback_auth_required"
    field :flashback_archives, :flashback_archives_result do
      @desc "城市钉筛选：非空时城市堆按城市聚合、名册只列该城市的已寄出者"
      arg(:city, :string)

      resolve(fn _, args, %{context: context} ->
        flashback_call(fn ->
          if is_nil(context[:actor]) do
            {:error,
             %{
               code: "flashback_auth_required",
               message: "sign-in required",
               reason: :auth_required
             }}
          else
            Cgc2046.Flashback.AlumniProjection.viewer_archives(Map.get(args, :city))
          end
        end)
      end)
    end

    @desc "看板四率（U11/R24/KTD10，PlatformAdmin）：分子=FlashbackTouch 各事件 distinct person；分母=成功送达（硬退信与退订剔除）；分线=记忆线/圆梦线。batch 可选——按波次筛（#984，拆批=放弃跨批去重）"
    field :flashback_admin_stats, :flashback_admin_stats do
      arg(:batch, :string)

      resolve(fn _, args, %{context: context} ->
        with_admin(context, fn _actor -> Cgc2046.Flashback.AdminStats.stats(args[:batch]) end)
      end)
    end

    @desc "波次下拉选项（#984，PlatformAdmin）：outreaches distinct batch 倒序，含 resend-* 补救批次；空库为 []"
    field :flashback_admin_batches, non_null(list_of(non_null(:string))) do
      resolve(fn _, _, %{context: context} ->
        with_admin(context, fn _actor -> Cgc2046.Flashback.AdminStats.batches() end)
      end)
    end

    @desc "兑换申请队列（U11/R25，PlatformAdmin）：倒序封顶；channel_note 为用户提交的收款渠道（admin-only）"
    field :flashback_admin_redemptions, non_null(list_of(non_null(:flashback_redemption))) do
      arg(:limit, :integer)

      resolve(fn _, args, %{context: context} ->
        with_admin(context, fn _actor ->
          Cgc2046.Flashback.AdminStats.redemptions(Map.get(args, :limit) || 50)
        end)
      end)
    end

    @desc "触达预览（R4/R7，PlatformAdmin）：批量发送前的影响面——三档分布、退订剔除、短信腿就绪位；与确认摘要同源（KTD2）；batch 非空时附 campaign 去重预判"
    field :flashback_outreach_preview, :flashback_outreach_preview do
      arg(:archive_key, non_null(:string))
      arg(:channel, :string)

      @desc "campaign 批次号（预判同人跨 archive 去重数；与入队同源）"
      arg(:batch, :string)

      resolve(fn _, args, %{context: context} ->
        with_admin(context, fn _actor ->
          with {:ok, channel} <-
                 Cgc2046.Flashback.Outreach.Dispatch.parse_channel(Map.get(args, :channel, "all")) do
            Cgc2046.Flashback.OutreachAdmin.preview(args[:archive_key], channel, args[:batch])
          else
            {:error, :invalid_channel} ->
              {:error,
               %{code: "flashback_invalid_input", message: "channel must be one of all|email|sms"}}
          end
        end)
      end)
    end

    @desc "场次列表（R7 发送入口数据源，PlatformAdmin）"
    field :flashback_admin_archives, non_null(list_of(non_null(:flashback_admin_archive))) do
      resolve(fn _, _, %{context: context} ->
        with_admin(context, fn _actor ->
          Cgc2046.Flashback.OutreachAdmin.archives()
        end)
      end)
    end

    @desc "触达批次历史（R8，PlatformAdmin）：按批次聚合发送计数（通道 × 状态），含 resend-* 补救批次"
    field :flashback_outreach_batches, non_null(list_of(non_null(:flashback_outreach_batch))) do
      arg(:archive_key, non_null(:string))

      resolve(fn _, args, %{context: context} ->
        with_admin(context, fn _actor ->
          Cgc2046.Flashback.OutreachAdmin.batch_history(args[:archive_key])
        end)
      end)
    end

    @desc "场次名册（R9，PlatformAdmin）：档案 + 最近触达结果 + 完整联系方式（KD6/R13）；filter = unclaimed|unsubscribed|sms_only|send_failed"
    field :flashback_outreach_roster,
          non_null(list_of(non_null(:flashback_outreach_roster_entry))) do
      arg(:archive_key, non_null(:string))
      arg(:filter, :string)
      arg(:search, :string)

      resolve(fn _, args, %{context: context} ->
        with_admin(context, fn _actor ->
          Cgc2046.Flashback.OutreachAdmin.roster(args[:archive_key], args[:filter], args[:search])
        end)
      end)
    end

    @desc "删除摘要（U10/R30 二次确认页数据源）：将失去什么——强提示依据；双入口（token 或登录账号）"
    field :flashback_delete_preview, :flashback_delete_preview_result do
      arg(:token, :string)

      resolve(fn _, args, %{context: context} ->
        flashback_call(fn ->
          with {:ok, identity} <- flashback_identity(args[:token], context) do
            case identity do
              {:token, token} ->
                with {:ok, resolved} <-
                       Cgc2046.Flashback.Deletion.resolve_identity(token, nil) do
                  Cgc2046.Flashback.Deletion.preview(resolved)
                end

              {:person, _person_id} ->
                with {:ok, resolved} <-
                       Cgc2046.Flashback.Deletion.resolve_identity(nil, context[:actor]) do
                  Cgc2046.Flashback.Deletion.preview(resolved)
                end
            end
          end
        end)
      end)
    end

    @desc "登录账号的全部未删除愿望，含公开、私密和待审；无历史档案也可使用。"
    field :flashback_my_wishes, :flashback_my_wishes do
      resolve(fn _, _, %{context: context} ->
        flashback_call(fn ->
          case context[:actor] do
            %{id: id} -> Cgc2046.Flashback.WishAuthors.mine(id)
            _ -> {:error, %{code: "flashback_auth_required", message: "请先登录，再查看或保存愿望。"}}
          end
        end)
      end)
    end

    @desc "闪念间公开统计层（U6/R32）：场次档案聚合 + 已回来/已寄出计数；匿名可读，空库为零值（前端空态叙事承接）"
    field :flashback_public_stats, :flashback_public_stats do
      resolve(fn _, _, _ -> Cgc2046.Flashback.Public.stats() end)
    end

    @desc "闪念间匿名金句墙（U6/R31/R32/R36/R37）：授权者的脱敏金句（姓** · 年 · 城），按句输出；未授权/已撤回内容零出现。排序=点赞数优先、更新时间次之；voterKey 用于 likedByViewer（不传恒 false）"
    field :flashback_public_quotes, non_null(list_of(non_null(:flashback_public_quote))) do
      @desc "城市短名；筛选先于热门 60 条限量"
      arg(:city, :string)
      @desc "客户端去重键（u:<user_id> / a:<device_uuid>）：只影响 likedByViewer 回显"
      arg(:voter_key, :string)

      resolve(fn _, args, _ ->
        Cgc2046.Flashback.Public.quotes(Map.get(args, :voter_key), Map.get(args, :city))
      end)
    end

    @desc "随便听听（R35 随机入口）：全量未隐藏金句中随机取 limit 句（默认 3）；过滤口径同金句墙"
    field :flashback_random_quotes, non_null(list_of(non_null(:flashback_public_quote))) do
      @desc "句数（默认 3，上限 20）"
      arg(:limit, :integer)
      @desc "客户端去重键（u:<user_id> / a:<device_uuid>）：只影响 likedByViewer 回显"
      arg(:voter_key, :string)

      resolve(fn _, args, _ ->
        limit = args |> Map.get(:limit, 3) |> max(1) |> min(20)
        Cgc2046.Flashback.Public.random_quotes(limit, Map.get(args, :voter_key))
      end)
    end

    @desc "单句直达（R37 分享链接 ?item=）：按 quoteId 取一句；已撤回/未授权/不存在统一 null（不泄露存在性，前端渲染失效页）"
    field :flashback_public_quote, :flashback_public_quote do
      arg(:quote_id, non_null(:id))
      @desc "客户端去重键（u:<user_id> / a:<device_uuid>）：只影响 likedByViewer 回显"
      arg(:voter_key, :string)

      resolve(fn _, args, _ ->
        Cgc2046.Flashback.Public.quote(args.quote_id, Map.get(args, :voter_key))
      end)
    end

    @desc "闪念间实名档案页（U6/R31 credited 档）：仅已发布 public_slug 者可解析；null = 未授权（前端 404 态）"
    field :flashback_public_profile, :flashback_public_profile do
      arg(:slug, non_null(:string))

      resolve(fn _, %{slug: slug}, _ -> Cgc2046.Flashback.Public.profile(slug) end)
    end

    @desc "卡片分享链接（#771）：匿名可读（无 token / 无 slug / 无授权依赖）；null = 未命中 / 已关闭 / 已删除（不区分原因，不做存在性预言机）"
    field :flashback_shared_card, :flashback_shared_card do
      arg(:share_id, non_null(:string))

      resolve(fn _, %{share_id: share_id}, _ ->
        {:ok, Cgc2046.Flashback.SharedCard.get(share_id)}
      end)
    end

    @desc "公开许愿树（wish2 U6/KTD10）：listed+public+未 hidden+未删 四条件；带种子加权随机排序（-ln(u)/w，w=(1+期待+2×附议)×freshness）；seed 缺省=当日+voterKey；字段白名单（无 phone/email/message）"
    field :flashback_public_wishes, non_null(list_of(non_null(:flashback_public_wish))) do
      @desc "城市过滤（Cities.normalize 短名；null = 不过滤）"
      arg(:city, :string)
      @desc "仅含已公开回响的愿望；在分页前筛选，不把草稿或撤销回响算入"
      arg(:with_echoes, :boolean)
      @desc "排序种子（null = 当日+voterKey；「换一批」传随机值）"
      arg(:seed, :string)
      @desc "分页偏移（同 seed 稳定不重不漏）"
      arg(:offset, :integer)
      @desc "页大小（默认 60，上限 120）"
      arg(:limit, :integer)
      @desc "客户端去重键（u:<user_id> / a:<device_uuid>）：只影响 expected/endorsedByViewer 回显"
      arg(:voter_key, :string)

      resolve(fn _, args, %{context: context} ->
        # HS-3 双键读面：登录 actor 强制 u: 键 + 入参 a: 设备键合并（期待态
        # 刷新不漂移——mutation 登录态按 u: 记账）；未登录维持入参单键。
        # 城市过滤与表单同源归一（KTD11）：「成都市」→「成都」；未识别值原样
        # 直传——读面宽容，查询结果为空而非报错。
        city =
          case args[:city] do
            nil ->
              nil

            raw when is_binary(raw) ->
              case Cgc2046.Flashback.Cities.normalize(raw) do
                {:ok, short} -> short
                {:error, _} -> raw
              end

            # 防御分支：:string 入参实际只会是 binary|nil；兜底防运行时 CaseClauseError
            other ->
              other
          end

        Cgc2046.Flashback.WishPublic.wishes(
          city: city,
          with_echoes: args[:with_echoes] || false,
          seed: args[:seed],
          offset: args[:offset],
          limit: args[:limit],
          voter_keys: viewer_voter_keys(context, args[:voter_key])
        )
      end)
    end

    @desc "许愿单条直达（?item=<wish_id>）：四条件可见才返回；不可见/不存在统一 null（不泄露存在性）"
    field :flashback_public_wish, :flashback_public_wish do
      arg(:wish_id, non_null(:id))
      @desc "客户端去重键：只影响 expected/endorsedByViewer 回显"
      arg(:voter_key, :string)

      resolve(fn _, args, %{context: context} ->
        Cgc2046.Flashback.WishPublic.wish(
          args.wish_id,
          voter_keys: viewer_voter_keys(context, args[:voter_key])
        )
      end)
    end

    @desc "公开许愿树城市全集，按拼音排列，不受愿望分页限制"
    field :flashback_wish_cities, non_null(list_of(non_null(:flashback_city))) do
      resolve(fn _, _, _ -> Cgc2046.Flashback.WishPublic.published_cities() end)
    end

    @desc "公开金句所在城市，按拼音排序；只计仍获授权、未撤下、未删除的金句，不受热门限量影响"
    field :flashback_voice_cities, non_null(list_of(non_null(:flashback_city))) do
      resolve(fn _, _, _ -> Cgc2046.Flashback.Public.voice_cities() end)
    end

    @desc "全国城市名单（wish2 U6/KTD11，静态 ~370 条）：name + fullName + pinyin + lngLat——表单自动补全与树图钉点共源"
    field :flashback_cities, non_null(list_of(non_null(:flashback_city))) do
      resolve(fn _, _, _ -> {:ok, Cgc2046.Flashback.WishPublic.cities()} end)
    end

    @desc "「说给主办方听」收件箱（wish2 U5/KTD5 PlatformAdmin）：private 未删愿望 + 作者登录账号联系方式（phone/email 仅 admin；公开响应禁出）"
    field :flashback_admin_wish_inbox,
          non_null(list_of(non_null(:flashback_admin_wish_inbox_entry))) do
      resolve(fn _, _, %{context: context} ->
        with_admin(context, fn _actor ->
          entries =
            Cgc2046.Flashback.Reports.list_inbox_private_wishes()
            |> Enum.map(fn entry ->
              %{
                wish_id: entry.wish.id,
                content: entry.wish.content,
                city: entry.wish.city,
                signature: entry.wish.signature,
                inserted_at: entry.wish.inserted_at,
                wisher_masked: entry.wisher_masked,
                wisher_phone: entry.wisher_user_contact && entry.wisher_user_contact.phone,
                wisher_email: entry.wisher_user_contact && entry.wisher_user_contact.email
              }
            end)

          {:ok, entries}
        end)
      end)
    end

    @desc "举报队列（wish2 U5/KTD5 PlatformAdmin）：status=pending 按时间正序"
    field :flashback_admin_wish_reports,
          non_null(list_of(non_null(:flashback_admin_report_entry))) do
      resolve(fn _, _, %{context: context} ->
        with_admin(context, fn _actor ->
          entries =
            Cgc2046.Flashback.Reports.list_pending_reports()
            |> Enum.map(fn r ->
              %{
                report_id: r.id,
                target_type: r.target_type,
                target_id: r.target_id,
                reason_type: r.reason_type,
                reason_free: r.reason_free,
                status: r.status,
                inserted_at: r.inserted_at
              }
            end)

          {:ok, entries}
        end)
      end)
    end

    @desc "许愿树回响（#834，PlatformAdmin）：读取某愿望全部回响及当前可通知附议数"
    field :flashback_admin_wish_echoes, :flashback_admin_wish_echoes_result do
      arg(:wish_id, non_null(:id))

      resolve(fn _, args, %{context: context} ->
        with_admin(context, fn _actor ->
          flashback_call(fn ->
            Cgc2046.Flashback.WishEchoes.list_for_admin(args.wish_id)
          end)
        end)
      end)
    end

    @desc "回响管理队列（#835 PlatformAdmin）：公开树可见愿望（listed/public/unhidden/未删），按挂树时间倒序，附回响计数"
    field :flashback_admin_listed_wishes,
          non_null(list_of(non_null(:flashback_admin_listed_wish_entry))) do
      resolve(fn _, _, %{context: context} ->
        with_admin(context, fn _actor ->
          {:ok, Cgc2046.Flashback.Reports.list_listed_wishes()}
        end)
      end)
    end

    @desc "公开愿望巡检（#817 PlatformAdmin）：作者已授权挂树（listing_consent_at）的公开愿望，待审置前 → 已下架 → 已挂树；三态标记 listed/pending_review/hidden；未授权与软删不出现"
    field :flashback_admin_public_wishes,
          non_null(list_of(non_null(:flashback_admin_public_wish_entry))) do
      @desc "返回上限（默认 50，最大 200）"
      arg(:limit, :integer)

      resolve(fn _, args, %{context: context} ->
        with_admin(context, fn _actor ->
          {:ok, Cgc2046.Flashback.Reports.list_public_wishes_for_admin(args[:limit])}
        end)
      end)
    end

    @desc "附议留言聚合（#817 PlatformAdmin）：有附议的未删愿望按最新附议倒序；分布 + 明细（留言/出力类型/时间）；附议者登录账号 phone/email 仅 admin，公开响应禁出（KTD5 双层断言）"
    field :flashback_admin_wish_endorsements,
          non_null(list_of(non_null(:flashback_admin_wish_endorsement_entry))) do
      @desc "返回愿望数上限（默认 50，最大 100）"
      arg(:limit, :integer)

      resolve(fn _, args, %{context: context} ->
        with_admin(context, fn _actor ->
          {:ok, Cgc2046.Flashback.Reports.list_wish_endorsements_for_admin(args[:limit])}
        end)
      end)
    end
  end
end
