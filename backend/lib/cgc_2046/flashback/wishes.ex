defmodule Cgc2046.Flashback.Wishes do
  @moduledoc """
  许愿写面（走廊未来帧，KTD2/KTD3/KTD4）。

  - **创建**（R5/R6）：`visibility` ∈ public|private（提交时定终，KD9 无转换）；
    `city` 快照许愿人的名册城市（无城市入参，nil 允许——无城市许愿在任何
    城市钉下都显示）；`content` 去空白非空且 ≤500 字（服务端长度防线）。
  - **附议**（R7）：一人一愿幂等（`unique_wish_person` 唯一索引 + upsert
    承接并发双击）；返回实时计数与 `endorsed_by_me`。
  - **留言**（R8）：公开愿望可留言，正文约束同 content；按时间正序展示。
  - **软删单源**（KTD4）：`soft_delete_wish/2`、`soft_delete_comment/2`
    ——学员自助删除（R14）与平台 MCP 删除（R18）共用同一实现，只置
    `deleted_at`（审计由 ToolCallLog 承担），不写第二条删除路径。
  - **年度额度**（R20）：每 person 每自然年（Asia/Shanghai）最多创建
    3 条愿望，按创建行为计数——含私有、含已软删，删除不退还额度；
    并发经 person 行 FOR UPDATE 锁串行化（同 card_sharing lock_row 协议）；
    `quota_remaining/1` 供走廊读面透出本人剩余额度。
  """

  require Ash.Query

  alias Cgc2046.Flashback.{AlumniProjection, Cities, Wish, WishComment, WishEndorsement}
  alias Cgc2046.Integrations.Wechat.Client, as: WechatClient
  alias Cgc2046.Repo

  @content_max_length 500
  @visibilities ~w(public private)
  @annual_wish_quota 3

  # KTD4 机审：user_identities.provider → content_check 平台参数。
  # 与 admission/enrollment.ex:36 同口径（保持先例字段映射单源）。
  @content_check_platforms %{"wechat" => :wechat, "tt" => :tt, "xhs" => :xhs}

  # KTD4 ③：openid 解析失败（未认领 token-only 长尾）→ 跳过检测并记
  # telemetry，本批不声称覆盖该长尾，先发后审兜底（KTD5）。
  @openid_unresolved_event [:cgc_2046, :content_check, :openid_unresolved]

  # ── 创建（R5/R6） ────────────────────────────────────────────────────

  @doc """
  许愿：visibility 二选一；city 快照许愿人名册城市（U1 KTD11 改用「期望地」，
  默认名册城市归一值）；年度额度 R20。
  KTD4：内容过微信 msgSecCheck v2（enrollment.ex:777-833 同链）——违规/待审
  fail-closed 返回 `flashback_content_rejected`；「说给主办方听」(private) 同样
  过机审但不进人工队列（KTD5 收件箱是 admin 读面，本批零队列写入）。

  **U1 KTD1**：opts 接受下列键（全可选，宽容向下兼容旧调用方）：
    - `:signature_choice` ∈ `:anonymous | :display_name`（默认 `:anonymous`）——
      决定 `signature` 快照：匿名走 `AlumniProjection.masked_name/1`；
      `:display_name` 按 KTD4 ①→② 链经 `person.user_id` LEFT JOIN users 取
      `u.display_name`（`users.display_name` 是真实列）；已认领 token-only
      person（user_id 非空但 display_name 为空）或未认领 person 回退 masked
      实名 `AlumniProjection.masked_name(person)`。
    - `:expected_city` ∈ `nil | binary`——nil 时按名册城市经
      `Cities.normalize/1` 归一（失败留空）；非 nil 强制归一，失败返回
      `flashback_wish_city_unknown` + ≤3 候选。
    - `:public_listing_consent` ∈ `boolean`（默认 false）——`visibility=public
      AND consent=true` 时写入 `listed_at`，否则 nil；旧客户端默认值
      false 自然宽容（listed_at=null，仅成员可见，不硬拒）。
  """
  @spec create_wish(String.t(), String.t(), String.t(), keyword()) ::
          {:ok, map()} | {:error, term()}
  def create_wish(person_id, content, visibility, opts \\ []) do
    signature_choice = Keyword.get(opts, :signature_choice, :anonymous)
    expected_city = Keyword.get(opts, :expected_city, nil)
    public_listing_consent = Keyword.get(opts, :public_listing_consent, false)

    with :ok <- validate_content(content),
         :ok <- validate_visibility(visibility),
         :ok <- check_content(person_id, content),
         {:ok, %{city: city, signature: signature, review_required: review_required}} <-
           build_writer_snapshots(person_id, expected_city, signature_choice) do
      # wish2 U8（KTD5 信用门补全，plan :180）：wishes_review_required_at 置位的
      # 作者，公开愿望不直接挂树——hidden_at 待审、admin 放行（clear hidden）才
      # 进公开树；listed/hidden 互斥，三态反馈由 status 承载。
      consents_listing = visibility == "public" and public_listing_consent
      now = DateTime.utc_now() |> DateTime.truncate(:microsecond)

      {listed_at, hidden_at} =
        cond do
          consents_listing and review_required -> {nil, now}
          consents_listing -> {now, nil}
          true -> {nil, nil}
        end

      # 锁 + COUNT + INSERT 同事务：Repo.rollback 透传 {:error, %{code: ...}}
      # 形状（Ecto 语义：error tuple 回滚不 raise），返回契约不变。
      Repo.transaction(fn ->
        with {:ok, _city} <- lock_person_city(person_id),
             :ok <- check_quota(person_id) do
          # signature/listed_at/hidden_at 由 domain 赋值 + accept（「仅 server 写」
          # 由 GraphQL 不入参保证——U6 公开 schema 不暴露这三字段）。
          Wish
          |> Ash.Changeset.for_create(:create, %{
            person_id: person_id,
            content: String.trim(content),
            visibility: visibility,
            city: city,
            signature: signature,
            listed_at: listed_at,
            hidden_at: hidden_at
          })
          |> Ash.create(authorize?: false)
          |> case do
            {:ok, wish} -> wish
            {:error, reason} -> Repo.rollback(reason)
          end
        else
          {:error, reason} -> Repo.rollback(reason)
        end
      end)
      |> case do
        {:ok, wish} -> {:ok, Map.put(wish, :listing_status, listing_status(visibility, wish))}
        other -> other
      end
    end
  end

  # 三态反馈（R18）：listed（挂树）/ pending_review（信用待审——admin 放行后挂树）/
  # private（说给主办方听）；public 无 consent 的旧客户端形状归 private 档反馈
  # （未挂树语义一致，旧客户端不读该字段）。
  defp listing_status(visibility, wish) do
    cond do
      visibility == "private" -> "private"
      not is_nil(wish.listed_at) -> "listed"
      not is_nil(wish.hidden_at) -> "pending_review"
      true -> "private"
    end
  end

  # U1 KTD1 / KTD11：name-place 与 city 快照。名册城市与 display_name 一次 SQL
  # 取回，KTD11 归一逻辑（Cities.normalize）做墙体。
  @doc false
  def build_writer_snapshots(person_id, expected_city, signature_choice) do
    # KTD4 ① → ② 一次 SQL 取复：person 行 + LEFT JOIN users 取 display_name。
    # 未认领 person（user_id 为空）→ display_name 为 NULL，回退 masked_name。
    case Repo.query(
           """
           SELECT p.city, p.full_name, p.surname, u.display_name, u.wishes_review_required_at
           FROM flashback_people p
           LEFT JOIN users u ON u.id = p.user_id
           WHERE p.id = $1
           """,
           [Repo.uuid!(person_id)]
         ) do
      {:ok, %{num_rows: 0}} ->
        {:error, %{code: "flashback_person_not_found"}}

      {:error, _} ->
        {:error, %{code: "flashback_person_not_found"}}

      {:ok, %{rows: [[person_city, full_name, surname, display_name, review_required_at]]}} ->
        case normalize_writing_city(expected_city, person_city) do
          {:error, err} ->
            {:error, err}

          {:ok, city} ->
            signature =
              case signature_choice do
                :display_name ->
                  cond do
                    is_binary(display_name) and display_name != "" ->
                      display_name

                    is_binary(full_name) and full_name != "" ->
                      full_name

                    true ->
                      AlumniProjection.masked_name(full_name, surname)
                  end

                _anonymous ->
                  AlumniProjection.masked_name(full_name, surname)
              end

            {:ok,
             %{
               city: city,
               signature: signature || "",
               review_required: not is_nil(review_required_at)
             }}
        end
    end
  end

  defp normalize_writing_city(nil, person_city) do
    case Cities.normalize(person_city || "") do
      {:ok, normalized} -> {:ok, normalized}
      {:error, _} -> {:ok, nil}
    end
  end

  defp normalize_writing_city(provided, _person_city) do
    Cities.normalize(provided)
  end

  # ── 附议（R7 / KTD3 U3，幂等） ───────────────────────────────────────

  @doc """
  附议（幂等，重复无副作用）。**KTD3 U3**：唯一入口 `endorse_by_user/3`
  （旧 token/person 匿名腿已 cutover 下线——simplify 清理）。opts:
    - `:contribution_types :list(String.t())`（venue/organize/speak/sponsor/other）
    - `:message :String.t() | nil`（≤500 字；非空经机审；仅运营可见）
    - `:notify :boolean`（默认 false——Echo 意愿仅持久化，**不**调 Consent.grant）
  - 归并：同 user 认领的 person 在同 wish 已有 `p:` 行 → p: 升级 u:（填 user_id
    与表单字段），不新增不双计。否则新插 `u:` 行。
  - 返回 `%{endorsement_count, endorsed_by_me}` 实时状态。
  """
  @spec endorse_by_user(String.t(), String.t(), keyword()) ::
          {:ok, %{endorsement_count: non_neg_integer(), endorsed_by_me: boolean()}}
          | {:error, term()}
  def endorse_by_user(user_id, wish_id, opts \\ []) do
    contribution_types = Keyword.get(opts, :contribution_types, [])
    message = Keyword.get(opts, :message, nil)
    notify? = Keyword.get(opts, :notify, false)

    user_uuid = Repo.uuid!(user_id)
    person_id = find_user_person_id(user_uuid)

    with {:ok, wish} <- fetch_public_wish(wish_id),
         # FIX-2（KTD9 资格矩阵）：listed → 任何登录用户；未 listed → 需可解析
         # person（成员语义）；viewer（无 person）对未 listed 统一 not_found
         # （不泄露存在性）。hidden/deleted 已被 fetch_public_wish 滤除。
         :ok <- authorize_endorse_target(wish, person_id),
         :ok <- validate_contribution_types(contribution_types),
         :ok <- validate_endorsement_message(message),
         :ok <- check_content_by_user(user_id, message) do
      cond do
        # p:→u: 归并：user 认领的 person 已有存量 p: 行 → 升级不新增
        existing_p = find_claimed_p_endorsement(user_uuid, wish.id) ->
          existing_p
          |> Ash.Changeset.for_update(:update, %{
            user_id: user_uuid,
            contribution_types: contribution_types,
            message: message,
            notify: notify?
          })
          |> Ash.update(authorize?: false)
          |> case do
            {:ok, _} -> {:ok, count_with_mine_by_user(wish.id, user_uuid)}
            {:error, reason} -> {:error, reason}
          end

        # u: 行幂等（含 viewer person_id=nil 行）：重复附议 UPDATE 不双计
        existing_u = find_endorsement_by_user(wish.id, user_uuid) ->
          existing_u
          |> Ash.Changeset.for_update(:update, %{
            contribution_types: contribution_types,
            message: message,
            notify: notify?
          })
          |> Ash.update(authorize?: false)
          |> case do
            {:ok, _} -> {:ok, count_with_mine_by_user(wish.id, user_uuid)}
            {:error, reason} -> {:error, reason}
          end

        # 新附议：member（有 person）或 viewer（listed 目标，person_id=nil）
        true ->
          do_insert_endorsement(
            wish.id,
            person_id,
            user_uuid,
            contribution_types,
            message,
            notify?
          )
      end
    end
  end

  # FIX-2（KTD9）：listed 目标任何登录用户可附议；未 listed 目标仅「可解析
  # person」的成员（成员语义）。viewer 对未 listed 统一 not_found——目标存在
  # 本身不可泄露（requires_claim 会泄露「可附议但需认领」信号，弃用）。
  defp authorize_endorse_target(%Wish{listed_at: listed_at}, _user_id)
       when not is_nil(listed_at),
       do: :ok

  defp authorize_endorse_target(%Wish{listed_at: nil}, person_id) do
    if is_nil(person_id) do
      {:error, %{code: "flashback_wish_not_found"}}
    else
      :ok
    end
  end

  defp find_endorsement_by_user(wish_id, user_uuid) do
    WishEndorsement
    |> Ash.Query.filter(wish_id == ^wish_id and user_id == ^user_uuid)
    |> Ash.read_one(authorize?: false)
    |> case do
      {:ok, nil} -> nil
      {:ok, row} -> row
      _ -> nil
    end
  end

  defp do_insert_endorsement(wish_id, person_id, user_uuid, contribution_types, message, notify?) do
    WishEndorsement
    |> Ash.Changeset.for_create(:create, %{
      wish_id: wish_id,
      person_id: person_id,
      user_id: user_uuid,
      contribution_types: contribution_types,
      message: message,
      notify: notify?
    })
    |> Ash.create(authorize?: false)
    |> case do
      {:ok, _} -> {:ok, count_with_mine_by_user(wish_id, user_uuid)}
      {:error, reason} -> {:error, reason}
    end
  end

  @spec cancel_endorse_by_user(String.t(), String.t()) ::
          {:ok, %{endorsement_count: non_neg_integer(), endorsed_by_me: boolean()}}
          | {:error, term()}
  def cancel_endorse_by_user(user_id, wish_id) do
    with {:ok, wish} <- fetch_public_wish(wish_id) do
      user_uuid = Repo.uuid!(user_id)

      WishEndorsement
      |> Ash.Query.filter(wish_id == ^wish.id and user_id == ^user_uuid)
      |> Ash.read_one(authorize?: false)
      |> case do
        {:ok, nil} ->
          {:ok, count_with_mine_by_user(wish.id, user_uuid)}

        {:ok, row} ->
          case Ash.destroy(row, authorize?: false) do
            :ok -> {:ok, count_with_mine_by_user(wish.id, user_uuid)}
            {:error, reason} -> {:error, reason}
          end

        {:error, reason} ->
          {:error, reason}
      end
    end
  end

  # ── U3 内部：contribution_types / message / openid 机审 ──────────────

  @valid_contribution_types ~w(venue organize speak sponsor other)

  defp validate_contribution_types(list) when is_list(list) do
    if Enum.all?(list, &(&1 in @valid_contribution_types)) do
      :ok
    else
      {:error,
       %{
         code: "flashback_wish_endorsement_invalid_contribution_types",
         message: "出力类型不合法，可选：venue / organize / speak / sponsor / other。"
       }}
    end
  end

  defp validate_contribution_types(_) do
    {:error,
     %{
       code: "flashback_wish_endorsement_invalid_contribution_types",
       message: "出力类型不合法，可选：venue / organize / speak / sponsor / other。"
     }}
  end

  defp validate_endorsement_message(nil), do: :ok

  defp validate_endorsement_message(msg) when is_binary(msg) do
    trimmed = String.trim(msg)

    cond do
      trimmed == "" ->
        :ok

      String.length(trimmed) > 500 ->
        {:error,
         %{
           code: "flashback_wish_endorsement_message_too_long",
           message: "附议留言 ≤500 字。"
         }}

      true ->
        :ok
    end
  end

  # KTD3 归并：找 user 已认领 person 在同 wish 下的 p: 行（user_id IS NULL）
  defp find_claimed_p_endorsement(user_uuid, wish_id) do
    query = """
    SELECT e.id
    FROM flashback_wish_endorsements e
    JOIN flashback_people p ON p.id = e.person_id
    WHERE e.wish_id = $1
      AND p.user_id = $2
      AND e.user_id IS NULL
    LIMIT 1
    """

    case Repo.query(query, [Repo.uuid!(wish_id), user_uuid]) do
      {:ok, %{rows: [[id]]}} ->
        WishEndorsement
        |> Ash.Query.filter(id == ^id)
        |> Ash.read_one!(authorize?: false)

      _ ->
        nil
    end
  end

  defp find_user_person_id(user_uuid) do
    case Repo.query(
           "SELECT id FROM flashback_people WHERE user_id = $1 LIMIT 1",
           [user_uuid]
         ) do
      {:ok, %{rows: [[id]]}} -> id
      _ -> nil
    end
  end

  @doc false
  def count_with_mine_by_user(wish_id, user_uuid) do
    count =
      WishEndorsement
      |> Ash.Query.filter(wish_id == ^wish_id)
      |> Ash.count!(authorize?: false)

    mine? =
      WishEndorsement
      |> Ash.Query.filter(wish_id == ^wish_id and user_id == ^user_uuid)
      |> Ash.exists?(authorize?: false)

    %{endorsement_count: count, endorsed_by_me: mine?}
  end

  # U3 KTD4 登录路径 message 机审：user_identities → wechat uid ①②；③ 长尾
  # （tt/xhs 单平台/web-only/查询异常）→ skipped telemetry + fail-open（与
  # wishes.check_content ③ 收口同语义）。**但注意**：传入 nil/"" message 直接放行
  # （无需检测）。
  defp check_content_by_user(_user_id, nil), do: :ok
  defp check_content_by_user(_user_id, ""), do: :ok

  defp check_content_by_user(user_id, message) when is_binary(message) do
    trimmed = String.trim(message)

    if trimmed == "" do
      :ok
    else
      case fetch_wechat_openid_by_user(Repo.uuid!(user_id)) do
        {:ok, openid} -> run_wechat_check(trimmed, openid)
        :no_wechat_identity -> :ok
      end
    end
  end

  defp fetch_wechat_openid_by_user(user_uuid) do
    case Repo.query(
           "SELECT provider, uid FROM user_identities WHERE user_id = $1",
           [user_uuid]
         ) do
      {:ok, %{rows: rows}} ->
        identities =
          rows
          |> Enum.map(fn [provider, uid] -> {@content_check_platforms[provider], uid} end)
          |> Enum.reject(fn {provider, _uid} -> is_nil(provider) end)
          |> Map.new()

        case Map.get(identities, :wechat) do
          nil ->
            emit_openid_unresolved(:no_wechat_identity)
            :no_wechat_identity

          openid ->
            {:ok, openid}
        end

      {:error, _} ->
        emit_openid_unresolved(:identity_query_error)
        :no_wechat_identity
    end
  end

  # ── 留言（R8） ───────────────────────────────────────────────────────

  @doc """
  留言（公开愿望）；返回该愿望的全部未删留言。
  KTD4：content 过微信 msgSecCheck v2 同 create_wish；违规/待审 fail-closed
  返回 `flashback_content_rejected`。
  """
  @spec add_comment(String.t(), String.t(), String.t()) ::
          {:ok, list(map())} | {:error, term()}
  def add_comment(person_id, wish_id, content) do
    with :ok <- validate_content(content),
         {:ok, wish} <- fetch_public_wish(wish_id),
         :ok <- check_content(person_id, content) do
      WishComment
      |> Ash.Changeset.for_create(:create, %{
        wish_id: wish.id,
        person_id: person_id,
        content: String.trim(content)
      })
      |> Ash.create(authorize?: false)
      |> case do
        {:ok, _} -> {:ok, list_comments(wish.id)}
        {:error, reason} -> {:error, reason}
      end
    end
  end

  @doc "愿望的未删留言（时间正序，带留言人遮罩姓）。"
  @spec list_comments(String.t()) :: list(map())
  def list_comments(wish_id) do
    WishComment
    |> Ash.Query.filter(wish_id == ^wish_id and is_nil(deleted_at))
    |> Ash.Query.sort(inserted_at: :asc)
    |> Ash.read!(authorize?: false, page: false, load: [:person])
    |> project_comments()
  end

  # 留言投影（list_comments 与 list_public 批量加载共用）
  defp project_comments(comments) do
    Enum.map(comments, fn comment ->
      %{
        id: comment.id,
        content: comment.content,
        inserted_at: comment.inserted_at,
        commenter_masked: AlumniProjection.masked_name(comment.person)
      }
    end)
  end

  # ── 软删单源（KTD4：学员自助与 MCP 共用） ────────────────────────────

  @doc "软删许愿（R14：仅许愿人；R18：平台管理员经 MCP 走同一函数）。"
  @spec soft_delete_wish(String.t(), String.t(), keyword()) :: {:ok, map()} | {:error, term()}
  def soft_delete_wish(wish_id, actor_person_id, opts \\ []) do
    admin? = Keyword.get(opts, :admin?, false)

    Wish
    |> Ash.Query.filter(id == ^wish_id)
    |> Ash.read_one(authorize?: false)
    |> case do
      {:ok, nil} -> {:error, %{code: "flashback_wish_not_found"}}
      {:ok, %Wish{} = wish} -> do_soft_delete_wish(wish, actor_person_id, admin?)
      {:error, reason} -> {:error, reason}
    end
  end

  @doc "软删留言（仅留言人；MCP 同一函数）。"
  @spec soft_delete_comment(String.t(), String.t(), keyword()) :: {:ok, map()} | {:error, term()}
  def soft_delete_comment(comment_id, actor_person_id, opts \\ []) do
    admin? = Keyword.get(opts, :admin?, false)

    WishComment
    |> Ash.Query.filter(id == ^comment_id)
    |> Ash.read_one(authorize?: false)
    |> case do
      {:ok, nil} -> {:error, %{code: "flashback_wish_comment_not_found"}}
      {:ok, %WishComment{} = comment} -> do_soft_delete_comment(comment, actor_person_id, admin?)
      {:error, reason} -> {:error, reason}
    end
  end

  # ── 读面（投影用） ───────────────────────────────────────────────────

  @doc """
  公开树愿望（U1 KTD1/KTD10）：仅 listed+public+未隐藏+未删除。
  这是 viewer 公开树的查询函数，与成员面 `list_public/2` 分离（G12 pin）。
  本批仅做「四条件过滤」；KTD10 direct 排序/分页在 U6 落。
  """
  @spec list_public_listed(String.t() | nil, String.t() | nil) :: list(map())
  def list_public_listed(city \\ nil, viewer_id \\ nil) do
    base =
      Wish
      |> Ash.Query.filter(
        visibility == "public" and
          is_nil(deleted_at) and
          is_nil(hidden_at) and
          not is_nil(listed_at)
      )
      |> Ash.Query.load([:endorsements, :person, comments: [:person]])

    base =
      if city do
        Ash.Query.filter(base, is_nil(city) or city == ^city)
      else
        base
      end

    wishes = Ash.read!(base, authorize?: false, page: false)

    wishes
    |> Enum.map(fn wish ->
      %{
        id: wish.id,
        content: wish.content,
        city: wish.city,
        signature: wish.signature,
        listed_at: wish.listed_at,
        inserted_at: wish.inserted_at,
        wisher_masked: AlumniProjection.masked_name(wish.person),
        endorsement_count: length(wish.endorsements),
        comments: project_comments(wish.comments),
        mine: viewer_id != nil and wish.person_id == viewer_id
      }
    end)
    |> Enum.sort_by(&{-&1.endorsement_count, &1.inserted_at})
  end

  @doc """
  公开愿望（成员面，附议数降序、时间稳定序）；city 过滤 nil = 不过滤；
  viewer_id 供 `mine` 标记（本人愿望显示删除入口，R14）。

  对 `listed_at/hidden_at` 无过滤——成员面语义是所有 public 未删愿望对登录
  成员可见（包括未授权 listed 的存量愿望）。公开树请用 `list_public_listed/2`。
  """
  @spec list_public(String.t() | nil, String.t() | nil) :: list(map())
  def list_public(city \\ nil, viewer_id \\ nil) do
    base =
      Wish
      |> Ash.Query.filter(visibility == "public" and is_nil(deleted_at))
      # 批量带出留言（N+1 修复）：一次查询投影全部愿望+附议+留言+许愿人
      |> Ash.Query.load([:endorsements, :person, comments: [:person]])

    base =
      if city do
        Ash.Query.filter(base, is_nil(city) or city == ^city)
      else
        base
      end

    wishes = Ash.read!(base, authorize?: false, page: false)

    wishes
    |> Enum.map(fn wish ->
      %{
        id: wish.id,
        content: wish.content,
        city: wish.city,
        inserted_at: wish.inserted_at,
        wisher_masked: AlumniProjection.masked_name(wish.person),
        endorsement_count: length(wish.endorsements),
        comments: project_comments(wish.comments),
        mine: viewer_id != nil and wish.person_id == viewer_id
      }
    end)
    |> Enum.sort_by(&{-&1.endorsement_count, &1.inserted_at})
  end

  @doc "本人私有许愿（私人许愿帧，R9 仅自己可见）。"
  @spec list_private(String.t()) :: list(map())
  def list_private(person_id) do
    Wish
    |> Ash.Query.filter(
      person_id == ^person_id and visibility == "private" and is_nil(deleted_at)
    )
    |> Ash.Query.sort(inserted_at: :desc)
    |> Ash.read!(authorize?: false, page: false)
    |> Enum.map(fn wish ->
      # 形状与公开愿望同构——GraphQL flashback_wish 的 comments/endorsement_count/
      # endorsed_by_me 为 non_null，私有投影给空/零默认（私有愿望不可附议留言，R9）
      %{
        id: wish.id,
        content: wish.content,
        city: wish.city,
        inserted_at: wish.inserted_at,
        wisher_masked: nil,
        endorsement_count: 0,
        endorsed_by_me: false,
        comments: []
      }
    end)
  end

  @doc "本人已附议的愿望 id 集（endorsedByMe 读面）。"
  @spec endorsed_wish_ids(String.t()) :: MapSet.t()
  def endorsed_wish_ids(person_id) do
    WishEndorsement
    |> Ash.Query.filter(person_id == ^person_id)
    |> Ash.read!(authorize?: false, page: false)
    |> MapSet.new(& &1.wish_id)
  end

  @doc "本人今年剩余许愿额度（R20：每年 #{@annual_wish_quota} 条，含私有与已软删）。"
  @spec quota_remaining(String.t()) :: non_neg_integer()
  def quota_remaining(person_id) do
    max(0, @annual_wish_quota - wishes_created_this_year(person_id))
  end

  # ── 内部 ─────────────────────────────────────────────────────────────

  # KTD4 机审正经入口：内容失败 fail-closed 返回业务错误码，infra 故障 fail-open
  # 放行（Wechat.Client.content_check 内部已记 skipped telemetry），无 openid 记
  # openid_unresolved telemetry（KTD4 ③三段收口，本批不声称覆盖 token-only 长尾）。
  #
  # 与 admission/enrollment.ex:777-833 的 check_content/check_content_with_identity
  # 同语义，差别仅错误码（enrollment_content_rejected → flashback_content_rejected）。
  defp check_content(person_id, content) do
    trimmed = String.trim(content)

    if trimmed == "" do
      :ok
    else
      case resolve_openid_path(person_id) do
        {:ok, openid} -> run_wechat_check(trimmed, openid)
        :no_wechat_identity -> :ok
        :no_user -> :ok
        :no_person -> :ok
      end
    end
  end

  defp run_wechat_check(content, openid) do
    case WechatClient.content_check(:wechat, content, openid) do
      {:ok, _} ->
        :ok

      {:error, :content_rejected} ->
        {:error,
         %{
           code: "flashback_content_rejected",
           message: "内容未通过安全检测，请调整后重试。"
         }}
    end
  end

  # openid 三段解析（KTD4）：
  #   ① 登录 actor（小链路 token=nil + context.actor）→ 该 actor 的 wechat uid。
  #      实际链路：`person_id → person.user_id → user_identities(wechat uid)`。
  #      本函数把 ①② 合并成同一访问路径——Flashback write 面只见到 person_id，
  #      person.user_id 非空即「已认领」（无论是登录 actor 还是 token 链路），
  #      不存在「person_id 但没 user 也能识别为登录」的状态。
  #   ② token/成员腿 → person.user_id 非空时经其 user_identities 取（已认领全
  #      覆盖）。同 ① 一次 SQL 落地。
  #   ③ 拿不到 → :no_user（person.user_id 为空，未认领 token-only 长尾）
  #      / :no_wechat_identity（有 user 但无 wechat 身份，如 tt/xhs 单平台
  #      或 web 注册）——两态均记录 telemetry 并放行，先发后审兜底（KTD5）。
  # @doc false
  defp resolve_openid_path(person_id) do
    case Repo.query(
           "SELECT user_id FROM flashback_people WHERE id = $1",
           [Repo.uuid!(person_id)]
         ) do
      {:ok, %{rows: [[nil]]}} ->
        emit_openid_unresolved(:no_user)
        :no_user

      {:ok, %{rows: [[user_id]]}} ->
        fetch_wechat_openid(user_id)

      {:ok, %{num_rows: 0}} ->
        # lock_person_city 兜底：person 不存在时本条不会到达（quota 检查会失败），
        # add_comment 链路下 person 删除竞态时按 no_person 收口——fail-open 但记。
        emit_openid_unresolved(:no_person)
        :no_person

      {:error, _} ->
        # 同 enrollment.ex actor_identities :error 分支：查询失败时不制造新故障点，
        # 记 telemetry 后放行（不发外呼也放行——避免 DB 抖动把 UGC 写面打挂）。
        emit_openid_unresolved(:query_error)
        :no_person
    end
  end

  # @doc false
  defp fetch_wechat_openid(user_id) do
    case Repo.query(
           "SELECT provider, uid FROM user_identities WHERE user_id = $1",
           [user_id]
         ) do
      {:ok, %{rows: rows}} ->
        identities =
          rows
          |> Enum.map(fn [provider, uid] -> {@content_check_platforms[provider], uid} end)
          |> Enum.reject(fn {provider, _uid} -> is_nil(provider) end)
          |> Map.new()

        case Map.get(identities, :wechat) do
          nil ->
            emit_openid_unresolved(:no_wechat_identity)
            :no_wechat_identity

          openid ->
            {:ok, openid}
        end

      {:error, _} ->
        emit_openid_unresolved(:identity_query_error)
        :no_wechat_identity
    end
  end

  # KTD4 ③ 长尾 telemetry：只在 openid 拿不到时计数，metadata 仅类别原子
  # （红线：内容明文/person_id/user_id 不进 telemetry/log）。单独的 event
  # 与 client.ex 的 [:cgc_2046, :content_check, :skipped]（infra 故障）区分，
  # 让 dashboard 能拆出「语义性 skip」与「故障性 skip」两类。
  defp emit_openid_unresolved(reason) do
    :telemetry.execute(@openid_unresolved_event, %{count: 1}, %{reason: reason})
  end

  defp validate_content(content) when is_binary(content) do
    trimmed = String.trim(content)

    cond do
      trimmed == "" ->
        {:error, %{code: "flashback_wish_invalid_content"}}

      String.length(trimmed) > @content_max_length ->
        {:error, %{code: "flashback_wish_invalid_content"}}

      true ->
        :ok
    end
  end

  defp validate_content(_), do: {:error, %{code: "flashback_wish_invalid_content"}}

  defp validate_visibility(visibility) when visibility in @visibilities, do: :ok
  defp validate_visibility(_), do: {:error, %{code: "flashback_wish_invalid_visibility"}}

  # R20：年度额度按创建行为计数——不过滤 deleted_at/visibility（软删不退还、
  # 私有也计），防删除重许刷热度信号使额度失效。
  defp check_quota(person_id) do
    if wishes_created_this_year(person_id) >= @annual_wish_quota do
      {:error,
       %{
         code: "flashback_wish_quota_exceeded",
         message: "今年的许愿名额已用完（每年最多 #{@annual_wish_quota} 条）。"
       }}
    else
      :ok
    end
  end

  defp wishes_created_this_year(person_id) do
    Wish
    |> Ash.Query.filter(person_id == ^person_id and inserted_at >= ^shanghai_year_start_utc())
    |> Ash.count!(authorize?: false)
  end

  # Asia/Shanghai 固定 UTC+8 无夏令时；项目无 tzdata 依赖（Calendar 默认
  # UTCOnly，shift_zone 不可用），算术偏移行为在 dev/test/prod 一致。
  defp shanghai_year_start_utc do
    shanghai_now = DateTime.add(DateTime.utc_now(), 8 * 3600, :second)

    DateTime.new!(Date.new!(shanghai_now.year, 1, 1), ~T[00:00:00], "Etc/UTC")
    |> DateTime.add(-8 * 3600, :second)
  end

  # R20 并发串行点（同 card_sharing lock_row 协议）：事务内对 person 行
  # FOR UPDATE——后到者锁内重数会看到先到者已提交的愿望，check_quota 的
  # COUNT 与 Ash.create 的 INSERT 不再分离成两条独立语句。锁读顺带返回
  # city（创建快照入参）；num_rows=0 即 person 不存在。
  defp lock_person_city(person_id) do
    case Repo.query("SELECT city FROM flashback_people WHERE id = $1 FOR UPDATE", [
           Repo.uuid!(person_id)
         ]) do
      {:ok, %{num_rows: 1, rows: [[city]]}} ->
        {:ok, city}

      {:ok, %{num_rows: 0}} ->
        {:error, %{code: "flashback_person_not_found"}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  # FIX-2（审计 U3 缺口 2 / KTD9）：附议/留言目标资格——public + 未 hidden + 未删。
  # hidden 后愿望不可再 endorse/cancel/comment（成员面 list_public 读不受影响）。
  defp fetch_public_wish(wish_id) do
    Wish
    |> Ash.Query.filter(
      id == ^wish_id and visibility == "public" and is_nil(deleted_at) and
        is_nil(hidden_at)
    )
    |> Ash.read_one(authorize?: false)
    |> case do
      {:ok, nil} -> {:error, %{code: "flashback_wish_not_found"}}
      {:ok, wish} -> {:ok, wish}
      error -> error
    end
  end

  # MCP 治理删除走 admin?: true，actor 传 nil（平台侧身份由 ToolCallLog 审计承担）
  defp do_soft_delete_wish(%Wish{person_id: person_id} = wish, actor_person_id, admin?) do
    if admin? or person_id == actor_person_id do
      wish
      |> Ash.Changeset.for_update(:update, %{deleted_at: DateTime.utc_now()})
      |> Ash.update(authorize?: false)
    else
      {:error, %{code: "flashback_forbidden_wish"}}
    end
  end

  defp do_soft_delete_comment(%WishComment{person_id: person_id} = comment, actor, admin?) do
    if admin? or person_id == actor do
      comment
      |> Ash.Changeset.for_update(:update, %{deleted_at: DateTime.utc_now()})
      |> Ash.update(authorize?: false)
    else
      {:error, %{code: "flashback_forbidden_wish"}}
    end
  end
end
