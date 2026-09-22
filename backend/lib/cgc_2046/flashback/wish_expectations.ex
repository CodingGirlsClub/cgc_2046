defmodule Cgc2046.Flashback.WishExpectations do
  @moduledoc """
  期待写面（KTD2 U2）公开 mutation `flashbackExpectWish` /
  `flashbackUnexpectWish` 的服务端逻辑。

  - **去重键**：客户端生成 `voter_key` = `u:<user_id>`（登录用户按账号去重）/
    `a:<device_uuid>`（路人按设备去重）。服务端只校验格式与长度上限——
    真实去重靠 `(wish_id, voter_key)` 唯一索引。
  - **幂等**：expected=true 重复调用不报错也不重复计数（Ash upsert 承接并发
    双击）；expected=false 删行，无行也是成功。
  - **限频**：双层（复用 likes.ex：10-12, 122-146 口径）——IP 窗口
    （60 次/小时，容纳「来回取消/重期待」与 NAT 后多人）+ voter_key 窗口
    （30 次/分钟，R29 防刷单设备高频硬拦）。两个并存。
  - **登录 expect 合并匿名**（KTD2）：登录 actor 调 `set_expectation/3` 带已
    认领 `u:` 键 + 可选 `anonVoterKey`；服务端先删该 `a:` 行再 upsert `u:` 行，
    防同人跨设备双计。
  - **目标校验（KTD9）**：目标 wish 必须当前可见（listed+public+未 hidden+未删
    给公开面；或 public+未删给登录成员·未 listed 也能期待）；否则统一
    `flashback_wish_not_found`（不泄露存在性）。
  - **双指标分离**：`expectation_count = COUNT(expectations)`，
    `endorsement_count = COUNT(endorsements)`——两侧互不维护。
  """

  require Ash.Query

  alias Cgc2046.Repo
  alias Cgc2046.Flashback.{Wish, WishExpectation}

  @voter_prefixes ~w(u a)
  @voter_key_max_length 64

  # likes.ex:10-12,122-146 同款双窗
  @ip_window_seconds 3600
  @ip_max_attempts 60
  @voter_window_seconds 60
  @voter_max_attempts 30

  @doc """
  期待 / 取消期待。opts:
    - `:actor_user_id` 登录 users.id（服务端据此强制 voter_key 为 `u:<uid>`）
    - `:anon_voter_key` 入参 `a:<dev>`（shift；登录后可附）
    - `:remote_ip` 客户端 IP（限频 IP 窗口）

  返回 `%{expectation_count: n, expected_by_me: bool}`。
  """
  @spec set_expectation(String.t(), boolean(), keyword()) ::
          {:ok, %{expectation_count: non_neg_integer(), expected_by_me: boolean()}}
          | {:error, term()}
  def set_expectation(wish_id, expected?, opts \\ []) do
    actor_user_id = Keyword.get(opts, :actor_user_id, nil)
    anon_voter_key = Keyword.get(opts, :anon_voter_key, nil)
    remote_ip = Keyword.get(opts, :remote_ip, nil)

    voter_key = resolve_voter_key(actor_user_id, anon_voter_key)

    with :ok <- validate_voter_key(voter_key),
         :ok <- check_rate_limit(remote_ip, voter_key),
         {:ok, wish} <- fetch_visible_wish(wish_id, actor_user_id) do
      case expected? do
        true -> do_expect(wish, voter_key, anon_voter_key)
        false -> do_unexpect(wish.id, voter_key)
      end
    end
  end

  @doc "某愿望的期待数（公开读面实时 COUNT 同源；测试断言用）。"
  @spec count_for_wish(String.t()) :: non_neg_integer()
  def count_for_wish(wish_id) do
    WishExpectation
    |> Ash.Query.filter(wish_id == ^wish_id)
    |> Ash.count!(authorize?: false)
  end

  @doc "viewer 的 expected_by_viewer 读面：批量返回已期待的 wish_id 集。"
  @spec expected_wish_ids(list(String.t()), String.t() | nil, String.t() | nil) :: MapSet.t()
  def expected_wish_ids(wish_ids, actor_user_id, anon_voter_key) do
    voter_keys =
      [user_voter_key(actor_user_id), anon_voter_key]
      |> Enum.reject(&is_nil/1)

    if voter_keys == [] or wish_ids == [] do
      MapSet.new()
    else
      WishExpectation
      |> Ash.Query.filter(wish_id in ^wish_ids and voter_key in ^voter_keys)
      |> Ash.read!(authorize?: false, page: false)
      |> MapSet.new(& &1.wish_id)
    end
  end

  # ── 内部 ─────────────────────────────────────────────────────────────

  defp user_voter_key(nil), do: nil
  defp user_voter_key(uid) when is_binary(uid), do: "u:#{uid}"

  # 登录强制 u: 键（优先级）；匿名走 anon 键。两者都没有 → 拒绝。
  defp resolve_voter_key(user_id, _anon) when is_binary(user_id),
    do: "u:#{user_id}"

  defp resolve_voter_key(nil, anon) when is_binary(anon), do: anon
  defp resolve_voter_key(nil, nil), do: nil

  defp validate_voter_key(voter_key) when is_binary(voter_key) do
    with true <- String.length(voter_key) <= @voter_key_max_length,
         [prefix, id] <- String.split(voter_key, ":", parts: 2),
         true <- prefix in @voter_prefixes,
         true <- id != "" do
      :ok
    else
      _ -> {:error, invalid_voter_key()}
    end
  end

  defp validate_voter_key(_), do: {:error, invalid_voter_key()}

  defp invalid_voter_key do
    %{
      code: "flashback_invalid_voter_key",
      message: "invalid voter key (expected u:<id> or a:<id>)",
      reason: :invalid_voter_key
    }
  end

  # KTD9：目标 wish 必须当前可对调方可见——公开面须 listed+public+未 hidden+未删
  # （登录 actor 也属于本面，可加宽允许未 listed）；否则 flashback_wish_not_found。
  defp fetch_visible_wish(wish_id, actor_user_id) do
    with {:ok, uuid} <- Ecto.UUID.cast(wish_id),
         {:ok, wish} when not is_nil(wish) <- find_wish(uuid, actor_user_id) do
      {:ok, wish}
    else
      _ ->
        {:error,
         %{
           code: "flashback_wish_not_found",
           message: "wish not found",
           reason: :wish_not_found
         }}
    end
  end

  defp find_wish(uuid, actor_user_id) do
    base =
      Wish
      |> Ash.Query.filter(
        id == ^uuid and visibility == "public" and
          is_nil(deleted_at) and is_nil(hidden_at)
      )

    base =
      cond do
        # 匿名公开面：强制 listed
        is_nil(actor_user_id) ->
          Ash.Query.filter(base, not is_nil(listed_at))

        # FIX-2（审计 U2 缺口 1 / KTD9）：登录成员面——可解析 person 的成员
        # 可期待未 listed 愿望；无 person 的 viewer 仅 listed（与附议资格同口径）
        member?(actor_user_id) ->
          base

        true ->
          Ash.Query.filter(base, not is_nil(listed_at))
      end

    Ash.read_one(base, authorize?: false)
  end

  defp member?(actor_user_id) do
    case Repo.query("SELECT 1 FROM flashback_people WHERE user_id = $1 LIMIT 1", [
           Repo.uuid!(actor_user_id)
         ]) do
      {:ok, %{num_rows: 1}} -> true
      _ -> false
    end
  end

  defp check_rate_limit(remote_ip, voter_key) do
    ip_key =
      Cgc2046Web.Plugs.RateLimit.build_key(
        "rate:flashback-expect-wish:ip",
        remote_ip || "unknown"
      )

    voter_key_limited =
      Cgc2046Web.Plugs.RateLimit.build_key("rate:flashback-expect-wish:voter", voter_key)

    with :ok <-
           Cgc2046Web.Plugs.RateLimit.check(ip_key,
             window_seconds: @ip_window_seconds,
             max_attempts: @ip_max_attempts
           ),
         :ok <-
           Cgc2046Web.Plugs.RateLimit.check(voter_key_limited,
             window_seconds: @voter_window_seconds,
             max_attempts: @voter_max_attempts
           ) do
      :ok
    else
      _ ->
        {:error,
         %{
           code: "flashback_expectation_rate_limited",
           message: "Too many expectation requests, try later",
           reason: :rate_limited
         }}
    end
  end

  defp do_expect(wish, voter_key, anon_voter_key_to_merge) do
    # KTD2 登录合并：upsert u: 行前先删该 anon 行（若有）
    if anon_voter_key_to_merge && anon_voter_key_to_merge != voter_key do
      WishExpectation
      |> Ash.Query.filter(
        wish_id == ^wish.id and voter_key == ^anon_voter_key_to_merge
      )
      |> Ash.read_one(authorize?: false)
      |> case do
        {:ok, %WishExpectation{} = row} -> Ash.destroy(row, authorize?: false)
        _ -> :ok
      end
    end

    WishExpectation
    |> Ash.Changeset.for_create(:create, %{wish_id: wish.id, voter_key: voter_key})
    |> Ash.create(authorize?: false)
    |> case do
      {:ok, _row} ->
        {:ok, %{expectation_count: count_for_wish(wish.id), expected_by_me: true}}

      {:error, error} ->
        {:error, error}
    end
  end

  defp do_unexpect(wish_id, voter_key) do
    WishExpectation
    |> Ash.Query.filter(wish_id == ^wish_id and voter_key == ^voter_key)
    |> Ash.read_one(authorize?: false)
    |> case do
      {:ok, nil} ->
        {:ok, %{expectation_count: count_for_wish(wish_id), expected_by_me: false}}

      {:ok, %WishExpectation{} = row} ->
        case Ash.destroy(row, authorize?: false) do
          :ok ->
            {:ok, %{expectation_count: count_for_wish(wish_id), expected_by_me: false}}

          {:error, reason} ->
            {:error, reason}
        end

      {:error, reason} ->
        {:error, reason}
    end
  end
end
