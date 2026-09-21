defmodule Cgc2046.Flashback.Likes do
  @moduledoc """
  金句点赞写面（R36）：公开 mutation `flashbackLikeQuote` 的服务端逻辑。

  - **去重键**：客户端生成 `voter_key` = `u:<user_id>`（登录用户按账号去重）或
    `a:<device_uuid>`（路人按设备去重）。服务端只校验格式与长度上限——
    真实去重靠 `flashback_likes` 的 `(person_id, voter_key)` 唯一索引；
  - **幂等**：liked=true 重复调用不报错也不重复计数（Ash upsert 承接并发双击）；
    liked=false 删行，无行也是成功；
  - **限频**：IP 窗口（`rate:flashback-like:ip`）——公开无登录端点，按 voter_key
    限频等于允许伪造新 key 绕过，IP 是唯一有约束力的维度；窗口给得宽
    （60 次/小时）以容纳「来回取消/重赞」的正常操作与 NAT 后的多人；
  - **目标校验**：被赞者必须当前确实在金句墙上（授权档 anonymous/credited +
    有选定区间 + 未被 R38 下线 + 档案未删除），否则 `flashback_quote_not_found`
    ——不泄露「存在但未授权」与「不存在」的区别。
  """

  require Ash.Query

  alias Cgc2046.Flashback.{Like, Public}

  @voter_prefixes ~w(u a)
  # voter_key 上限：`u:` + uuid(36) = 38；给 64 留余量（服务端只做长度防线）。
  @voter_key_max_length 64
  @window_seconds 3600
  @ip_max_attempts 60

  @doc """
  点赞 / 取消（R36）。返回 `{:ok, %{like_count: n}}`（实时计数，前端就地更新）。
  """
  @spec set_like(String.t(), String.t(), boolean(), String.t() | nil) ::
          {:ok, %{like_count: non_neg_integer()}} | {:error, term()}
  def set_like(person_id, voter_key, liked?, remote_ip) do
    with :ok <- validate_voter_key(voter_key),
         :ok <- check_rate_limit(remote_ip),
         {:ok, ^person_id} <- validate_target(person_id) do
      case liked? do
        true -> create_like(person_id, voter_key)
        false -> destroy_like(person_id, voter_key)
      end
    end
  end

  @doc "某人的点赞数（作者侧回访面 quoteStats / 测试断言用）。"
  @spec count_for_person(String.t()) :: non_neg_integer()
  def count_for_person(person_id) do
    Like
    |> Ash.Query.filter(person_id == ^person_id)
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

  # 被赞目标必须在墙上（Public.quotes 同口径：授权档 + 选定区间 + 未下线 + 未删除）。
  defp validate_target(person_id) when is_binary(person_id) do
    # 与公开墙同口径（Public.quotes/1 已含授权档 + 选定区间 + 未下线 + 未删除过滤）
    {:ok, quotes} = Public.quotes()

    if Enum.any?(quotes, &(&1.person_id == person_id)) do
      {:ok, person_id}
    else
      {:error,
       %{
         code: "flashback_quote_not_found",
         message: "quote not found",
         reason: :quote_not_found
       }}
    end
  end

  defp validate_target(_) do
    {:error,
     %{code: "flashback_quote_not_found", message: "quote not found", reason: :quote_not_found}}
  end

  defp check_rate_limit(remote_ip) do
    key = Cgc2046Web.Plugs.RateLimit.build_key("rate:flashback-like:ip", remote_ip || "unknown")

    case Cgc2046Web.Plugs.RateLimit.check(key,
           window_seconds: @window_seconds,
           max_attempts: @ip_max_attempts
         ) do
      :ok ->
        :ok

      _ ->
        {:error,
         %{
           code: "flashback_like_rate_limited",
           message: "Too many like requests, try later",
           reason: :rate_limited
         }}
    end
  end

  defp create_like(person_id, voter_key) do
    Like
    |> Ash.Changeset.for_create(:create, %{person_id: person_id, voter_key: voter_key})
    |> Ash.create(authorize?: false)
    |> case do
      {:ok, _like} -> {:ok, %{like_count: count_for_person(person_id)}}
      {:error, error} -> {:error, error}
    end
  end

  defp destroy_like(person_id, voter_key) do
    Like
    |> Ash.Query.filter(person_id == ^person_id and voter_key == ^voter_key)
    |> Ash.read_one(authorize?: false)
    |> case do
      {:ok, nil} -> {:ok, %{like_count: count_for_person(person_id)}}
      {:ok, like} -> destroy_existing(like, person_id)
      {:error, error} -> {:error, error}
    end
  end

  defp destroy_existing(like, person_id) do
    case Ash.destroy(like, authorize?: false) do
      :ok -> {:ok, %{like_count: count_for_person(person_id)}}
      {:ok, _} -> {:ok, %{like_count: count_for_person(person_id)}}
      {:error, error} -> {:error, error}
    end
  end
end
