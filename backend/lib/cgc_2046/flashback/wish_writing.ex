defmodule Cgc2046.Flashback.WishWriting do
  @moduledoc "Single creation pipeline for account writers and historical token writers."
  require Ash.Query
  alias Cgc2046.Flashback.{Cities, Wish, WishAuthors, Wishes}
  alias Cgc2046.Repo

  def create(identity, content, visibility, opts \\ []) do
    key = Keyword.get(opts, :request_id)
    fingerprint = fingerprint(content, visibility, opts)
    author = WishAuthors.resolve(identity)

    with :ok <- Wishes.validate_content(content),
         :ok <- validate_visibility(visibility),
         :ok <- validate_key(key),
         {:ok, replay} <- replay(author, key, fingerprint) do
      if replay do
        result(replay)
      else
        with :ok <- check_content(author, content),
             {:ok, _} <- snapshots(author, opts) do
          Repo.transaction(fn ->
            author = WishAuthors.lock(identity)

            with {:ok, replay} <- replay(author, key, fingerprint) do
              replay || insert(author, content, visibility, opts, key, fingerprint)
            else
              {:error, reason} -> Repo.rollback(reason)
            end
          end)
          |> case do
            {:ok, wish} -> result(wish)
            error -> error
          end
        end
      end
    end
  end

  defp insert(author, content, visibility, opts, key, fingerprint) do
    if WishAuthors.quota_remaining(author) == 0,
      do:
        Repo.rollback(%{code: "flashback_wish_quota_exceeded", message: "今年的许愿名额已用完（每年最多 3 条）。"})

    snapshot =
      case snapshots(author, opts) do
        {:ok, s} -> s
        {:error, reason} -> Repo.rollback(reason)
      end

    consent = visibility == "public" and Keyword.get(opts, :public_listing_consent, false)
    now = DateTime.utc_now()

    attributes =
      Map.merge(author, %{
        signature: snapshot.signature,
        listed_at: if(consent and not snapshot.review_required, do: now),
        hidden_at: if(consent and snapshot.review_required, do: now),
        request_id: if(author.user_id, do: key),
        request_fingerprint: if(author.user_id && key, do: fingerprint)
      })

    Wish
    |> Ash.Changeset.for_create(
      :create,
      %{content: String.trim(content), visibility: visibility, city: snapshot.city},
      context: %{wish_author_attributes: attributes}
    )
    |> Ash.create(authorize?: false)
    |> case do
      {:ok, wish} -> wish
      {:error, reason} -> Repo.rollback(reason)
    end
  end

  defp result(wish),
    do: {:ok, Map.put(wish, :listing_status, Wishes.listing_status(wish.visibility, wish))}

  defp check_content(%{user_id: id}, content) when is_binary(id),
    do: Wishes.check_content_by_user(id, content)

  defp check_content(%{person_id: id}, content), do: Wishes.check_content(id, content)

  defp snapshots(%{person_id: id}, opts) when is_binary(id) do
    Wishes.build_writer_snapshots(
      id,
      Keyword.get(opts, :expected_city),
      Keyword.get(opts, :signature_choice, :anonymous)
    )
  end

  defp snapshots(%{user_id: id}, opts) do
    with {:ok, city} <- Cities.normalize(Keyword.get(opts, :expected_city) || "") do
      # P2-1 机审通道门（同 wishes.build_writer_snapshots）：机审只对有微信身份的
      # 作者可用，无微信身份（web/小红书单平台账号）→ 公开愿进人工审核。
      %{rows: [[name, review]]} =
        Repo.query!(
          "SELECT display_name, (wishes_review_required_at IS NOT NULL OR NOT EXISTS (" <>
            "SELECT 1 FROM user_identities i WHERE i.user_id = users.id AND i.provider = 'wechat'" <>
            ")) FROM users WHERE id=$1",
          [Repo.uuid!(id)]
        )

      signature =
        if Keyword.get(opts, :signature_choice) == :display_name and is_binary(name) and
             name != "", do: name, else: "匿名"

      {:ok, %{city: city, signature: signature, review_required: review}}
    end
  end

  defp validate_visibility(v) when v in ["public", "private"], do: :ok

  defp validate_visibility(_),
    do: {:error, %{code: "flashback_wish_invalid_visibility", message: "请选择愿望可见范围。"}}

  defp validate_key(nil), do: :ok
  defp validate_key(k) when is_binary(k) and byte_size(k) in 1..80, do: :ok

  defp validate_key(_),
    do: {:error, %{code: "flashback_wish_invalid_request_id", message: "提交标识无效，请重新打开页面。"}}

  defp fingerprint(content, visibility, opts) do
    # Hash input, not mutable profile snapshots, so a retry after rename is stable.
    {content, visibility, Keyword.get(opts, :expected_city),
     Keyword.get(opts, :signature_choice, :anonymous),
     Keyword.get(opts, :public_listing_consent, false)}
    |> :erlang.term_to_binary()
    |> then(&:crypto.hash(:sha256, &1))
    |> Base.encode16(case: :lower)
  end

  defp replay(%{user_id: nil}, _, _), do: {:ok, nil}
  defp replay(_, nil, _), do: {:ok, nil}

  defp replay(%{user_id: user_id}, key, fingerprint) do
    case Wish
         |> Ash.Query.filter(user_id == ^user_id and request_id == ^key)
         |> Ash.read_one(authorize?: false) do
      {:ok, nil} ->
        {:ok, nil}

      {:ok, %{request_fingerprint: ^fingerprint} = wish} ->
        {:ok, wish}

      {:ok, _} ->
        {:error, %{code: "flashback_wish_request_conflict", message: "这次提交的内容已改变，请重新提交。"}}

      error ->
        error
    end
  end
end
