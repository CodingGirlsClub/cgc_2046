defmodule Cgc2046.Flashback.WishPublic do
  @moduledoc """
  公开许愿树读面（U6 KTD10）：listed+public+未 hidden+未 deleted 四条件过滤，
  带种子的加权随机排序（Efraimidis–Spirakis）。

  - 权重 `w_i = (1 + 期待数 + 2 × 附议数) × freshness`；
    freshness = inserted_at 距今 ≤7 天 ×1.5，否则 ×1
  - `u_i` 由 `md5(wish_id || ':' || seed)` 派生 (0,1] 均匀值（裁剪下界防 ln(0)）
  - 排序键 `k_i = -ln(u_i) / w_i` 升序——权重高者大概率靠前但非单调
  - seed 缺省 = 当日日期 + voter_key：同访客当天翻页稳定（offset 不重不漏）、
    跨天自然轮换；「换一批」传随机 seed 立即重洗
  - `item` 单条直达不参与排序（不泄露存在性：不可见返回 nil）
  - 字段白名单：id/content/city/signature/expectation_count/endorsement_count/
    contribution_distribution/expected_by_viewer/endorsed_by_viewer/listed_at/
    inserted_at——**不含** phone/email/message 等敏感字段（KTD5 红线）
  """

  import Ecto.Query

  alias Cgc2046.Repo

  @default_limit 60
  @max_limit 120
  # freshness 参数硬编码进 SQL fragment（7 天窗 ×1.5）——单源，避免 attribute 与 SQL 漂移

  @doc """
  公开树查询。`opts`:
    - `:city` 城市过滤（nil = 不过滤；与 U1 list_public_listed 同口径 is_nil or ==）
    - `:seed` 排序种子（nil = 当日 + voter_key 组合）
    - `:offset` 分页偏移（同 seed 稳定）
    - `:limit` 页大小（默认 60，上限 120）
    - `:voter_key` viewer 期待/附议回显（u: 或 a:；nil = 恒 false）
  """
  @spec wishes(keyword()) :: {:ok, list(map())}
  def wishes(opts \\ []) do
    city = Keyword.get(opts, :city)
    voter_key = Keyword.get(opts, :voter_key)
    voter_key = voter_key || ""
    # 形态与 endorsement actor_key 同构；a:/nil 不匹配附议（附议要求登录）
    endorser_key = if is_binary(voter_key) and String.starts_with?(voter_key, "u:"), do: voter_key, else: ""
    seed = Keyword.get(opts, :seed) || default_seed(voter_key)
    offset = max(Keyword.get(opts, :offset, 0), 0)
    limit = opts |> Keyword.get(:limit, @default_limit) |> max(1) |> min(@max_limit)


    base_where =
      dynamic(
        [w],
        w.visibility == "public" and
          not is_nil(w.listed_at) and
          is_nil(w.hidden_at) and
          is_nil(w.deleted_at)
      )

    where_dyn =
      if city do
        dynamic([w], ^base_where and (is_nil(w.city) or w.city == ^city))
      else
        base_where
      end

    rows =
      Repo.all(
        from(w in "flashback_wishes",
          where: ^where_dyn,
          order_by:
            fragment(
              """
              -ln(
                greatest(
                  (('x' || substr(md5(?::text || ':' || ?), 1, 8))::bit(32)::bigint
                   + 0.5) / 4294967296.0,
                  1e-9
                )
              ) /
              (
                (1
                  + (SELECT COUNT(*) FROM flashback_wish_expectations e WHERE e.wish_id = ?)
                  + 2 * (SELECT COUNT(*) FROM flashback_wish_endorsements en WHERE en.wish_id = ?)
                )
                *
                CASE WHEN ? > now() - interval '7 days' THEN 1.5 ELSE 1 END
              )
              """,
              w.id,
              ^seed,
              w.id,
              w.id,
              w.inserted_at
            ),
          limit: ^limit,
          offset: ^offset,
          select: %{
            id: w.id,
            content: w.content,
            city: w.city,
            signature: w.signature,
            listed_at: w.listed_at,
            inserted_at: w.inserted_at,
            expectation_count:
              fragment(
                "(SELECT COUNT(*) FROM flashback_wish_expectations e WHERE e.wish_id = ?)",
                w.id
              ),
            endorsement_count:
              fragment(
                "(SELECT COUNT(*) FROM flashback_wish_endorsements en WHERE en.wish_id = ?)",
                w.id
              ),
            expected_by_viewer:
              fragment(
                "EXISTS (SELECT 1 FROM flashback_wish_expectations e WHERE e.wish_id = ? AND e.voter_key = ?)",
                w.id,
                ^voter_key
              ),
            endorsed_by_viewer:
              fragment(
                """
                EXISTS (
                  SELECT 1 FROM flashback_wish_endorsements en
                  WHERE en.wish_id = ? AND en.actor_key = ?
                )
                """,
                w.id,
                ^endorser_key
              )
          }
        )
      )

    {:ok, Enum.map(rows, &payload/1)}
  end


  @doc """
  单条直达（?item=<wish_id>）：四条件可见才返回 payload；否则 nil（不泄露存在性）。
  """
  @spec wish(String.t(), String.t() | nil) :: {:ok, map() | nil}
  def wish(wish_id, voter_key \\ nil) when is_binary(wish_id) do
    voter_key = voter_key || ""

    with {:ok, _uuid} <- Ecto.UUID.cast(wish_id) do
      row =
        Repo.one(
          from(w in "flashback_wishes",
            where:
              w.id == ^Repo.uuid!(wish_id) and
                w.visibility == "public" and
                not is_nil(w.listed_at) and
                is_nil(w.hidden_at) and
                is_nil(w.deleted_at),
            limit: 1,
            select: %{
              id: w.id,
              content: w.content,
              city: w.city,
              signature: w.signature,
              listed_at: w.listed_at,
              inserted_at: w.inserted_at,
              expectation_count:
                fragment(
                  "(SELECT COUNT(*) FROM flashback_wish_expectations e WHERE e.wish_id = ?)",
                  w.id
                ),
              endorsement_count:
                fragment(
                  "(SELECT COUNT(*) FROM flashback_wish_endorsements en WHERE en.wish_id = ?)",
                  w.id
                ),
              expected_by_viewer:
                fragment(
                  "EXISTS (SELECT 1 FROM flashback_wish_expectations e WHERE e.wish_id = ? AND e.voter_key = ?)",
                  w.id,
                  ^voter_key
                )
            }
          )
        )

      {:ok, row && payload(row)}
    else
      _ -> {:ok, nil}
    end
  end

  @doc "城市静态名单（U6 flashbackCities）：name + full_name + pinyin + lngLat"
  @spec cities() :: list(map())
  def cities do
    Cgc2046.Flashback.Cities.list()
    |> Enum.map(fn c ->
      %{
        name: c.short_name,
        full_name: c.full_name,
        pinyin: c.pinyin,
        lng_lat: c.lng_lat
      }
    end)
  end

  # ── 内部 ─────────────────────────────────────────────────────────────

  defp default_seed(voter_key) do
    today = Date.to_string(Date.utc_today())
    "#{today}:#{voter_key || "anon"}"
  end

  defp payload(row) do
    id = Ecto.UUID.load!(row.id)

    %{
      id: id,
      content: row.content,
      city: row.city,
      signature: row.signature,
      expectation_count: row.expectation_count,
      endorsement_count: row.endorsement_count,
      contribution_distribution: contribution_distribution(id),
      expected_by_viewer: row.expected_by_viewer || false,
      endorsed_by_viewer: row[:endorsed_by_viewer] || false,
      listed_at: row.listed_at,
      inserted_at: row.inserted_at
    }
  end

  defp contribution_distribution(wish_id) when is_binary(wish_id) and byte_size(wish_id) == 16 do
    rows =
      Repo.query!(
        """
        SELECT ct, COUNT(*) FROM (
          SELECT unnest(contribution_types) AS ct
          FROM flashback_wish_endorsements
          WHERE wish_id = $1
        ) t GROUP BY ct ORDER BY ct
        """,
        [wish_id]
      )

    Map.new(rows.rows || [], fn [type, count] -> {type, count} end)
  end

  defp contribution_distribution(wish_id) do
    contribution_distribution(Repo.uuid!(wish_id))
  end
end
