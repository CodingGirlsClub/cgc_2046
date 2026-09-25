defmodule Cgc2046Web.GraphqlSchema do
  use Absinthe.Schema
  import_types(Cgc2046Web.GraphqlSchema.Recruitment)
  import_types(Cgc2046Web.GraphqlSchema.SpeakerInvitation)
  import_types(Cgc2046Web.GraphqlSchema.PaymentOperations)
  import_types(Cgc2046Web.GraphqlSchema.Offering)
  import_types(Cgc2046Web.GraphqlSchema.Learning)
  import_types(Cgc2046Web.GraphqlSchema.AdminDashboard)

  require Logger
  require Ash.Query
  require Ash.Expr

  alias Cgc2046.AdminList
  import Cgc2046Web.GraphqlSchema.Helpers

  use AshGraphql,
    domains: [
      Cgc2046.Admission,
      Cgc2046.Courses,
      Cgc2046.Curriculum,
      Cgc2046.Events,
      Cgc2046.Flashback,
      Cgc2046.Accounts,
      Cgc2046.Learning,
      Cgc2046.Payments,
      Cgc2046.Reconciliation,
      Cgc2046.Recruitment,
      Cgc2046.Sponsorship,
      Cgc2046.Workflows
    ],
    generate_sdl_file: "priv/graphql/schema.graphql",
    auto_generate_sdl_file?: true

  query do
    @desc "Placeholder query until the first resource is added"
    field :ping, :string do
      resolve(fn _, _, _ ->
        {:ok, "pong"}
      end)
    end

    @desc "角色权限矩阵（#66 Rbac）：五角色 × 八能力，对齐前端权限表（需登录；#1 能力接口：abilities 为通用列表）"
    field :permission_matrix, :permission_matrix_payload do
      resolve(fn _, _, %{context: context} ->
        with_actor(context, fn _actor ->
          roles =
            Cgc2046.Accounts.Rbac.matrix()
            |> Enum.map(fn row ->
              %{
                name: to_string(row.role),
                abilities:
                  Enum.map(row.abilities, fn {name, allowed} ->
                    %{name: to_string(name), allowed: allowed}
                  end)
              }
            end)

          {:ok, %{roles: roles}}
        end)
      end)
    end

    field :offering_readiness, :offering_readiness_payload do
      arg(:id, non_null(:id))

      resolve(fn _, %{id: id}, %{context: context} ->
        with_actor(context, fn actor ->
          resolve_readiness(id, actor)
        end)
      end)
    end

    @desc "当前登录用户个人资料（#68 Profile API，需登录）：id/email/displayName/isPlatformAdmin + memberNumber/joinedAt（ADR-0004 收窄为全局身份）"
    field :me, :user do
      resolve(fn _, _, %{context: context} ->
        with_actor(
          context,
          fn actor ->
            load_profile(actor, actor, context, nil)
          end,
          on_nil: fn _ctx ->
            # #13 Finding A：token 签名有效但 user 加载失败（DB 故障 / 撤销）时
            # AuthPlug.load_actor 已标记 cgc_auth_uncertain。返回 auth_uncertain
            # 让前端保持登录态重试，而非误踢已登录用户。
            if context[:cgc_auth_uncertain] do
              {:error, message: "Auth state uncertain", code: "auth_uncertain"}
            else
              {:error, unauthorized_error()}
            end
          end
        )
      end)
    end

    @desc "当前登录用户的掩码手机号（仅本人；未绑定返回 null；前 6 后 4 中间 ****，明文不出 GraphQL 面）"
    field :my_phone, :string do
      resolve(fn _, _, %{context: context} ->
        with_actor(context, fn actor ->
          {:ok, Cgc2046.Accounts.PhoneNumber.mask(actor.phone)}
        end)
      end)
    end

    @desc "当前用户在某工作台的公开资料（ADR-0004 per-workspace；按 visibility 授权）"
    field :workspace_profile, :workspace_profile do
      arg(:workspace_id, non_null(:id))

      resolve(fn _, %{workspace_id: workspace_id}, %{context: context} ->
        with_actor(context, fn actor ->
          Cgc2046.Accounts.WorkspaceProfile
          |> Ash.Query.for_read(:read)
          |> Ash.Query.filter(user_id == ^actor.id)
          |> Ash.read_one(tenant: workspace_id, actor: actor)
        end)
      end)
    end

    @desc "当前用户在某工作台的作品集条目列表（ADR-0004 per-workspace）"
    field :my_workspace_portfolio, list_of(:portfolio_item) do
      arg(:workspace_id, non_null(:id))

      resolve(fn _, %{workspace_id: workspace_id}, %{context: context} ->
        with_actor(context, fn actor ->
          Ash.read(Cgc2046.Accounts.PortfolioItem,
            action: :my_portfolio,
            tenant: workspace_id,
            actor: actor
          )
        end)
      end)
    end

    @desc "当前用户的 MCP 连接 token 列表（切片 D #44；不含明文，新→旧；policy 仅见本人）"
    field :my_mcp_tokens, list_of(:mcp_token) do
      resolve(fn _, _, %{context: context} ->
        with_actor(context, fn actor ->
          Cgc2046.Mcp.Token.list_for(actor)
        end)
      end)
    end

    @desc "当前用户作为 Owner/Admin 的跨工作台待审批项（Enrollment + JoinRequest + Sponsorship）；include_expired=true 时附带已过期行（只读展示，E-8 #123）"
    field :my_pending_approvals, non_null(list_of(non_null(:pending_approval))) do
      arg(:include_expired, :boolean)

      resolve(fn _, args, %{context: context} ->
        with_actor(context, fn actor ->
          Cgc2046.PendingApprovals.list(actor,
            include_expired: args[:include_expired] || false
          )
        end)
      end)
    end

    @desc "当前用户作为 Owner/Admin 的跨工作台可操作待办总数（Enrollment + JoinRequest + Sponsorship 的 pending 且未过审批截止）；已过期不计（KTD8 口径，与 /approvals 展示含过期行存在有意差异）"
    field :pending_approvals_count, non_null(:integer) do
      resolve(fn _, _, %{context: context} ->
        with_actor(context, fn actor ->
          case Cgc2046.PendingApprovals.count_pending(actor) do
            {:ok, count} -> {:ok, count}
            {:error, reason} -> {:error, reason}
          end
        end)
      end)
    end

    @desc "公开 Initiative 活动页投影；匿名可读，统一跨租户计数口径"
    field :public_initiative, :public_initiative do
      arg(:slug, non_null(:string))

      resolve(fn _, %{slug: slug}, _ ->
        case Cgc2046.Initiatives.Public.get_by_slug(slug) do
          {:ok, payload} -> {:ok, payload}
          {:error, :not_found} -> {:ok, nil}
          {:error, _} -> {:error, [message: "failed to load public initiative", code: "invalid"]}
        end
      end)
    end

    @desc "公开 Initiative 列表；匿名可读"
    field :public_initiatives, non_null(list_of(non_null(:public_initiative_card))) do
      resolve(fn _, _, _ ->
        case Cgc2046.Initiatives.Public.list() do
          {:ok, rows} -> {:ok, rows}
          {:error, _} -> {:error, [message: "failed to load public initiatives", code: "invalid"]}
        end
      end)
    end

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

    @desc "看板四率（U11/R24/KTD10，PlatformAdmin）：分子=FlashbackTouch 各事件 distinct person；分母=成功送达（硬退信与退订剔除）；分线=记忆线/圆梦线"
    field :flashback_admin_stats, :flashback_admin_stats do
      resolve(fn _, _, %{context: context} ->
        with_admin(context, fn _actor -> Cgc2046.Flashback.AdminStats.stats() end)
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

    @desc "闪念间·单人重发（R2/R10，PlatformAdmin）：不可重发者带原因业务错误（R5 拒绝表）；resend-* 独立批次"
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

    @desc "平台管理员：脱敏 workflow 运行元数据（不含 facts/input snapshot）"
    field :platform_workflow_audit, non_null(list_of(non_null(:platform_workflow_audit))) do
      arg(:workspace_id, :id)
      arg(:status, :string)
      arg(:started_after, :datetime)
      arg(:started_before, :datetime)

      resolve(fn _, args, %{context: context} ->
        with_admin(context, fn _actor ->
          {:ok,
           Cgc2046.Workflows.PlatformAudit.list(
             workspace_id: args[:workspace_id],
             status: args[:status],
             started_after: args[:started_after],
             started_before: args[:started_before]
           )}
        end)
      end)
    end

    @desc "当前用户在某工作台的 MCP 工具调用活动流（plan 020 U2.1；policy：workspace 成员 + 仅本人；params 摘要级不返回）"
    field :my_workspace_tool_calls, non_null(list_of(non_null(:workspace_tool_call))) do
      arg(:workspace_id, non_null(:id))
      arg(:first, :integer)

      resolve(fn _, args, %{context: context} ->
        # args 只含调用方提供的键（first 可缺省）——不能用固定键 pattern match。
        # 018：first 封顶（与 AdminList.paginate 共用上限），防无界全表导出
        with_actor(context, fn actor ->
          resolve_my_workspace_tool_calls(
            actor,
            args[:workspace_id],
            min(args[:first] || 50, AdminList.max_first())
          )
        end)
      end)
    end

    import_fields(:speaker_invitation_queries)

    import_fields(:admin_dashboard_queries)
    @desc "当前用户（申请人）的工作台创建申请列表（R7a；任何人可见自己的申请）"
    field :my_workspace_applications, non_null(list_of(non_null(:admin_workspace_application))) do
      resolve(fn _, _, %{context: context} ->
        with_actor(context, fn actor ->
          Cgc2046.Accounts.WorkspaceApplication
          |> Ash.Query.for_read(:read)
          |> Ash.Query.filter(applicant_id == ^actor.id)
          |> Ash.read(actor: actor)
          |> map_error(context, :read, Cgc2046.Accounts.WorkspaceApplication, Cgc2046.Accounts)
        end)
      end)
    end

    import_fields(:offering_queries)

    import_fields(:recruitment_queries)
    import_fields(:learning_queries)
  end

  mutation do
    @desc "账号密码登录（plan 002 U2：login 含 @ 走邮箱，否则手机号归一化；token 经 httpOnly cookie 交付）"
    field :sign_in, :sign_in_result do
      arg(:login, non_null(:string))
      arg(:password, non_null(:string))

      middleware(Cgc2046Web.Plugs.RateLimit,
        key_path: [:login],
        normalize: &Cgc2046.Accounts.WebAuthFlow.normalize_login/1
      )

      resolve(fn _, %{login: login, password: password}, _ ->
        # 分流：含 @ → email；否则按手机号归一化（同号不同写法命中同一 User 与同一限流 key）
        query =
          if String.contains?(login, "@") do
            Cgc2046.Accounts.User
            |> Ash.Query.for_read(:sign_in_with_password, %{email: login, password: password})
          else
            case Cgc2046.Accounts.PhoneNumber.normalize(login) do
              {:ok, phone} ->
                Cgc2046.Accounts.User
                |> Ash.Query.for_read(:sign_in_with_password_phone, %{
                  phone: phone,
                  password: password
                })

              {:error, :invalid} ->
                # 非法手机号格式：直接走 email 分支让其产出既有的统一认证失败错误
                # （防枚举语义不变，不新增格式错误出口）
                Cgc2046.Accounts.User
                |> Ash.Query.for_read(:sign_in_with_password, %{email: login, password: password})
            end
          end

        try do
          case Ash.read(query) do
            {:ok, [user]} ->
              {:ok,
               %{
                 id: user.id,
                 email: user.email,
                 is_platform_admin: user.is_platform_admin,
                 # token 仅用于 middleware 传递到 before_send，不暴露在响应中
                 __token__: user.__metadata__[:token]
               }}

            {:error, _error} ->
              {:error, message: "Invalid email or password", code: "authentication_failed"}
          end
        rescue
          _ -> {:error, message: "Invalid email or password", code: "authentication_failed"}
        end
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

    @desc "请求发送手机验证码（plan 002 U3；限流 phone 1/60s + 5/1h + 20/1d、IP 30/1d）"
    field :request_phone_code, :request_phone_code_result do
      arg(:phone, non_null(:string))
      arg(:purpose, non_null(:phone_code_purpose))

      resolve(fn _, %{phone: raw_phone, purpose: purpose}, %{context: context} ->
        with {:ok, phone} <- Cgc2046.Accounts.PhoneNumber.normalize(raw_phone),
             :ok <- Cgc2046.Accounts.WebAuthFlow.check_phone_code_request_limits(context, phone) do
          Cgc2046.Accounts.WebAuthFlow.request_phone_code(phone, purpose)
        else
          {:error, :invalid} ->
            {:error, message: "Invalid phone number", code: "invalid_phone"}

          {:error, :rate_limited} ->
            {:error, message: "Too many requests. Try again later.", code: "rate_limited"}
        end
      end)
    end

    @desc "手机验证码登录（plan 002 U3；用户不存在自动建号；token 经 httpOnly cookie 交付）"
    field :sign_in_with_phone_code, :sign_in_with_phone_code_result do
      arg(:phone, non_null(:string))
      arg(:code, non_null(:string))

      resolve(fn _, %{phone: raw_phone, code: code}, %{context: context} ->
        with {:ok, phone} <- Cgc2046.Accounts.PhoneNumber.normalize(raw_phone),
             :ok <- Cgc2046.Accounts.WebAuthFlow.check_phone_code_verify_limits(context, phone) do
          sign_in_with_phone_code(phone, code, context)
        else
          {:error, :invalid} ->
            {:error, message: "Invalid phone number", code: "invalid_phone"}

          {:error, :rate_limited} ->
            {:error, message: "Too many requests. Try again later.", code: "rate_limited"}
        end
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

    @desc "发起微信扫码登录（plan 002 U4；未配置 → wechat_login_unavailable；IP 20/15min 限流）"
    field :wechat_login_start, :wechat_login_start_result do
      @desc "发起微信扫码登录(plan 002 U4);next 透传进 redirect_uri(callback 页同源校验后跳转)"
      arg(:next, :string)

      resolve(fn _, args, %{context: context} ->
        if Cgc2046.Integrations.Wechat.WebOAuth.configured?() do
          with :ok <- Cgc2046.Accounts.WebAuthFlow.check_wechat_login_start_limits(context) do
            Cgc2046.Accounts.WebAuthFlow.start_wechat_login(args[:next])
          else
            {:error, :rate_limited} ->
              {:error, message: "Too many requests. Try again later.", code: "rate_limited"}
          end
        else
          {:error, message: "WeChat login is unavailable", code: "wechat_login_unavailable"}
        end
      end)

      # advisor02 M2：state 经 before_send 下发 httpOnly cgc_wechat_state cookie
      # 绑定发起浏览器（WechatStatePlug 读回校验）
      middleware(fn res, _ ->
        case res.value do
          %{state: state} when is_binary(state) ->
            %{res | context: Map.put(res.context, :cgc_wechat_state_set, state)}

          _ ->
            res
        end
      end)
    end

    @desc "微信扫码回调（plan 002 U4；IP 20/15min 限流）：已绑定直登，未绑定返回绑定票据"
    field :sign_in_with_wechat, :sign_in_with_wechat_result do
      arg(:code, non_null(:string))
      arg(:state, non_null(:string))

      resolve(fn _, %{code: code, state: state}, %{context: context} ->
        with :ok <- Cgc2046.Accounts.WebAuthFlow.check_wechat_callback_limits(context) do
          case Cgc2046.Accounts.WechatWebSignIn.sign_in_with_wechat(state, code, context) do
            {:ok, :signed_in, user} ->
              {:ok,
               %{
                 status: :signed_in,
                 bind_ticket: nil,
                 __token__: user.__metadata__[:token]
               }}

            {:ok, :needs_binding, bind_ticket} ->
              {:ok, %{status: :needs_binding, bind_ticket: bind_ticket}}

            {:error, reason} ->
              # 防枚举：客户端只收统一错误；服务端只记白名单分类，原始
              # code/token/身份值与下游 error struct 均不得进入日志。
              summary = Cgc2046.Accounts.WebAuthFlow.summarize_wechat_sign_in_failure(reason)
              Logger.warning("[wechat_web sign_in] failed: #{inspect(summary)}")

              {:error, message: "WeChat sign in failed", code: "wechat_sign_in_failed"}
          end
        else
          {:error, :rate_limited} ->
            {:error, message: "Too many requests. Try again later.", code: "rate_limited"}
        end
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

    @desc "微信扫码绑定手机号完成登录（plan 002 U4；phone 5/15min 限流）"
    field :bind_wechat_with_phone, :sign_in_with_phone_code_result do
      arg(:bind_ticket, non_null(:string))
      arg(:phone, non_null(:string))
      arg(:code, non_null(:string))

      resolve(fn _,
                 %{bind_ticket: bind_ticket, phone: raw_phone, code: code},
                 %{context: context} ->
        with {:ok, phone} <- Cgc2046.Accounts.PhoneNumber.normalize(raw_phone),
             :ok <- Cgc2046.Accounts.WebAuthFlow.check_wechat_bind_limits(context, phone) do
          case Cgc2046.Accounts.WechatWebSignIn.bind_wechat_with_phone(
                 bind_ticket,
                 phone,
                 code,
                 context
               ) do
            {:ok, user} ->
              {:ok,
               %{
                 id: user.id,
                 email: user.email,
                 is_platform_admin: user.is_platform_admin,
                 __token__: user.__metadata__[:token]
               }}

            {:error, :invalid_or_expired_code} ->
              {:error, message: "Invalid or expired code", code: "invalid_or_expired_code"}

            {:error, :invalid_bind_ticket} ->
              {:error, message: "Invalid binding session", code: "invalid_bind_ticket"}

            {:error, _reason} ->
              {:error, message: "Binding failed", code: "wechat_bind_failed"}
          end
        else
          {:error, :invalid} ->
            {:error, message: "Invalid phone number", code: "invalid_phone"}

          {:error, :rate_limited} ->
            {:error, message: "Too many requests. Try again later.", code: "rate_limited"}
        end
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

    @desc "手机号注册（验证码 + 密码；httpOnly cookie 交付 token，自动登录）"
    field :sign_up_with_phone, :sign_up_with_phone_payload do
      arg(:input, non_null(:sign_up_with_phone_input))

      resolve(fn _, %{input: %{phone: raw_phone, code: code, password: password}}, ctx ->
        context = ctx.context

        with {:ok, phone} <- Cgc2046.Accounts.PhoneNumber.normalize(raw_phone),
             :ok <- Cgc2046.Accounts.WebAuthFlow.check_phone_code_verify_limits(context, phone) do
          Cgc2046.Accounts.WebAuthFlow.sign_up_with_phone(phone, code, password, context)
        else
          {:error, :invalid} ->
            {:error, message: "Invalid phone number", code: "invalid_phone"}

          {:error, :rate_limited} ->
            {:error, message: "Too many requests. Try again later.", code: "rate_limited"}
        end
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

    @desc "请求发送密码重置邮件（无论邮箱是否存在都返回统一成功结果）"
    field :request_password_reset, :request_password_reset_result do
      arg(:email, non_null(:string))

      middleware(
        Cgc2046Web.Plugs.RateLimit,
        key_path: [:email],
        normalize: &Cgc2046.Accounts.WebAuthFlow.normalize_email/1
      )

      resolve(fn _, %{email: email}, %{context: context} ->
        email = Cgc2046.Accounts.WebAuthFlow.normalize_email(email)

        case Cgc2046.Accounts.WebAuthFlow.check_password_reset_request_limits(context, email) do
          :ok ->
            strategy = AshAuthentication.Info.strategy!(Cgc2046.Accounts.User, :password)

            _ =
              AshAuthentication.Strategy.action(
                strategy,
                :reset_request,
                %{"email" => email}
              )

            {:ok, %{sent: true}}

          :error ->
            {:error, message: "Too many requests. Try again later.", code: "rate_limited"}
        end
      end)
    end

    @desc "使用一次性密码重置 token 设置新密码"
    field :reset_password, :reset_password_result do
      arg(:reset_token, non_null(:string))
      arg(:password, non_null(:string))

      middleware(Cgc2046Web.Plugs.RateLimit, key_path: [:reset_token])

      resolve(fn _, %{reset_token: reset_token, password: password}, %{context: context} ->
        params = %{
          "reset_token" => reset_token,
          "password" => password
        }

        strategy = AshAuthentication.Info.strategy!(Cgc2046.Accounts.User, :password)

        try do
          case AshAuthentication.Strategy.action(strategy, :reset, params) do
            {:ok, _user} ->
              {:ok, %{ok: true}}

            {:error, error} ->
              Cgc2046.Accounts.WebAuthFlow.classify_password_reset_error(error, context)

            other ->
              Cgc2046.Accounts.WebAuthFlow.report_password_reset_failure(other)
          end
        rescue
          error ->
            Cgc2046.Accounts.WebAuthFlow.report_password_reset_failure(error)
        catch
          kind, reason ->
            Cgc2046.Accounts.WebAuthFlow.report_password_reset_failure({kind, reason})
        end
      end)
    end

    @desc "小程序平台一键登录（N1，Phase 1）：code2session + 平台手机号锚定统一身份，token 经 httpOnly cookie 交付"
    field :sign_in_with_platform, :sign_in_with_platform_result do
      arg(:platform, non_null(:string))
      arg(:code, non_null(:string))
      arg(:phone_code, :string)
      arg(:encrypted_data, :string)
      arg(:iv, :string)

      # #930：IP 维度只留宽松天花板（线下活动同一 WiFi / CGNAT 多人共享 IP）；
      # getPhoneNumber 计费防刷改按 openid 计（SignInPreparation，code2session 之后、换手机号之前）
      middleware(Cgc2046Web.Plugs.RateLimit, key_path: [:platform], limit: :platform_sign_in_ip)

      resolve(fn _, %{platform: platform, code: code} = args, _ ->
        # phone_code/encrypted_data/iv 可空（phone_code 或 encrypted_data+iv 二选一，
        # 由 SignInPreparation.fetch_phone 校验组合）；缺键时 Map.get 得 nil 透传。
        query =
          Cgc2046.Accounts.User
          |> Ash.Query.for_read(:sign_in_with_miniprogram, %{
            platform: platform,
            code: code,
            phone_code: Map.get(args, :phone_code),
            encrypted_data: Map.get(args, :encrypted_data),
            iv: Map.get(args, :iv)
          })

        try do
          case Ash.read(query) do
            {:ok, [user]} ->
              {:ok,
               %{
                 id: user.id,
                 email: user.email,
                 is_platform_admin: user.is_platform_admin,
                 # token 仅用于 middleware 传递到 before_send，不暴露在响应中
                 __token__: user.__metadata__[:token]
               }}

            {:error, error} ->
              if platform_sign_in_rate_limited?(error),
                do:
                  {:error, message: "Too many requests. Try again later.", code: "rate_limited"},
                else: {:error, message: "Platform sign in failed", code: "authentication_failed"}
          end
        rescue
          _ -> {:error, message: "Platform sign in failed", code: "authentication_failed"}
        catch
          # Elixir rescue 不抓 exit（如依赖进程缺失 noproc）——缺此分支则
          # 登录失败穿透至 Absinthe/Plug 500 且无统一文案，防枚举语义被绕过。
          :exit, _ ->
            {:error, message: "Platform sign in failed", code: "authentication_failed"}
        end
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

    @desc "记录一次小程序订阅消息授权并增加一个可用次数"
    field :grant_mini_program_notification_consent, :integer do
      arg(:platform, non_null(:string))
      arg(:template_key, non_null(:string))

      # #930：与登录拆桶——grant 本来就要求登录，按账号计（原「IP + 平台」桶与登录共用，
      # 1 次登录 + 1 次三模板订阅就吃掉 4/5，再登录即 Too many requests）
      resolve(fn _, %{platform: platform, template_key: template_key}, %{context: context} ->
        with_actor(context, fn actor ->
          key = Cgc2046Web.Plugs.RateLimit.build_key("rate:notification-consent:actor", actor.id)

          with :ok <- Cgc2046Web.Plugs.RateLimit.check(key, limit: :notification_consent_actor),
               {:ok, remaining} <-
                 Cgc2046.Notifications.Consent.grant(actor.id, platform, template_key) do
            {:ok, remaining}
          else
            :error ->
              {:error, message: "Too many requests. Try again later.", code: "rate_limited"}

            {:error, :invalid_platform} ->
              {:error, message: "Invalid platform", code: "invalid_platform"}

            {:error, _} ->
              {:error, message: "Consent grant failed", code: "consent_grant_failed"}
          end
        end)
      end)
    end

    @desc "登出：服务端撤销当前 token 并清除 httpOnly cookie（token 被偷也无法重放）"
    field :sign_out, :string do
      resolve(fn _, _, _ ->
        {:ok, "signed_out"}
      end)

      middleware(fn res, _ ->
        revoke_bearer_token(res.context)
        %{res | context: Map.put(res.context, :cgc_clear_token, true)}
      end)
    end

    @desc "更新当前用户全局显示名（ADR-0004：displayName 保留全局身份字段）"
    field :update_display_name, :user do
      arg(:display_name, non_null(:string))

      resolve(fn _, %{display_name: display_name}, %{context: context} ->
        with_actor(context, fn actor ->
          case Ash.update(actor, %{display_name: display_name},
                 action: :update_display_name,
                 actor: actor
               ) do
            {:ok, user} ->
              # member_number/joined_at 为计算属性，返回前需显式加载
              load_profile(user, actor, context, :update_display_name)

            {:error, error} ->
              {:error, to_ash_graphql_errors(error, context, :update_display_name)}
          end
        end)
      end)
    end

    @desc "绑定/换绑当前用户手机号（验证码 purpose=CHANGE_PHONE 验新号；仅本人；目标号已被他人占用即拒绝，不做自助合并）"
    field :update_my_phone, :user do
      arg(:phone, non_null(:string))
      arg(:code, non_null(:string))

      resolve(fn _, %{phone: raw_phone, code: code}, %{context: context} ->
        with_actor(context, fn actor ->
          with {:ok, phone} <- Cgc2046.Accounts.PhoneNumber.normalize(raw_phone),
               :ok <- Cgc2046.Accounts.WebAuthFlow.check_phone_code_verify_limits(context, phone),
               :ok <-
                 Cgc2046.Accounts.PhoneVerificationCode.consume_valid(phone, code, :change_phone) do
            Cgc2046.Accounts.WebAuthFlow.update_my_phone(actor, phone, context)
          else
            {:error, :invalid} ->
              {:error, message: "Invalid phone number", code: "invalid_phone"}

            {:error, :rate_limited} ->
              {:error, message: "Too many requests. Try again later.", code: "rate_limited"}

            {:error, :invalid_code} ->
              {:error, message: "Invalid or expired code", code: "invalid_or_expired_code"}

            {:error, :code_not_available} ->
              {:error, message: "Invalid or expired code", code: "invalid_or_expired_code"}
          end
        end)
      end)
    end

    @desc "更新当前用户界面语言偏好（i18n Phase 1；zh-CN | en，仅本人）"
    field :update_my_locale, :user do
      arg(:locale, non_null(:string))

      resolve(fn _, %{locale: locale}, %{context: context} ->
        with_actor(context, fn actor ->
          case Ash.update(actor, %{locale: locale},
                 action: :update_locale,
                 actor: actor
               ) do
            {:ok, user} ->
              load_profile(user, actor, context, :update_locale)

            {:error, error} ->
              {:error, to_ash_graphql_errors(error, context, :update_locale)}
          end
        end)
      end)
    end

    @desc "拒绝首公里接入邀请（每次登录弹直到明确拒绝；幂等保留首次拒绝时间戳，仅本人）"
    field :dismiss_onboarding_invitation, :user do
      resolve(fn _, _, %{context: context} ->
        with_actor(context, fn actor ->
          case Ash.update(actor, %{},
                 action: :dismiss_onboarding_invitation,
                 actor: actor
               ) do
            {:ok, user} ->
              load_profile(user, actor, context, :dismiss_onboarding_invitation)

            {:error, error} ->
              {:error, to_ash_graphql_errors(error, context, :dismiss_onboarding_invitation)}
          end
        end)
      end)
    end

    @desc "更新当前用户在某工作台的资料（ADR-0004 per-workspace）"
    field :update_workspace_profile, :workspace_profile do
      arg(:workspace_id, non_null(:id))
      arg(:input, non_null(:update_workspace_profile_input))

      resolve(fn _, %{workspace_id: workspace_id, input: input}, %{context: context} ->
        with_actor(context, fn actor ->
          scoped_update(
            actor,
            Cgc2046.Accounts.WorkspaceProfile,
            workspace_id,
            :update_profile,
            map_input(input),
            context
          )
        end)
      end)
    end

    @desc "设置当前用户在某工作台的 UI 主题偏好（ADR-0004 per-workspace）"
    field :set_workspace_theme, :workspace_profile do
      arg(:workspace_id, non_null(:id))
      arg(:input, non_null(:set_workspace_theme_input))

      resolve(fn _, %{workspace_id: workspace_id, input: input}, %{context: context} ->
        with_actor(context, fn actor ->
          scoped_update(
            actor,
            Cgc2046.Accounts.WorkspaceProfile,
            workspace_id,
            :set_ui_theme,
            %{ui_theme_preference: input.ui_theme_preference},
            context
          )
        end)
      end)
    end

    @desc "在某工作台创建作品集条目（ADR-0004；workspace_id 与 user_id 自动填充，防跨租户伪造）"
    field :create_portfolio_item, :portfolio_item do
      arg(:workspace_id, non_null(:id))
      arg(:input, non_null(:create_portfolio_item_input))

      resolve(fn _, %{workspace_id: workspace_id, input: input}, %{context: context} ->
        with_actor(context, fn actor ->
          attrs = map_input(input, [:title, :description, :url, :icon])

          Cgc2046.Accounts.PortfolioItem
          |> Ash.Changeset.for_create(:create, attrs)
          |> Ash.create(tenant: workspace_id, actor: actor)
        end)
      end)
    end

    @desc "更新某工作台自己的作品集条目（ADR-0004；tenant 隔离）"
    field :update_portfolio_item, :portfolio_item do
      arg(:id, non_null(:id))
      arg(:workspace_id, non_null(:id))
      arg(:input, non_null(:update_portfolio_item_input))

      resolve(fn _, %{id: id, workspace_id: workspace_id, input: input}, %{context: context} ->
        with_actor(context, fn actor ->
          attrs = map_input(input, [:title, :description, :url, :icon])

          with {:ok, item} <-
                 Cgc2046.Accounts.PortfolioItem
                 |> Ash.get(id, tenant: workspace_id, actor: actor) do
            item
            |> Ash.Changeset.for_update(:update, attrs)
            |> Ash.update(tenant: workspace_id, actor: actor)
          end
        end)
      end)
    end

    @desc "删除某工作台自己的作品集条目（ADR-0004；tenant 隔离）"
    field :delete_portfolio_item, :portfolio_item do
      arg(:id, non_null(:id))
      arg(:workspace_id, non_null(:id))

      resolve(fn _, %{id: id, workspace_id: workspace_id}, %{context: context} ->
        with_actor(context, fn actor ->
          with {:ok, item} <-
                 Cgc2046.Accounts.PortfolioItem
                 |> Ash.get(id, tenant: workspace_id, actor: actor) do
            case Ash.destroy(item, tenant: workspace_id, actor: actor) do
              :ok -> {:ok, item}
              {:error, error} -> {:error, error}
            end
          end
        end)
      end)
    end

    @desc "签发 MCP 连接 token（切片 D #44；明文仅本次经 plainToken 返回一次，库中只存 SHA256 hash）"
    field :create_mcp_token, :create_mcp_token_payload do
      arg(:name, non_null(:string))

      resolve(fn _, %{name: name}, %{context: context} ->
        with_actor(context, fn actor ->
          case Cgc2046.Mcp.Token.issue(name, actor) do
            {:ok, token, plain} ->
              {:ok, %{result: token, plain_token: plain, errors: []}}

            {:error, error} ->
              {:ok,
               %{
                 result: nil,
                 plain_token: nil,
                 errors:
                   to_ash_graphql_errors(error, context, :issue, Cgc2046.Mcp.Token, Cgc2046.Mcp)
               }}
          end
        end)
      end)
    end

    @desc "撤销 MCP 连接 token（切片 D #44；仅本人，置 revokedAt 保留审计行；他人 token 一律 not_found 不泄露存在性）"
    field :revoke_mcp_token, :mcp_token do
      arg(:id, non_null(:id))

      resolve(fn _, %{id: id}, %{context: context} ->
        with_actor(context, fn actor ->
          case Cgc2046.Mcp.Token.revoke(id, actor) do
            {:ok, revoked} ->
              {:ok, revoked}

            {:error, :not_found} ->
              # NotFound（他人 token / 不存在 id）统一塌缩，不泄露存在性。
              # 与 invalid 分支同经 AshGraphql 序列化（message/code/fields 齐备），
              # 恢复 AshGraphql 原行为的 error 结构（message "could not be found"、
              # fields ["id"]）。
              {:error,
               to_ash_graphql_errors(
                 Ash.Error.Query.NotFound.exception(
                   primary_key: %{id: id},
                   resource: Cgc2046.Mcp.Token
                 ),
                 context,
                 :revoke,
                 Cgc2046.Mcp.Token,
                 Cgc2046.Mcp
               )}

            {:error, {:invalid, error}} ->
              {:error,
               to_ash_graphql_errors(error, context, :revoke, Cgc2046.Mcp.Token, Cgc2046.Mcp)}
          end
        end)
      end)
    end

    import_fields(:payment_operation_mutations)

    import_fields(:speaker_invitation_mutations)

    import_fields(:admin_dashboard_mutations)

    import_fields(:offering_mutations)

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
          params = %{
            level: level,
            chosen_quote_spans: Map.get(args, :chosen_quote_spans),
            credited_note: Map.get(args, :credited_note)
          }

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

    @desc "自助找回·发起（U6/R21/KTD7）：手机精确匹配→邮箱兜底；命中与未命中同形返回（不泄露存在性）；双窗口限流"
    field :flashback_recover, :flashback_recover_result do
      arg(:identifier, non_null(:string))

      middleware(Cgc2046Web.Plugs.RateLimit, key_path: [:identifier])

      resolve(fn _, %{identifier: identifier}, %{context: context} ->
        flashback_call(fn ->
          Cgc2046.Flashback.Recover.initiate(identifier, context_ip(context))
        end)
      end)
    end

    @desc "自助找回·验证（U6/R21）：手机验证码通过 → find-or-create User + 绑定全部匹配档案（token 全部作废，R1）；返回脱敏卡列表（你的 N 张卡）"
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

    @desc "自助找回·验证（已登录，#932）：手机验证码通过 → 匹配档案绑定到当前登录账号（不 find-or-create、不换会话）；号码或档案已属于另一个账号 → flashback_recover_account_conflict（不静默合并）；发起沿用 flashbackRecover"
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

    import_fields(:recruitment_mutations)
  end

  # id 入参形态校验（R36/R38）：Absinthe 的 :id 是 string，非法 uuid 直接进
  # Ecto.UUID.dump! 会抛；这里 fail-closed 成业务码（不泄露存在性）。
  defp validate_like_person_id(person_id) when is_binary(person_id) do
    case Ecto.UUID.cast(person_id) do
      {:ok, uuid} ->
        {:ok, uuid}

      :error ->
        {:error,
         %{
           code: "flashback_quote_not_found",
           message: "quote not found",
           reason: :quote_not_found
         }}
    end
  end

  defp validate_like_person_id(_) do
    {:error,
     %{code: "flashback_quote_not_found", message: "quote not found", reason: :quote_not_found}}
  end

  # ── RBAC 类型（#66 角色权限矩阵；原 rbac_types.ex 内联，唯一消费者为本 schema） ──

  object :ability_grant do
    field(:name, non_null(:string),
      description:
        "能力名：view_workspace / access_invite_only / list_members / manage_members / assign_roles / create_workspace"
    )

    field(:allowed, non_null(:boolean))
  end

  object :permission_matrix_row do
    field(:name, non_null(:string),
      description: "角色名：owner / admin / tutor / volunteer / learner"
    )

    field(:abilities, non_null(list_of(non_null(:ability_grant))))
  end

  object :permission_matrix_payload do
    field(:roles, non_null(list_of(non_null(:permission_matrix_row))))
  end

  object :offering_readiness_payload do
    field(:ready, non_null(:boolean))
    field(:items, non_null(list_of(non_null(:offering_readiness_item))))
  end

  object :offering_readiness_item do
    field(:key, non_null(:string))
    field(:label, non_null(:string))
    field(:ok, non_null(:boolean))
  end

  object :pending_approval do
    field(:id, non_null(:id))
    field(:kind, non_null(:string))
    field(:workspace_id, non_null(:id))
    field(:user_id, non_null(:id))
    field(:event_id, :id)
    field(:course_id, :id)
    field(:status, non_null(:string))
    field(:approval_deadline, :datetime)
    field(:expired_at, :datetime)
    field(:requester_name, :string)
    field(:workspace_name, :string)
    field(:context_title, :string)

    # E-9 #123 expired 重提链接落点字段（workspace_slug 全 kind；event_slug
    # 仅 sponsorship event 级行非空，可空供给物无 slug）
    field(:workspace_slug, :string)
    field(:event_slug, :string)

    # E-3 #48 sponsorship 行（其他 kind 为 null）
    field(:level, :string)
    field(:company_name, :string)
    field(:contact_email, :string)
    field(:tier_name, :string)
    field(:amount, :integer)
  end

  object :platform_workflow_audit do
    field(:id, non_null(:id))
    field(:workspace_id, non_null(:id))
    field(:definition_type, non_null(:string))
    field(:status, non_null(:string))
    field(:started_at, :datetime)
    field(:finished_at, :datetime)
    field(:inserted_at, non_null(:datetime))
    field(:error_summary, :string)
  end

  object :workspace_tool_call do
    field(:id, non_null(:id))
    field(:tool, non_null(:string))
    field(:status, non_null(:string))
    field(:latency_ms, :integer)
    field(:inserted_at, non_null(:datetime))
    field(:error_message, :string)
  end

  object :miniprogram_code_result do
    field(:invitation_id, non_null(:id))
    field(:platform, non_null(:string))
    field(:scene, non_null(:string))
    field(:code_base64, non_null(:string))
    field(:expires_at, non_null(:datetime))
  end

  # ── 认证相关类型（#60 路径 B：httpOnly cookie 交付 token） ──────────────

  # 持 token 的邀请接口限流：validate/accept 均吃明文 token 参数，按 IP+token 计，
  # 5 次/15 分钟（复用 RateLimit plug，与 sign_in/sign_up 同档位）。
  # token 为 256-bit 强随机，枚举不成立；此为已知 token 被滥用探测时的加固。
  # arity-3：Absinthe 的 middleware callback 是 arity-3（schema.middleware(mw, field, object)），
  # arity-2 不会被框架调用。
  def middleware(middleware, %{identifier: :validate_invitation}, _object),
    do: [{Cgc2046Web.Plugs.RateLimit, key_path: [:token]} | middleware]

  # 注：accept_invitation 现为手写 field，RateLimit 在 field 内显式挂载
  # （手写 field 不经过 middleware/3 回调），不再需要此处的 identifier 分支。

  def middleware(middleware, _field, _object), do: middleware

  object :sign_in_result do
    field(:id, non_null(:id))
    field(:email, non_null(:string))
    field(:is_platform_admin, non_null(:boolean))
  end

  object :request_password_reset_result do
    field(:sent, non_null(:boolean))
  end

  object :reset_password_result do
    field(:ok, non_null(:boolean))
  end

  # 小程序手机号用户无邮箱 → email 可空（与 users.email 放宽一致）
  object :sign_in_with_platform_result do
    field(:id, non_null(:id))
    field(:email, :string)
    field(:is_platform_admin, non_null(:boolean))
  end

  # 手机验证码登录（plan 002 U3）：phone 用户 email 可空（同 platform result）
  object :request_phone_code_result do
    field(:sent, non_null(:boolean))
    field(:retry_after_seconds, non_null(:integer))
  end

  enum :phone_code_purpose do
    value(:login)
    value(:wechat_bind)
    value(:register)
    value(:change_phone)
  end

  object :sign_in_with_phone_code_result do
    field(:id, non_null(:id))
    field(:email, :string)
    field(:is_platform_admin, non_null(:boolean))
  end

  # 微信扫码登录（plan 002 U4）
  object :wechat_login_start_result do
    field(:qr_url, non_null(:string))
    field(:state, non_null(:string))
    field(:expires_in_seconds, non_null(:integer))
  end

  object :sign_in_with_wechat_result do
    field(:status, non_null(:wechat_sign_in_status))
    field(:bind_ticket, :string)
  end

  enum :wechat_sign_in_status do
    value(:signed_in)
    value(:needs_binding)
  end

  @desc "手机号注册结果（email 可空——无邮箱手机号用户，同 phone code 登录 result）"
  object :sign_up_with_phone_user do
    field(:id, non_null(:id))
    field(:email, :string)
    field(:is_platform_admin, non_null(:boolean))
  end

  object :sign_up_with_phone_payload do
    field(:result, :sign_up_with_phone_user)
    field(:errors, list_of(:mutation_error))
  end

  input_object :sign_up_with_phone_input do
    field(:phone, non_null(:string))
    field(:code, non_null(:string))
    field(:password, non_null(:string))
  end

  # ── 个人资料相关类型（ADR-0004 per-workspace）────────────────────────

  object :workspace_profile do
    @desc "per-workspace 成员公开资料（ADR-0004）"
    field(:id, non_null(:id))
    field(:workspace_id, non_null(:id))
    field(:user_id, non_null(:id))
    field(:avatar_url, :string)
    field(:location, :string)
    field(:about, :string)
    field(:skills, list_of(:string))
    field(:visibility, :string)
    field(:ui_theme_preference, non_null(:string))
  end

  object :portfolio_item do
    @desc "per-workspace 作品集条目（ADR-0004）"
    field(:id, non_null(:id))
    field(:workspace_id, non_null(:id))
    field(:title, non_null(:string))
    field(:description, :string)
    field(:url, :string)
    field(:icon, non_null(:string))
  end

  input_object :update_workspace_profile_input do
    @desc "updateWorkspaceProfile 输入（ADR-0004）：avatarUrl/location/about/skills/visibility 可选"
    field(:avatar_url, :string)
    field(:location, :string)
    field(:about, :string)
    field(:skills, list_of(:string))
    field(:visibility, :string)
  end

  input_object :set_workspace_theme_input do
    @desc "setWorkspaceTheme 输入：uiThemePreference 必填，仅 dark | light"
    field(:ui_theme_preference, non_null(:string))
  end

  input_object :create_portfolio_item_input do
    @desc "createPortfolioItem 输入：title 必填，description/url/icon 可选"
    field(:title, non_null(:string))
    field(:description, :string)
    field(:url, :string)
    field(:icon, :string)
  end

  input_object :update_portfolio_item_input do
    @desc "updatePortfolioItem 输入：title/description/url/icon 可选"
    field(:title, :string)
    field(:description, :string)
    field(:url, :string)
    field(:icon, :string)
  end

  # ── MCP 连接 token（切片 D #44；手写三入口，资源不经 AshGraphql 自动暴露）──

  object :mcp_token do
    @desc "MCP 连接 token（明文不可经此类型读回；hash 不落 GraphQL 面）"
    field(:id, non_null(:id))
    field(:name, non_null(:string))
    field(:last_used_at, :datetime)
    field(:revoked_at, :datetime)
    field(:inserted_at, non_null(:datetime))
  end

  object :create_mcp_token_payload do
    @desc "createMcpToken 返回：result 为 token 记录；plainToken 明文仅此一次"
    field(:result, :mcp_token)
    field(:plain_token, :string)
    field(:errors, list_of(:mutation_error))
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

  # ── 闪念间（In a Flash）首程 token 面类型（U2；手写 field 专用） ──────────
  # 投影纪律（KTD3）：白名单列字段；phone/email 明文绝不出现（只有掩码）。
  # 圆梦线 CTA 两态指路（U4）：只投指路字段，无个人数据。
  object :flashback_dream_target do
    field(:event_slug, non_null(:string))
    field(:event_title, non_null(:string))
    field(:starts_at, :datetime)
    field(:initiative_slug, non_null(:string))
  end

  # ── 时间胶囊（U5）校友层类型：分层墙（R12）与行动板（R13） ──────────────
  # 投影纪律（KTD3）：白名单列字段；手机/邮箱不进任何投影；他人答案一律雾化。

  object :flashback_capsule_today do
    field(:now_status, :string)
    field(:want, :string)
    field(:need, :string)
    field(:say, :string)
    @desc "句级雾面：field(now/want/need/say) → spans；本人管理面专用"
    field(:fog_spans, :json)
    field(:sent_to_wall_at, :string)
  end

  object :flashback_capsule_me do
    field(:id, non_null(:id))
    field(:full_name, non_null(:string))
    field(:surname, :string)
    field(:city, :string)
    field(:occupation_then, :string)
    field(:participation, non_null(:string))
    field(:applied_at, :string)
    field(:today, :flashback_capsule_today)
    @desc "金句授权档（R31：off/anonymous/credited；无授权行为 off）——回访端恢复选中态"
    field(:quote_level, non_null(:string))
    @desc "选定金句（R14 摘要卡；off/未选为 null）"
    field(:quote, :string)
    @desc "句子白名单区间列表（首句 = 消费面展示句;圈选器回显全量）"
    field(:quote_spans, list_of(:flashback_quote_span))
    @desc "本人金句的点赞数（R36；仅匿名/实名授权档返回，未授权为 null）"
    field(:quote_stats, :flashback_quote_stats)
    @desc "本人当年答案（U9 起含原文与既有雾面区间——编辑雾化消费面；text 仍为雾化版）"
    field(:answers, non_null(list_of(non_null(:flashback_me_answer))))
    @desc "卡片分享（#771）：开关态 + 标识 + 本人预览；预览独立于公开门（关着也有）"
    field(:card_sharing, non_null(:flashback_card_sharing))
  end

  # ── 卡片分享（#771）：本人管理面 + 匿名公开面 ──────────────────────────
  # 投影纪律（KTD3 同款）：分享卡只出隐名（王**）+ 城市 + 报名时间 +
  # 当年三题与今天四格；手机/邮箱/性别/职业/公开 slug/授权档一律不进 SELECT。
  # 雾面段 text 恒空串——原文字符不出响应体（FogSpans.segments 保证）。
  object :flashback_card_sharing do
    @desc "分享链接是否可被访客解析（关 = 链接 404，标识仍保留）"
    field(:enabled, non_null(:boolean))
    @desc "分享标识：首开铸出后**永不变**（关闭不清、重开复用）；从未开启为 null"
    field(:share_id, :string)
    @desc "本人预览（与公开面同一投影，不受 enabled 门限制）；档案已删除为 null"
    field(:preview, :flashback_shared_card)
  end

  object :flashback_shared_card do
    @desc "隐名（姓氏 + 星号，如 王**）；分享卡无亮名路径"
    field(:display_name, non_null(:string))
    field(:city, :string)
    @desc "报名时间戳（ISO8601，精确到秒）；落款用——她写下这张卡的那一刻"
    field(:applied_at, :string)
    @desc "活动举办日（ISO8601 日期，如 2014-01-11）；头部场景定位用——记忆真正发生的那天"
    field(:occurred_on, :string)
    @desc "当年答案（实时保存数据，无「已寄出」前置）：键 self_intro / funny_thing / os；空节剔除"
    field(:answers, non_null(list_of(non_null(:flashback_shared_card_section))))
    @desc "今天四格（实时保存数据）：键 today.now / today.want / today.need / today.say；空节剔除"
    field(:today, non_null(list_of(non_null(:flashback_shared_card_section))))
  end

  object :flashback_shared_card_section do
    field(:question_key, non_null(:string))
    @desc "段结构（原文顺序）：明文段 text 有字、雾面段 text 恒空串（原文零泄露），len 供视觉档位"
    field(:segments, non_null(list_of(non_null(:flashback_shared_card_segment))))
  end

  object :flashback_shared_card_segment do
    field(:text, non_null(:string))
    field(:fog, non_null(:boolean))
    field(:len, non_null(:integer))
  end

  object :flashback_me_answer do
    field(:id, non_null(:id))
    field(:question_key, non_null(:string))
    @desc "原文（KTD4：本人在任何视图永远完整）"
    field(:raw_text, non_null(:string))
    @desc "既有雾面区间（本人调整的起点）"
    field(:fog_spans, non_null(list_of(non_null(:flashback_fog_span))))
    @desc "雾化版（与墙上呈现同规则，R15 全文卡）"
    field(:text, non_null(:string))
  end

  object :flashback_roster_segment do
    @desc "雾面段（对外版）：fog=true 时 text 恒为空——原文字符不出 DOM，len 供视觉档位"
    field(:text, non_null(:string))
    field(:fog, non_null(:boolean))
    field(:len, non_null(:integer))
  end

  object :flashback_roster_answer do
    @desc "当年答案（对外版）：段结构——明文段与雾面段交替，雾面段零字符泄露"
    field(:question_key, non_null(:string))
    field(:segments, non_null(list_of(non_null(:flashback_roster_segment))))
  end

  object :flashback_roster_entry_today do
    field(:now_status, :string)
    field(:want, :string)
    field(:say, :string)
  end

  object :flashback_roster_entry do
    field(:id, non_null(:id))
    @desc "姓氏隐名（R12）：王**；名册结构化卡的核心标识"
    field(:surname_masked, non_null(:string))
    @desc "寄出者全名（用户定稿：她回来了即亮名）；未寄出者 null（隐名）"
    field(:full_name, :string)
    @desc "寄出者的报名时间戳（翻转卡正面白边）；未寄出者 null"
    field(:applied_at, :string)
    field(:city, :string)
    field(:occupation_then, :string)
    @desc "attended | not_selected（圆梦线名册徽标用）。#933 起仅已寄出者下发；未寄出者 null（只剩姓氏遮罩）"
    field(:participation, :string)
    field(:sent_to_wall_at, :string)
    @desc "nil = 未寄出（前端渲染虚线内容位「她的答案，还在等她」）"
    field(:today, :flashback_roster_entry_today)
    @desc "空数组 = 未寄出；寄出者才有内容层（雾化版当年答案）"
    field(:answers, non_null(list_of(non_null(:flashback_roster_answer))))
  end

  object :flashback_archive_pile do
    field(:city, non_null(:string))
    field(:count, non_null(:integer))
    field(:returned, non_null(:integer))
  end

  @desc "相册读面（#933）：已登录即可读的场次时间轴与名册"
  object :flashback_archives_result do
    field(:archives, non_null(list_of(non_null(:flashback_capsule_archive))))
    field(:cities, non_null(list_of(non_null(:string))))
  end

  object :flashback_capsule_archive do
    field(:key, non_null(:string))
    field(:name, :string)
    field(:city, :string)
    field(:occurred_on, :string)
    field(:applied_count, :integer)
    field(:attended_count, :integer)

    @desc "长廊场次格叙事短标签（原型 D ia-frame-label）：「六城同日」写故事不写地名"
    field(:label, :string)
    @desc "本人的场次（胶囊「今天」格与本人名册卡的定位锚）"
    field(:is_mine, non_null(:boolean))
    field(:roster, non_null(list_of(non_null(:flashback_roster_entry))))
    @desc "城市堆（#933 服务端聚合）：按人的城市计数（含未寄出者的聚合数）+ 已回来数；人数降序 + 城市序"
    field(:piles, non_null(list_of(non_null(:flashback_archive_pile))))
  end

  object :flashback_capsule do
    field(:me, non_null(:flashback_capsule_me))
    field(:archives, non_null(list_of(non_null(:flashback_capsule_archive))))
    @desc "未来场次帧：按 initiative 分组、组内按场次时间升序（KTD1）；报名直链 /events/{slug}"
    field(:future_events, non_null(list_of(non_null(:flashback_future_frame))))
    @desc "公开愿望（附议数降序）；城市钉筛选时无城市许愿恒显示"
    field(:public_wishes, non_null(list_of(non_null(:flashback_wish))))
    @desc "本人私有许愿（私人许愿帧，仅自己可见）"
    field(:my_private_wishes, non_null(list_of(non_null(:flashback_wish))))
    @desc "本人今年剩余许愿额度（每年 3 条，R20）；capsule 可解析时恒有值，nullable 仅为 schema 演进安全"
    field(:my_wish_quota_remaining, :integer)
    @desc "城市钉数据源（R34）：有名册成员的城市，去重排序；不随 city 过滤收缩"
    field(:cities, non_null(list_of(non_null(:string))))
  end

  object :flashback_future_frame do
    @desc "帧头跳转目标：/initiatives/{initiative_slug}（R1）"
    field(:initiative_slug, non_null(:string))
    field(:initiative_name, non_null(:string))
    @desc "未显影帧时间：initiative 窗口开始时间（未来=还没冲洗的底片,报名/附议即显影）"
    field(:initiative_starts_at, :datetime)
    field(:events, non_null(list_of(non_null(:flashback_future_event))))
  end

  object :flashback_future_event do
    field(:id, non_null(:id))
    @desc "报名直链：/events/{slug}（R2/R3，不在走廊内闭环）"
    field(:slug, non_null(:string))
    field(:title, non_null(:string))
    field(:city, :string)
    field(:starts_at, :datetime)
    @desc "名额进度（U7 与 web enrollmentBadge 口径对齐）"
    field(:capacity, :integer)
    field(:confirmed_count, non_null(:integer))
    field(:registration_deadline, :datetime)
  end

  object :flashback_wish do
    field(:id, non_null(:id))
    field(:content, non_null(:string))
    field(:city, :string)
    @desc "许愿人遮罩姓（王**）"
    field(:wisher_masked, :string)
    field(:endorsement_count, non_null(:integer))
    @desc "本人已附议（已附议态渲染依据，R7）"
    field(:endorsed_by_me, non_null(:boolean))
    @desc "本人许愿（删除入口只对本人显示，R14）"
    field(:mine, non_null(:boolean))
    field(:comments, non_null(list_of(non_null(:flashback_wish_comment))))
    field(:latest_echo, :flashback_public_wish_echo)
    field(:echo_count, non_null(:integer))
    field(:echoes, non_null(list_of(non_null(:flashback_public_wish_echo))))
    field(:inserted_at, non_null(:datetime))
  end

  object :flashback_admin_wish_echo do
    field(:id, non_null(:id))
    field(:content, non_null(:string))
    field(:status, non_null(:string))
    field(:inserted_at, non_null(:datetime))
    field(:published_at, :datetime)
    field(:corrected_at, :datetime)
    field(:revoked_at, :datetime)
    @desc "发布时的 PlatformAdmin UUID，仅 admin 读面"
    field(:published_by_user_id, :id)
  end

  object :flashback_admin_wish_echoes_result do
    field(:echoes, non_null(list_of(non_null(:flashback_admin_wish_echo))))
    field(:current_notifiable_endorsement_count, non_null(:integer))
  end

  object :flashback_admin_listed_wish_entry do
    field(:wish_id, non_null(:id))
    field(:content, non_null(:string))
    field(:signature, :string)
    field(:city, :string)
    field(:listed_at, non_null(:datetime))
    @desc "已发布/已更正回响数（公开可见）"
    field(:published_echo_count, non_null(:integer))
    @desc "草稿回响数（仅 admin）"
    field(:draft_echo_count, non_null(:integer))
  end

  object :flashback_wish_comment do
    field(:id, non_null(:id))
    field(:content, non_null(:string))
    @desc "留言人遮罩姓"
    field(:commenter_masked, :string)
    field(:inserted_at, non_null(:datetime))
  end

  object :flashback_my_wishes do
    field(:quota_remaining, non_null(:integer))
    field(:wishes, non_null(list_of(non_null(:flashback_owned_wish))))
  end

  object :flashback_owned_wish do
    field(:id, non_null(:id))
    field(:content, non_null(:string))
    field(:city, :string)
    field(:signature, non_null(:string))
    field(:visibility, non_null(:string))
    field(:status, non_null(:string))
    field(:inserted_at, non_null(:datetime))
  end

  object :flashback_wish_result do
    @desc "新建愿望 id（本人查看/撤回入口用）"
    field(:id, :id)
    @desc "附议后实时计数与本人态"
    field(:endorsement_count, non_null(:integer))
    field(:endorsed_by_me, non_null(:boolean))
    @desc "wish2 U8 三态反馈：listed（挂上许愿树）/ pending_review（信用待审——审核通过后挂树）/ private（说给主办方听）"
    field(:status, non_null(:string))
  end

  # ── 看板与兑换（U11/R24/R25）────────────────────────────────────────

  object :flashback_rates do
    @desc "分母：成功送达人数（sent 的 distinct person，硬退信与退订剔除）"
    field(:delivered, non_null(:integer))
    field(:link_opened, non_null(:integer))
    field(:revealed, non_null(:integer))
    field(:sent_to_wall, non_null(:integer))
    field(:intent_submitted, non_null(:integer))
  end

  object :flashback_admin_stats do
    @desc "记忆线（participation=attended）四率"
    field(:memory, non_null(:flashback_rates))
    @desc "圆梦线（participation=not_selected）四率"
    field(:dream, non_null(:flashback_rates))
    field(:overall, non_null(:flashback_rates))
  end

  object :flashback_redemption do
    field(:id, non_null(:id))
    field(:status, non_null(:string))
    @desc "用户提交的收款渠道信息（admin-only，KTD3）"
    field(:channel_note, non_null(:string))
    field(:handled_note, :string)
    field(:inserted_at, :string)
    @desc "掩码署名（姓** · 城市）——运营定位用"
    field(:masked_name, :string)
    field(:city, :string)
  end

  object :flashback_redemption_update_result do
    field(:id, non_null(:id))
    field(:status, non_null(:string))
  end

  # ── 触达运营台（R4/R8/R9）────────────────────────────────────────────
  object :flashback_admin_archive do
    field(:key, non_null(:string))
    field(:name, non_null(:string))
    # 教练场等档案无具体日期/城市（occurred_on/city 可空，运营后台直建）
    field(:city, :string)
    field(:occurred_on, :string)
  end

  object :flashback_outreach_preview do
    field(:archive_key, non_null(:string))
    field(:archive_name, non_null(:string))
    @desc "所选通道档的预估入队数"
    field(:channel, non_null(:string))
    field(:queued, non_null(:integer))
    @desc "三档分布：仅邮件可达 / 仅短信可达 / 双通道"
    field(:email_only, non_null(:integer))
    field(:sms_only, non_null(:integer))
    field(:both, non_null(:integer))
    field(:unsubscribed, non_null(:integer))
    field(:unreachable, non_null(:integer))
    @desc "campaign 去重预判（batch 参数非空时：可达人中联系方式命中该批次已有成功触达的人数；未传 batch 恒 0）"
    field(:deduped_within_campaign, non_null(:integer))
    @desc "短信腿就绪位（SendCloud 触达模板已配置）"
    field(:sms_ready, non_null(:boolean))
  end

  object :flashback_outreach_batch_channel do
    field(:queued, non_null(:integer))
    field(:sent, non_null(:integer))
    field(:failed, non_null(:integer))
  end

  object :flashback_outreach_batch do
    field(:batch, non_null(:string))
    field(:template, non_null(:string))
    field(:email, non_null(:flashback_outreach_batch_channel))
    field(:sms, non_null(:flashback_outreach_batch_channel))
    @desc "批次最早建行时刻（触发时间近似）"
    field(:first_at, :string)
  end

  object :flashback_outreach_last do
    field(:channel, non_null(:string))
    field(:status, non_null(:string))
    field(:batch, non_null(:string))
    field(:at, :string)
  end

  object :flashback_outreach_roster_entry do
    field(:person_id, non_null(:id))
    field(:full_name, non_null(:string))
    @desc "完整联系方式（KD6/R13：platform_admin 门控，排查核对用）"
    field(:email, :string)
    field(:phone, :string)
    field(:claimed, non_null(:boolean))
    field(:participation, non_null(:string))
    field(:unsubscribed, non_null(:boolean))
    field(:deleted, non_null(:boolean))
    field(:email_reachable, non_null(:boolean))
    field(:sms_reachable, non_null(:boolean))
    field(:last_outreach, :flashback_outreach_last)
  end

  object :flashback_redeem_result do
    field(:status, non_null(:string))
    field(:updated, non_null(:boolean))
  end

  # ── 删除（U10/R30/ADR-0015）────────────────────────────────────────
  object :flashback_delete_result do
    field(:deleted, non_null(:boolean))
    field(:deleted_at, non_null(:string))
  end

  object :flashback_delete_preview_result do
    field(:person_id, non_null(:id))
    field(:full_name, non_null(:string))
    @desc "寄出态（撤下提示依据）；未寄出为 null"
    field(:sent_to_wall_at, :string)
    @desc "将一并删除的附议数"
    field(:endorsement_count, non_null(:integer))
    field(:already_deleted, non_null(:boolean))
  end

  # ── 公开层类型（U6/R32）：路人可见的故事与授权的名字，不是名单 ──────────
  object :flashback_public_stats_archive do
    field(:key, non_null(:string))
    field(:name, :string)
    field(:city, :string)
    field(:occurred_on, :string)
    field(:applied_count, :integer)
    field(:attended_count, :integer)
    field(:label, :string)
  end

  object :flashback_public_stats do
    field(:archives, non_null(list_of(non_null(:flashback_public_stats_archive))))
    @desc "已回来人数（distinct link_opened touch）"
    field(:returned_count, non_null(:integer))
    field(:sent_count, non_null(:integer))
  end

  object :flashback_public_quote do
    @desc "授权金句文本（区间切片；雾面句本就不进候选）"
    field(:text, non_null(:string))
    @desc "署名：王** · 年 · 城"
    field(:attribution, non_null(:string))
    field(:level, non_null(:string))
    @desc "credited 档才有：链实名档案页"
    field(:public_slug, :string)
    @desc "单句定位键（R37）：flashbackLikeQuote 的 quoteId 入参 / 分享链接 ?item="
    field(:quote_id, non_null(:id))
    @desc "城市快照（选城浏览用）"
    field(:city, :string)
    @desc "年份快照（选城浏览用）"
    field(:year, :integer)
    @desc "实时点赞数（R36，无冗余计数列）"
    field(:like_count, non_null(:integer))
    @desc "本访客是否已赞（按 voterKey 去重；未传 voterKey 恒 false）"
    field(:liked_by_viewer, non_null(:boolean))
  end

  object :flashback_public_profile do
    field(:full_name, non_null(:string))
    field(:city, :string)
    field(:event_name, :string)
    field(:year, :integer)
    @desc "实名补充：现在在做什么、想法（R31 credited 档）"
    field(:credited_note, :string)
    field(:quote, non_null(:string))
  end

  object :flashback_recover_result do
    @desc "恒 true 形态：命中与未命中同形返回（不泄露存在性）"
    field(:dispatched, non_null(:boolean))
  end

  object :flashback_recover_card do
    field(:person_id, non_null(:id))
    field(:surname_masked, non_null(:string))
    field(:event_name, :string)
    field(:city, :string)
  end

  object :flashback_recover_verify_result do
    field(:bound, non_null(:boolean))
    @desc "绑定档案的脱敏卡列表——多档案=「你的 N 张卡」由本人选择先看哪张"
    field(:cards, non_null(list_of(non_null(:flashback_recover_card))))
  end

  object :flashback_fog_span do
    @desc "雾面区间：grapheme 偏移（start 起、len 长），reason 可选"
    field(:start, non_null(:integer))
    field(:len, non_null(:integer))
    field(:reason, :string)
  end

  object :flashback_answer do
    @desc "当年答案（本人视图：raw_text 永远完整，KTD4）"
    field(:id, non_null(:id))
    field(:question_key, non_null(:string))
    field(:raw_text, non_null(:string))
    field(:fog_spans, list_of(:flashback_fog_span))
  end

  object :flashback_archive_ref do
    field(:key, non_null(:string))
    field(:name, :string)
    field(:city, :string)
    field(:occurred_on, :string)
  end

  object :flashback_profile do
    field(:full_name, non_null(:string))
    field(:surname, :string)
    field(:city, :string)
    field(:occupation_then, :string)
    field(:gender, :string)
    field(:role, non_null(:string))
    field(:participation, non_null(:string))
    field(:applied_at, :string)
    field(:archive, :flashback_archive_ref)
    field(:answers, list_of(:flashback_answer))
  end

  object :flashback_today do
    field(:now_status, :string)
    field(:want, :string)
    field(:need, :string)
    field(:say, :string)
    @desc "句级雾面区间（字段名 → spans；U9/R16，空 map = 无雾）"
    field(:fog_spans, :json)
    field(:want_give_tags, list_of(:string))
    field(:mobilization, :json_string)
    field(:newsletter_opt_in, :boolean)
    field(:reconnect_tags, list_of(:string))
    field(:sent_to_wall_at, :string)
  end

  object :flashback_progress do
    field(:today, :flashback_today)
    field(:quote_level, non_null(:string))
    field(:masked_phone, :string)
    field(:masked_email, :string)
  end

  object :flashback_enter_result do
    @desc "进入结果：line = memory（记忆线）| dream（圆梦线）；失效走顶层错误 code（flashback_token_not_found/claimed/revoked）"
    field(:line, non_null(:string))
    field(:profile, :flashback_profile)
    field(:progress, :flashback_progress)

    @desc "桌面散照候选（R5 数据驱动）：本人那张 + 其他场次各一人；空库时仅本人一张"
    field(:scatter, :flashback_scatter)
  end

  object :flashback_scatter do
    field(:entries, non_null(list_of(non_null(:flashback_scatter_photo))))
  end

  object :flashback_scatter_photo do
    @desc "照片定位键（本人 = 本人档案 id；他人 = 他人档案 id）"
    field(:photo_key, non_null(:id))

    @desc "场次全名标签「年份 · 城市」——问答选项与读屏线索用（散照卡只显日期戳）"
    field(:label, non_null(:string))

    @desc "拍立得日期戳「2016 10 15」——放大时渐显，只给日期不给城市（谜不泄底）"
    field(:date_stamp, non_null(:string))

    @desc "是否本人那张"
    field(:is_mine, non_null(:boolean))

    @desc "照片主人姓氏（前端渲染姓氏级脱敏 王**，R12）"
    field(:surname, :string)
  end

  object :flashback_touch_result do
    field(:recorded, non_null(:boolean))
  end

  object :flashback_today_result do
    field(:today, :flashback_today)
  end

  object :flashback_send_to_wall_result do
    field(:sent_to_wall_at, :string)
    field(:masked_phone, :string)
    field(:masked_email, :string)
  end

  object :flashback_adjust_today_fog_result do
    field(:field, non_null(:string))
    field(:fog_spans, :json)
  end

  object :flashback_adjust_fog_result do
    field(:answer_id, non_null(:id))
    field(:fog_spans, list_of(:flashback_fog_span))
  end

  object :flashback_quote_stats do
    @desc "点赞数（R36：作者侧回访面，实时 COUNT）"
    field(:like_count, non_null(:integer))
  end

  object :flashback_claim_result do
    @desc "是否已绑定（false = 库里没有匹配的未认领档案）"
    field(:bound, non_null(:boolean))
    @desc "本次绑定/已绑定的档案数"
    field(:bound_count, non_null(:integer))
    @desc "掩码回显（完整号码不出接口）"
    field(:masked_phone, :string)
  end

  object :flashback_quote_hidden_result do
    field(:person_id, non_null(:id))
    @desc "操作后的下线态（true=已下线）"
    field(:hidden, non_null(:boolean))
  end

  object :flashback_quote_like_result do
    @desc "点赞后的实时计数——前端就地更新，免二次拉取"
    field(:like_count, non_null(:integer))
  end

  # ── wish2 U6 公开许愿树契约（KTD10 白名单字段）──────────────────────

  object :flashback_public_wish do
    field(:id, non_null(:id))
    field(:content, non_null(:string))
    @desc "期望地短名（Cities.normalize 归一；null = 未填）"
    field(:city, :string)
    @desc "署名快照（匿名遮罩姓 王** 或实名 display_name；创建时定型）"
    field(:signature, non_null(:string))
    field(:expectation_count, non_null(:integer))
    field(:endorsement_count, non_null(:integer))
    @desc "出力分布（venue/organize/speak/sponsor/other → count）——从 endorsements 聚合"
    field(:contribution_distribution, non_null(:json))
    field(:expected_by_viewer, non_null(:boolean))
    field(:endorsed_by_viewer, non_null(:boolean))
    field(:latest_echo, :flashback_public_wish_echo)
    field(:echo_count, non_null(:integer))
    field(:echoes, non_null(list_of(non_null(:flashback_public_wish_echo))))
    field(:listed_at, non_null(:datetime))
    field(:inserted_at, non_null(:datetime))
  end

  object :flashback_public_wish_echo do
    field(:id, non_null(:id))
    field(:content, non_null(:string))
    field(:status, non_null(:string))
    field(:published_at, non_null(:datetime))
    field(:corrected_at, :datetime)
  end

  object :flashback_city do
    @desc "短名（成都）"
    field(:name, non_null(:string))
    @desc "全称（成都市）"
    field(:full_name, non_null(:string))
    field(:pinyin, non_null(:string))
    @desc "中心坐标 [lng, lat]（GeoJSON 形状，G9）"
    field(:lng_lat, non_null(list_of(non_null(:float))))
  end

  object :flashback_wish_expect_result do
    @desc "期待后的实时计数 + 本人态"
    field(:expectation_count, non_null(:integer))
    field(:expected_by_me, non_null(:boolean))
  end

  object :flashback_wish_endorse_result do
    field(:endorsement_count, non_null(:integer))
    field(:endorsed_by_me, non_null(:boolean))
  end

  object :flashback_report_result do
    field(:report_id, non_null(:id))
    field(:status, non_null(:string))
  end

  object :flashback_wish_hidden_result do
    field(:wish_id, non_null(:id))
    @desc "操作后的下架态（true=已下架）"
    field(:hidden, non_null(:boolean))
  end

  object :flashback_admin_wish_inbox_entry do
    field(:wish_id, non_null(:id))
    field(:content, non_null(:string))
    field(:city, :string)
    field(:signature, non_null(:string))
    field(:inserted_at, non_null(:datetime))
    @desc "作者遮罩姓（王**）"
    field(:wisher_masked, :string)
    @desc "作者登录账号联系方式（仅 platform admin；公开 GraphQL 永不返回）"
    field(:wisher_phone, :string)
    field(:wisher_email, :string)
  end

  object :flashback_admin_report_entry do
    field(:report_id, non_null(:id))
    field(:target_type, non_null(:string))
    field(:target_id, non_null(:id))
    field(:reason_type, non_null(:string))
    field(:reason_free, :string)
    field(:status, non_null(:string))
    field(:inserted_at, non_null(:datetime))
  end

  # 多句金句:每句自带宿主与区间(grapheme 偏移,结构同 fog span)
  input_object :flashback_quote_span_input do
    field(:question_key, non_null(:string))
    field(:start, non_null(:integer))
    field(:len, non_null(:integer))
  end

  object :flashback_quote_span do
    field(:question_key, non_null(:string))
    field(:start, non_null(:integer))
    field(:len, non_null(:integer))
  end

  object :flashback_quote_license_result do
    field(:level, non_null(:string))
    field(:chosen_quote_spans, list_of(:flashback_quote_span))
    field(:credited_note, :string)
  end

  object :flashback_retract_result do
    field(:retracted, non_null(:boolean))
    field(:sent_to_wall_at, :string)
  end

  object :flashback_register_bind_result do
    field(:bound, non_null(:boolean))
    field(:masked_phone, :string)
  end

  object :flashback_update_contact_result do
    field(:masked_phone, :string)
    field(:updated, non_null(:boolean))
  end

  object :flashback_outreach_dispatch_result do
    @desc "入队件数（错峰 scheduled_at 限速后由 worker 续发）"
    field(:queued, non_null(:integer))
    @desc "跳过件数（已退订 / 无可用通道 / 本批次已入队——幂等重跑计入此处）"
    field(:skipped, non_null(:integer))
    @desc "campaign 去重件数（同批次内联系方式命中他人已有成功触达——同人跨 archive 只收一封）"
    field(:deduped_within_campaign, non_null(:integer))
  end

  input_object :flashback_today_input do
    @desc "「今天的你」问卷（R8）：四个自由文本 + Want/Give 标签 + 动员勾选（R20）+ Newsletter（R18）+ Reconnect（R19）"
    field(:now_status, :string)
    field(:want, :string)
    field(:need, :string)
    field(:say, :string)
    field(:want_give_tags, list_of(:string))
    field(:mobilization_join_1024, :boolean)
    field(:mobilization_help_promote, :boolean)
    field(:mobilization_donate_intent, :boolean)
    field(:mobilization_volunteer_lead, :boolean)
    field(:newsletter_opt_in, :boolean)
    field(:reconnect_tags, list_of(:string))
  end

  input_object :flashback_fog_span_input do
    field(:start, non_null(:integer))
    field(:len, non_null(:integer))
    field(:reason, :string)
  end

  # 找回限流的 IP 提取（同 WebAuthFlow.remote_ip 口径；conn 由 plug 上下文携带）
  defp context_ip(%{conn: %{remote_ip: ip}}), do: ip |> :inet.ntoa() |> to_string()
  defp context_ip(_context), do: "unknown"

  # wish2 U6：登录 actor 的 user_id（未登录 nil——匿名 voter 走 a: 键）
  defp actor_user_id(%{actor: %{id: id}}) when is_binary(id), do: id
  defp actor_user_id(_context), do: nil

  # wish2 review HS-3：读面 viewer 双键集——登录 = 强制 u:<uid> + 入参 a: 键
  # （a: 入参与期待 mutation 的 anonVoterKey merge 语义对称，刷新不漂移）；
  # 未登录 = 入参单键（a: 设备键原样）。入参 u: 键仅未登录时透传（低危回显，
  # 登录时被 actor 键取代——不可借此窥探他人）。
  defp viewer_voter_keys(context, arg_key) do
    case actor_user_id(context) do
      nil ->
        [arg_key]

      uid ->
        ["u:#{uid}" | [arg_key]]
    end
  end

  # voter_key 只在 a: 前缀时当 anon 键用（u: 由 actor_user_id 强制）
  defp anon_key_from(nil), do: nil
  defp anon_key_from("a:" <> _ = key), do: key
  defp anon_key_from(_), do: nil

  # 闪念间写面双入口（U9/R28）：token 优先（首程/链接回访）；省略时按登录
  # actor 解析绑定的档案（person.user_id）。返回 {:token, t} | {:person, id}，
  # 与 capsule 读面的 resolve_person 同语义；两者皆无 → auth_required。
  # Wish authorship needs an account, not an archive. Other archive operations
  # deliberately keep flashback_identity's existing eligibility boundary.
  defp wish_identity(token, %{actor: %{id: id}}) when token in [nil, ""], do: {:ok, {:user, id}}

  defp wish_identity(token, context) do
    with {:ok, identity} <- flashback_identity(token, context),
         {:ok, id} <- identity_person_id(identity),
         do: {:ok, {:person, id}}
  end

  defp flashback_identity(token, context) do
    cond do
      is_binary(token) and token != "" ->
        case Cgc2046.Flashback.Tokens.fetch_valid(token) do
          {:ok, _flashback_token} -> {:ok, {:token, token}}
          {:error, error} -> {:error, error}
        end

      not is_nil(context[:actor]) ->
        case Cgc2046.Flashback.AlumniProjection.resolve_person(nil, context[:actor]) do
          {:ok, %{person: person}} -> {:ok, {:person, person.id}}
          {:error, error} -> {:error, error}
        end

      true ->
        {:error,
         %{
           code: "flashback_auth_required",
           message: "token or sign-in required",
           reason: :auth_required
         }}
    end
  end

  # 闪念间身份元组 → person_id（U9/U11 写面共用：redeem 等不需 person 结构的入口）。
  defp identity_person_id({:token, token}) do
    case Cgc2046.Flashback.Tokens.fetch_valid(token) do
      {:ok, flashback_token} -> {:ok, flashback_token.person_id}
      {:error, error} -> {:error, error}
    end
  end

  defp identity_person_id({:person, person_id}), do: {:ok, person_id}

  # wish2 U8/KTD1：signature_choice 字符串→atom（context opts 契约）；
  # 非法/缺省宽容降级 anonymous——旧客户端与拼写错误不因此拒绝整单
  defp wish_signature_choice("display_name"), do: :display_name
  defp wish_signature_choice(_), do: :anonymous

  # 闪念间手写 field 的统一错误映射：domain 信封原样透传（code 进 #241 契约）；
  # Ash 校验错误经 domain 的 invalid_input_error/1 包装；其余按 DB 故障兜底。
  defp flashback_call(fun) do
    case fun.() do
      {:ok, value} ->
        {:ok, value}

      # wish2 U8/KTD11：city_unknown 信封带 candidates（≤3 候选城市）——
      # map 模式匹配需余字段容忍，candidates 保留在 extensions 供前端提示
      {:error, %{code: code, message: message} = envelope}
      when is_binary(code) and is_map(envelope) ->
        {:error, [message: message, code: code] ++ envelope_extra(envelope)}

      {:error, %Ash.Error.Invalid{errors: [first | _]}} ->
        envelope = Cgc2046.Flashback.Tokens.invalid_input_error(Exception.message(first))
        {:error, message: envelope.message, code: envelope.code}

      {:error, _other} ->
        {:error, message: "服务暂时不可用，请稍后重试。", code: "database_error"}
    end
  end

  # 信封余字段（如 city_unknown 的 candidates）→ keyword 附加项；
  # code/message 已显式消费，只透传非空名单类补充信息
  defp envelope_extra(envelope) do
    case envelope[:candidates] || Map.get(envelope, :candidates) do
      candidates when is_list(candidates) and candidates != [] -> [candidates: candidates]
      _ -> []
    end
  end

  # 动员勾选拍平 → mobilization map（存储形状单一，前端不必拼 JSON）。
  defp today_params(input) do
    %{
      now_status: Map.get(input, :now_status),
      want: Map.get(input, :want),
      need: Map.get(input, :need),
      say: Map.get(input, :say),
      want_give_tags: Map.get(input, :want_give_tags) || [],
      mobilization: %{
        "join_1024" => Map.get(input, :mobilization_join_1024) || false,
        "help_promote" => Map.get(input, :mobilization_help_promote) || false,
        "donate_intent" => Map.get(input, :mobilization_donate_intent) || false,
        "volunteer_lead" => Map.get(input, :mobilization_volunteer_lead) || false
      },
      newsletter_opt_in: Map.get(input, :newsletter_opt_in) || false,
      reconnect_tags: Map.get(input, :reconnect_tags) || []
    }
  end

  defp sign_in_with_phone_code(phone, code, context) do
    case Cgc2046.Accounts.PhoneCodeSignIn.sign_in_with_phone_code(phone, code, context) do
      {:ok, user} ->
        {:ok,
         %{
           id: user.id,
           email: user.email,
           is_platform_admin: user.is_platform_admin,
           __token__: user.__metadata__[:token]
         }}

      {:error, :invalid_or_expired_code} ->
        {:error, message: "Invalid or expired code", code: "invalid_or_expired_code"}

      {:error, reason} ->
        Logger.warning("[signInWithPhoneCode] failed: #{inspect(reason)}")
        {:error, message: "Sign in failed", code: "phone_code_sign_in_failed"}
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

  # 统一的个人资料加载：member_number/joined_at 为计算属性，获取与更新后均需显式加载。
  # 加载失败（罕见：calculation/DB 异常）经 to_ash_graphql_errors 映射，与
  # update_profile/set_ui_theme 同源——避免把 Ash 内部 stacktrace 当 string 返给客户端。
  # `action` 用于错误路径解析（与出错 mutation 的 action 对齐，nil 表示 query 侧 me）。
  defp load_profile(user, actor, context, action) do
    case Ash.load(user, [:member_number, :joined_at],
           actor: actor,
           domain: Cgc2046.Accounts
         ) do
      {:ok, loaded} ->
        {:ok, loaded}

      {:error, error} ->
        {:error, to_ash_graphql_errors(error, context, action)}
    end
  end

  # owner 域 read-first update 组合子（PR-E D5）：filter(user_id == ^actor.id) +
  # read_one(tenant:, actor:) → {:ok, nil} 分支错误单点（workspace_profile_not_found）
  # → for_update(action, attrs) → Ash.update(tenant:, actor:)。错误路径经
  # to_ash_graphql_errors 显式透传 resource（message/code/fields 逐字保留）。
  # 消费方：update_workspace_profile(:update_profile, map_input 全量) /
  # set_workspace_theme(:set_ui_theme, 单字段)。
  defp scoped_update(actor, resource, tenant_id, action, attrs, context) do
    case resource
         |> Ash.Query.for_read(:read)
         |> Ash.Query.filter(user_id == ^actor.id)
         |> Ash.read_one(tenant: tenant_id, actor: actor) do
      {:ok, nil} ->
        {:error,
         message: "Workspace profile not found or not accessible",
         code: "workspace_profile_not_found"}

      {:ok, profile} ->
        profile
        |> Ash.Changeset.for_update(action, attrs)
        |> Ash.update(tenant: tenant_id, actor: actor)

      {:error, error} ->
        {:error, to_ash_graphql_errors(error, context, action, resource)}
    end
  end

  # #930：SignInPreparation 把 openid 限流标成 caused_by.reason = :rate_limited；其余失败
  # 一律统一为 authentication_failed（防枚举）。限流如实告知：openid 来自请求者自己的 code，不泄露他人信息。
  defp platform_sign_in_rate_limited?(%{errors: errors}) when is_list(errors),
    do: Enum.any?(errors, &platform_sign_in_rate_limited?/1)

  defp platform_sign_in_rate_limited?(%AshAuthentication.Errors.AuthenticationFailed{
         caused_by: %{reason: :rate_limited}
       }),
       do: true

  defp platform_sign_in_rate_limited?(_), do: false

  # 服务端撤销当前 token：往 tokens 表对当前 jti 做 upsert，把 purpose 从 "user"
  # 覆盖成 "revocation"，下次 load_from_bearer 的 get_token 查不到 user 记录即认证失败。
  # token 由 AuthTokenContextPlug 从 Authorization header 透传进 Absinthe context。
  # 撤销失败不阻断登出：仍清 cookie 让用户侧登出成功，token 会在 7 天自然过期。
  defp revoke_bearer_token(context) do
    case context[:cgc_bearer_token] do
      token when is_binary(token) and byte_size(token) > 0 ->
        case AshAuthentication.TokenResource.Actions.revoke(Cgc2046.Accounts.Token, token, []) do
          :ok ->
            :ok

          {:error, reason} ->
            Logger.warning("signOut token revoke failed: #{inspect(reason)}")
        end

      _ ->
        :ok
    end
  end

  object :admin_workspace_application do
    field(:id, non_null(:id))
    field(:applicant_id, non_null(:id))
    field(:name, non_null(:string))
    field(:slug, non_null(:string))
    field(:purpose, non_null(:string))
    field(:status, non_null(:string))
    field(:rejection_reason, :string)
    # #116 R10a：处理人/时间（approve/reject 对称四字段；pending/expired 为 null）
    field(:approved_by, :id)
    field(:approved_at, :datetime)
    field(:rejected_by, :id)
    field(:rejected_at, :datetime)
    field(:inserted_at, non_null(:datetime))
  end

  object :public_initiative do
    field(:id, non_null(:id))
    field(:name, non_null(:string))
    field(:slug, non_null(:string))
    field(:hashtag, :string)
    field(:description, :string)
    field(:window_starts_at, :datetime)
    field(:window_ends_at, :datetime)
    field(:status, non_null(:string))
    field(:city_count, non_null(:integer))
    field(:event_count, non_null(:integer))
    field(:confirmed_count, non_null(:integer))
    field(:qualified_event_count, non_null(:integer))
    field(:cities, non_null(list_of(non_null(:public_initiative_city))))
  end

  object :public_initiative_card do
    field(:id, non_null(:id))
    field(:name, non_null(:string))
    field(:slug, non_null(:string))
    field(:hashtag, :string)
    field(:description, :string)
    field(:window_starts_at, :datetime)
    field(:window_ends_at, :datetime)
    field(:status, non_null(:string))
  end

  object :public_initiative_city do
    field(:city, non_null(:string))
    field(:events, non_null(list_of(non_null(:public_initiative_event))))
  end

  object :public_initiative_event do
    field(:id, non_null(:id))
    field(:slug, non_null(:string))
    field(:title, non_null(:string))
    field(:status, non_null(:string))
    field(:visibility, non_null(:string))
    field(:starts_at, :datetime)
    field(:ends_at, :datetime)
    field(:registration_deadline, :datetime)
    field(:venue, :json_string)
    field(:confirmed_count, non_null(:integer))
    field(:min_participants, :integer)
    field(:qualification_status, :string)
    field(:archived, non_null(:boolean))
    field(:qualification_badge, non_null(:string))
    field(:short_by, :integer)

    # 参与条件披露（#627）：缴费槽三态 + 押金明细 + 年龄门槛存在性 + 收费金额锚。
    # 全部来自 Event 已物化快照列（`Initiatives.Public` 的裸 SQL 投影），不暴露规则表。
    field(:payment_mode, non_null(:string))
    field(:deposit, non_null(:public_initiative_deposit))
    field(:min_age, :integer)
    field(:price_range_min_cents, :integer)
  end

  @desc "公开页押金明细（#627）：金额缺失/非正时 amountCents 为 null，enabled 仍 true——绝不显示 ¥0"
  object :public_initiative_deposit do
    field(:enabled, non_null(:boolean))
    field(:amount_cents, :integer)
    field(:refundable_on_check_in, :boolean)
  end

  # plan 020 U2.1：本人 MCP 工具调用活动流。
  # policy（显式判定，与 Wrapper 成员门槛同源）：workspace 成员 + 仅本人。
  # 过滤：params JSONB 内 workspace_id（键名 params["workspace_id"]，Wrapper 落库
  # 格式，assumption 1）+ user_id == actor.id；排序 inserted_at desc + id desc。
  # 非成员统一 forbidden；读取经 authorize?: false 直读（ToolCallLog 读 policy 仍
  # platform_admin 专属，本查询按成员+本人独立门控，params 摘要级不返回）。
  defp resolve_my_workspace_tool_calls(actor, workspace_id, first) do
    if Cgc2046.Accounts.MembershipContext.membership_of(actor, workspace_id) do
      ws_id = to_string(workspace_id)

      query =
        Cgc2046.Mcp.ToolCallLog
        |> Ash.Query.filter(user_id == ^actor.id)
        |> Ash.Query.filter(fragment("params->>'workspace_id' = ?", ^ws_id))
        |> Ash.Query.sort(inserted_at: :desc, id: :desc)
        |> Ash.Query.limit(first)

      case Ash.read(query, authorize?: false) do
        {:ok, logs} ->
          {:ok,
           Enum.map(logs, fn log ->
             %{
               id: log.id,
               tool: log.tool,
               status: to_string(log.result_status),
               latency_ms: log.latency_ms,
               inserted_at: log.inserted_at,
               error_message: log.error_message
             }
           end)}

        {:error, error} ->
          {:error, to_ash_graphql_errors(error, %{}, :read, Cgc2046.Mcp.ToolCallLog, Cgc2046.Mcp)}
      end
    else
      {:error, [message: "forbidden", code: "forbidden"]}
    end
  end

  defp resolve_readiness(id, actor) do
    with {:ok, entity} <- fetch_offering_by_id(id, actor) do
      {:ok, Cgc2046.Offering.Readiness.evaluate(entity)}
    end
  end

  # offeringReadiness 目标可能是 Event 或 Course（原 event 优先、失败回退 course）。
  # 读取唯一真源 = Offering；**必须显式 authorize?: true**（D2 风险：Offering 默认
  # authorize?: false 会绕过 read policy，actor 感知读取退化为全量可见）。
  defp fetch_offering_by_id(id, actor) do
    case Cgc2046.Offering.fetch(:event, id, actor: actor, authorize?: true) do
      {:ok, entity} -> {:ok, entity}
      {:error, _} -> Cgc2046.Offering.fetch(:course, id, actor: actor, authorize?: true)
    end
  end
end
