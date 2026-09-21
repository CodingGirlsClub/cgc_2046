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

  alias Cgc2046.Flashback.{AlumniProjection, Wish, WishComment, WishEndorsement}
  alias Cgc2046.Repo

  @content_max_length 500
  @visibilities ~w(public private)
  @annual_wish_quota 3

  # ── 创建（R5/R6） ────────────────────────────────────────────────────

  @doc "许愿：visibility 二选一；city 快照许愿人名册城市；年度额度 R20。"
  @spec create_wish(String.t(), String.t(), String.t()) ::
          {:ok, map()} | {:error, term()}
  def create_wish(person_id, content, visibility) do
    with :ok <- validate_content(content),
         :ok <- validate_visibility(visibility) do
      # 锁 + COUNT + INSERT 同事务：Repo.rollback 透传 {:error, %{code: ...}}
      # 形状（Ecto 语义：error tuple 回滚不 raise），返回契约不变。
      Repo.transaction(fn ->
        with {:ok, city} <- lock_person_city(person_id),
             :ok <- check_quota(person_id) do
          Wish
          |> Ash.Changeset.for_create(:create, %{
            person_id: person_id,
            content: String.trim(content),
            visibility: visibility,
            city: city
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
    end
  end

  # ── 附议（R7，幂等） ─────────────────────────────────────────────────

  @doc "附议 +1（幂等，重复无副作用）；返回实时计数与本人态。"
  @spec endorse(String.t(), String.t()) ::
          {:ok, %{endorsement_count: non_neg_integer(), endorsed_by_me: boolean()}}
          | {:error, term()}
  def endorse(person_id, wish_id) do
    with {:ok, wish} <- fetch_public_wish(wish_id) do
      WishEndorsement
      |> Ash.Changeset.for_create(:create, %{wish_id: wish.id, person_id: person_id})
      |> Ash.create(authorize?: false, upsert?: true, upsert_identity: :unique_wish_person)
      |> case do
        {:ok, _} -> {:ok, count_with_mine(wish.id, person_id)}
        {:error, reason} -> {:error, reason}
      end
    end
  end

  # ── 留言（R8） ───────────────────────────────────────────────────────

  @doc "留言（公开愿望）；返回该愿望的全部未删留言。"
  @spec add_comment(String.t(), String.t(), String.t()) ::
          {:ok, list(map())} | {:error, term()}
  def add_comment(person_id, wish_id, content) do
    with :ok <- validate_content(content),
         {:ok, wish} <- fetch_public_wish(wish_id) do
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

  @doc "公开愿望（附议数降序、时间稳定序）；city 过滤 nil = 不过滤；
  viewer_id 供 `mine` 标记（本人愿望显示删除入口，R14）。"
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

  defp fetch_public_wish(wish_id) do
    Wish
    |> Ash.Query.filter(id == ^wish_id and visibility == "public" and is_nil(deleted_at))
    |> Ash.read_one(authorize?: false)
    |> case do
      {:ok, nil} -> {:error, %{code: "flashback_wish_not_found"}}
      {:ok, wish} -> {:ok, wish}
      error -> error
    end
  end

  defp count_with_mine(wish_id, person_id) do
    count =
      WishEndorsement
      |> Ash.Query.filter(wish_id == ^wish_id)
      |> Ash.count!(authorize?: false)

    mine? =
      WishEndorsement
      |> Ash.Query.filter(wish_id == ^wish_id and person_id == ^person_id)
      |> Ash.exists?(authorize?: false)

    %{endorsement_count: count, endorsed_by_me: mine?}
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
