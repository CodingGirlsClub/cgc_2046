defmodule Cgc2046.Flashback.Likes do
  @moduledoc """
  金句点赞写面（R36/R37）：公开 mutation `flashbackLikeQuote` 的服务端逻辑。

  - **去重键**：客户端生成 `voter_key` = `u:<user_id>`（登录用户按账号去重）或
    `a:<device_uuid>`（路人按设备去重）。服务端只校验格式与长度上限——
    真实去重靠 `flashback_likes` 的 `(quote_id, voter_key)` 唯一索引；
  - **幂等**：liked=true 重复调用不报错也不重复计数（Ash upsert 承接并发双击）；
    liked=false 删行，无行也是成功；
  - **限频**：双层——IP 窗口（`rate:flashback-like:ip`，60 次/小时，容纳
    「来回取消/重赞」与 NAT 后多人）+ voter_key 窗口
    （`rate:flashback-like:voter`，30 次/分钟，R29 防刷：单设备高频刷赞硬拦）。
    按 voter_key 限频不能替代 IP 维度（伪造新 key 即可绕过），两者并存；
  - **目标校验**：被赞句必须当前确实在金句墙上（授权档 anonymous/credited +
    license 与单句均未下线 + 档案未删除），否则 `flashback_quote_not_found`
    ——不泄露「存在但未授权」与「不存在」的区别。
  """

  require Ash.Query

  alias Cgc2046.Flashback.{Like, Quote}

  @voter_prefixes ~w(u a)
  # voter_key 上限：`u:` + uuid(36) = 38；给 64 留余量（服务端只做长度防线）。
  @voter_key_max_length 64
  @ip_window_seconds 3600
  @ip_max_attempts 60
  # R29 防刷：同一 voter_key 每分钟点赞次数上限（执行时定值 30，见计划 U2）。
  @voter_window_seconds 60
  @voter_max_attempts 30

  @doc """
  点赞 / 取消（R36/R37）。返回 `{:ok, %{like_count: n}}`（该句实时计数，
  前端就地更新）。
  """
  @spec set_like(String.t(), String.t(), boolean(), String.t() | nil) ::
          {:ok, %{like_count: non_neg_integer()}} | {:error, term()}
  def set_like(quote_id, voter_key, liked?, remote_ip) do
    with :ok <- validate_voter_key(voter_key),
         :ok <- check_rate_limit(remote_ip, voter_key),
         {:ok, ^quote_id} <- validate_target(quote_id) do
      case liked? do
        true -> create_like(quote_id, voter_key)
        false -> destroy_like(quote_id, voter_key)
      end
    end
  end

  @doc "某句的点赞数（公开读面实时 COUNT 同源；测试断言用）。"
  @spec count_for_quote(String.t()) :: non_neg_integer()
  def count_for_quote(quote_id) do
    Like
    |> Ash.Query.filter(quote_id == ^quote_id)
    |> Ash.count!(authorize?: false)
  end

  @doc "某人的点赞数（作者侧回访面 quoteStats：按人聚合其全部句）。"
  @spec count_for_person(String.t()) :: non_neg_integer()
  def count_for_person(person_id) do
    Like
    |> Ash.Query.filter(quote.quote_license.person_id == ^person_id)
    |> Ash.count!(authorize?: false)
  end

  # ── 内部 ─────────────────────────────────────────────────────────────

  defp validate_voter_key(voter_key) when is_binary(voter_key) do
    with true <- String.length(voter_key) <= @voter_key_max_length,
         [prefix, id] <- String.split(voter_key, ":", parts: 2),
         true <- prefix in @voter_prefixes,
         true <- id != "" do
      :ok
    else
      _ -> invalid_voter_key()
    end
  end

  defp validate_voter_key(_), do: invalid_voter_key()

  defp invalid_voter_key do
    {:error,
     %{
       code: "flashback_invalid_voter_key",
       message: "invalid voter key (expected u:<id> or a:<id>)",
       reason: :invalid_voter_key
     }}
  end

  # 被赞目标必须在墙上（与 Public.quotes/1 同口径：授权档 + license/单句
  # 未下线 + 档案未删除）。只查目标行（不按全墙枚举）。
  defp validate_target(quote_id) when is_binary(quote_id) do
    with {:ok, uuid} <- Ecto.UUID.cast(quote_id),
         {:ok, quote} when not is_nil(quote) <- fetch_visible_quote(uuid) do
      {:ok, quote.id}
    else
      _ -> quote_not_found()
    end
  end

  defp validate_target(_), do: quote_not_found()

  defp fetch_visible_quote(uuid) do
    Quote
    |> Ash.Query.filter(
      id == ^uuid and is_nil(hidden_at) and
        quote_license.level in ["anonymous", "credited"] and
        is_nil(quote_license.hidden_at) and
        is_nil(quote_license.person.deleted_at)
    )
    |> Ash.read_one(authorize?: false)
  end

  defp quote_not_found do
    {:error,
     %{
       code: "flashback_quote_not_found",
       message: "quote not found",
       reason: :quote_not_found
     }}
  end

  defp check_rate_limit(remote_ip, voter_key) do
    ip_key =
      Cgc2046Web.Plugs.RateLimit.build_key("rate:flashback-like:ip", remote_ip || "unknown")

    voter_key =
      Cgc2046Web.Plugs.RateLimit.build_key("rate:flashback-like:voter", voter_key)

    with :ok <-
           Cgc2046Web.Plugs.RateLimit.check(ip_key,
             window_seconds: @ip_window_seconds,
             max_attempts: @ip_max_attempts
           ),
         :ok <-
           Cgc2046Web.Plugs.RateLimit.check(voter_key,
             window_seconds: @voter_window_seconds,
             max_attempts: @voter_max_attempts
           ) do
      :ok
    else
      _ ->
        {:error,
         %{
           code: "flashback_like_rate_limited",
           message: "Too many like requests, try later",
           reason: :rate_limited
         }}
    end
  end

  defp create_like(quote_id, voter_key) do
    Like
    |> Ash.Changeset.for_create(:create, %{quote_id: quote_id, voter_key: voter_key})
    |> Ash.create(authorize?: false)
    |> case do
      {:ok, _like} -> {:ok, %{like_count: count_for_quote(quote_id)}}
      {:error, error} -> {:error, error}
    end
  end

  defp destroy_like(quote_id, voter_key) do
    Like
    |> Ash.Query.filter(quote_id == ^quote_id and voter_key == ^voter_key)
    |> Ash.read_one(authorize?: false)
    |> case do
      {:ok, nil} -> {:ok, %{like_count: count_for_quote(quote_id)}}
      {:ok, like} -> destroy_existing(like, quote_id)
      {:error, error} -> {:error, error}
    end
  end

  defp destroy_existing(like, quote_id) do
    case Ash.destroy(like, authorize?: false) do
      :ok -> {:ok, %{like_count: count_for_quote(quote_id)}}
      {:ok, _} -> {:ok, %{like_count: count_for_quote(quote_id)}}
      {:error, error} -> {:error, error}
    end
  end
end
