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

  alias Cgc2046.Flashback.WishEchoes
  alias Cgc2046.Repo

  @default_limit 60
  @max_limit 120
  @max_public_input_length 255
  # freshness 参数硬编码进 SQL fragment（7 天窗 ×1.5）——单源，避免 attribute 与 SQL 漂移

  @doc """
  公开树查询。`opts`:
    - `:city` 城市过滤（nil = 不过滤；与 U1 list_public_listed 同口径 is_nil or ==）
    - `:seed` 排序种子（nil = 当日 + voter_key 组合）
    - `:offset` 分页偏移（同 seed 稳定）
    - `:limit` 页大小（默认 60，上限 120）
    - `:voter_keys` viewer 期待/附议回显键集（HS-3 双键读面：登录 = 强制
      `u:<user_id>` + 入参 `a:` 设备键；未登录 = 入参单键）。空集恒 false。
      旧 `:voter_key` 单键入参仍兼容（包装为单元素集）。
  """
  @spec wishes(keyword()) :: {:ok, list(map())}
  def wishes(opts \\ []) do
    city = Keyword.get(opts, :city)
    voter_keys = opts |> normalize_voter_keys() |> Enum.map(&bound_public_input/1)
    # endorsed_by_viewer 只匹配 u: 键（附议要求登录，actor_key 恒 u: 形态）
    endorser_keys = Enum.filter(voter_keys, &String.starts_with?(&1, "u:"))

    seed =
      case Keyword.get(opts, :seed) do
        nil -> default_seed(List.first(voter_keys))
        value -> bound_public_input(value)
      end

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
                "EXISTS (SELECT 1 FROM flashback_wish_expectations e WHERE e.wish_id = ? AND e.voter_key = ANY(?))",
                w.id,
                ^voter_keys
              ),
            endorsed_by_viewer:
              fragment(
                """
                EXISTS (
                  SELECT 1 FROM flashback_wish_endorsements en
                  WHERE en.wish_id = ? AND en.actor_key = ANY(?)
                )
                """,
                w.id,
                ^endorser_keys
              )
          }
        )
      )

    echoes_by_wish_id =
      rows
      |> Enum.map(&Ecto.UUID.load!(&1.id))
      |> WishEchoes.public_by_wish_ids()

    {:ok, Enum.map(rows, &payload(&1, echoes_by_wish_id))}
  end

  @doc """
  单条直达（?item=<wish_id>）：四条件可见才返回 payload；否则 nil（不泄露存在性）。
  """
  # 第二参双形态：voter_key 单键（string|nil，既有调用方）或 keyword
  # （:voter_keys 双键集——HS-3 登录 u: 强制 + 入参 a: 合并由 resolver 组好）。
  # 单子句不重载：双子句会让默认参 bridge 与 cast 的类型推断打架
  # （warnings-as-errors 下必挂）。
  @spec wish(String.t(), String.t() | keyword() | nil) :: {:ok, map() | nil}
  def wish(wish_id, voter_key_or_opts \\ nil) when is_binary(wish_id) do
    voter_keys =
      case voter_key_or_opts do
        opts when is_list(opts) -> normalize_voter_keys(opts)
        key -> normalize_voter_keys(voter_key: key)
      end
      |> Enum.map(&bound_public_input/1)

    # 与 wishes/1 同构：仅 u: 键可命中附议 actor_key
    endorser_keys = Enum.filter(voter_keys, &String.starts_with?(&1, "u:"))

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
                  "EXISTS (SELECT 1 FROM flashback_wish_expectations e WHERE e.wish_id = ? AND e.voter_key = ANY(?))",
                  w.id,
                  ^voter_keys
                ),
              # simplify（审计 U6-2）：单条直达补 endorsed_by_viewer——与 wishes/1
              # 同构 EXISTS（actor_key = u: 键），payload 不再恒 false
              endorsed_by_viewer:
                fragment(
                  """
                  EXISTS (
                    SELECT 1 FROM flashback_wish_endorsements en
                    WHERE en.wish_id = ? AND en.actor_key = ANY(?)
                  )
                  """,
                  w.id,
                  ^endorser_keys
                )
            }
          )
        )

      echoes_by_wish_id =
        if row do
          [Ecto.UUID.load!(row.id)] |> WishEchoes.public_by_wish_ids()
        else
          %{}
        end

      {:ok, row && payload(row, echoes_by_wish_id)}
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

  # HS-3 双键读面：voter_keys 优先（列表）；兼容旧 voter_key 单键。恒非空
  # （[""] 占位）——postgrex 空数组参数无法推断类型，且 = ANY('{""}') 恒 false
  # 语义等价「无键」。去重保序。
  defp normalize_voter_keys(opts) do
    keys =
      case Keyword.get(opts, :voter_keys) do
        list when is_list(list) -> Enum.reject(list, &(is_nil(&1) or &1 == ""))
        _ -> []
      end

    keys =
      case keys do
        [] ->
          case Keyword.get(opts, :voter_key) do
            k when is_binary(k) and k != "" -> [k]
            _ -> []
          end

        _ ->
          keys
      end

    keys |> Enum.uniq() |> then(&if &1 == [], do: [""], else: &1)
  end

  # #818：限制读面排序/回显键长度，避免超长输入进入 md5 与 ANY 查询参数。
  defp bound_public_input(nil), do: nil

  defp bound_public_input(value) when is_binary(value),
    do: String.slice(value, 0, @max_public_input_length)

  defp bound_public_input(value), do: value

  defp default_seed(voter_key) do
    today = Date.to_string(Date.utc_today())
    "#{today}:#{voter_key || "anon"}"
  end

  defp payload(row, echoes_by_wish_id) do
    id = Ecto.UUID.load!(row.id)

    echo_projection =
      Map.get(echoes_by_wish_id, id, %{latest_echo: nil, echo_count: 0, echoes: []})

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
      latest_echo: echo_projection.latest_echo,
      echo_count: echo_projection.echo_count,
      echoes: echo_projection.echoes,
      # E2E P1：schemaless select 返回 naive datetime（timestamp 无时区）——
      # Absinthe :datetime 标量要求 DateTime struct，裸 NaiveDateTime 序列化
      # 即 500。schemaless 读面统一按 UTC 语义装箱。
      listed_at: to_utc_datetime(row.listed_at),
      inserted_at: to_utc_datetime(row.inserted_at)
    }
  end

  defp to_utc_datetime(%DateTime{} = dt), do: dt
  defp to_utc_datetime(%NaiveDateTime{} = naive), do: DateTime.from_naive!(naive, "Etc/UTC")
  defp to_utc_datetime(nil), do: nil

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
