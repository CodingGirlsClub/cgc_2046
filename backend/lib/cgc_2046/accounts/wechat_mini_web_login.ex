defmodule Cgc2046.Accounts.WechatMiniWebLogin do
  @moduledoc "Explicit mini-program approval, independently bound to the initiating browser."
  require Ash.Query
  require Logger
  alias Cgc2046.Accounts.{SignInFlow, User, UserIdentity, WechatMiniWebLoginRequest}
  alias Cgc2046.Integrations.Wechat.WebLoginLaunch
  alias Cgc2046.Repo
  @internal [context: %{private: %{ash_authentication?: true}}]

  def start(mode, context) do
    with :ok <- browser(context),
         {:ok, rate_key} <- browser_rate_key(context[:mini_web_proof]),
         :ok <- limits(:start, rate_key, context),
         code <- random(16),
         proof <- random(32),
         {:ok, launch} <- WebLoginLaunch.generate(mode, code),
         {:ok, row} <-
           transaction(fn ->
             cancel_previous(context[:mini_web_proof])

             Ash.create(
               WechatMiniWebLoginRequest,
               %{
                 public_code: code,
                 browser_proof_hash: digest(proof),
                 browser_rate_key: rate_key,
                 expires_at: DateTime.add(now(), 600)
               },
               authorize?: false
             )
           end) do
      event(:started, %{count: 1}, %{mode: mode})
      {:ok, Map.merge(view(row), launch) |> Map.put(:__proof__, proof)}
    end
  end

  def preview(code, context) do
    with :ok <- valid_code(code),
         :ok <- limits(:preview, code, context),
         {:ok, row} <- fetch(code),
         do: {:ok, view(row)}
  end

  def status(code, context) do
    with :ok <- browser(context),
         :ok <- valid_code(code),
         {:ok, row} <- fetch(code),
         :ok <- proof(row, context),
         :ok <- limits(:status, code, context) do
      claims = context[:mini_web_claims] || %{}

      established =
        row.status == :consumed and not is_nil(row.consumed_jti) and
          claims["jti"] == row.consumed_jti and
          match?(%User{id: id} when id == row.user_id, context[:actor])

      {:ok, Map.put(view(row), :session_established, established)}
    end
  end

  def confirm(code, context) do
    with :ok <- valid_code(code),
         {:ok, user} <- mini_actor(context),
         :ok <- limits(:confirm, user.id, context) do
      transaction(fn ->
        with {:ok, row} <- fetch(code, true), :ok <- active(row) do
          case row do
            %{status: :pending} ->
              transition(row, %{status: :approved, user_id: user.id, approved_at: now()})

            %{status: :approved, user_id: id} when id == user.id ->
              {:ok, row}

            %{status: :approved} ->
              {:error, :mini_web_login_account_conflict}

            _ ->
              {:error, :mini_web_login_consumed}
          end
        end
      end)
      |> result_view(:approved)
    end
  end

  def cancel(code, context) do
    with :ok <- browser(context), :ok <- valid_code(code) do
      transaction(fn ->
        with {:ok, row} <- fetch(code, true),
             :ok <- proof(row, context),
             :ok <- limits(:cancel, code, context) do
          if row.status in [:pending, :approved],
            do: transition(row, %{status: :cancelled, cancelled_at: now()}),
            else: {:ok, row}
        end
      end)
      |> result_view(:cancelled)
    end
  end

  def consume(code, context) do
    with :ok <- browser(context), :ok <- valid_code(code) do
      transaction(fn ->
        with {:ok, row} <- fetch(code, true),
             :ok <- proof(row, context),
             :ok <- limits(:consume, code, context),
             :ok <- active(row),
             :ok <- approved(row),
             :ok <- same_actor(row, context),
             {:ok, %User{phone: phone} = user} when is_binary(phone) <-
               Ash.get(User, row.user_id, @internal),
             :ok <- SignInFlow.revoke_stored_tokens(user, :web),
             {:ok, signed} <- SignInFlow.generate_token(user, :web, context),
             token when is_binary(token) <- signed.__metadata__[:token],
             {:ok, %{"jti" => jti}, _} <- AshAuthentication.Jwt.verify(token, User),
             {:ok, _} <-
               transition(row, %{status: :consumed, consumed_at: now(), consumed_jti: jti}) do
          {:ok,
           %{
             id: user.id,
             status: :consumed,
             __token__: token,
             __approval_delay__: DateTime.diff(now(), row.approved_at, :second)
           }}
        else
          {:error, _} = error -> error
          _ -> {:error, :mini_web_login_failed}
        end
      end)
      |> tap(fn
        {:ok, result} ->
          event(:consumed, %{count: 1, approval_to_consume_seconds: result.__approval_delay__})

        _ ->
          event(:consume_failed)
      end)
    end
  end

  defp mini_actor(%{
         actor: %User{phone: phone} = user,
         mini_web_claims: %{"platform" => "wechat"}
       })
       when is_binary(phone) and phone != "" do
    with {:ok, [_ | _]} <-
           UserIdentity
           |> Ash.Query.filter(user_id == ^user.id and provider == :wechat)
           |> Ash.read(@internal) do
      {:ok, user}
    else
      _ -> {:error, :mini_web_login_invalid}
    end
  end

  defp mini_actor(%{actor: %User{phone: nil}}), do: {:error, :mini_web_login_phone_required}
  defp mini_actor(_), do: {:error, :mini_web_login_invalid}

  defp browser(%{mini_web_browser?: true}), do: :ok
  defp browser(_), do: {:error, :mini_web_login_invalid}

  defp valid_code(code) when is_binary(code) do
    if Regex.match?(~r/\A[A-Za-z0-9_-]{22}\z/, code),
      do: :ok,
      else: {:error, :mini_web_login_invalid}
  end

  defp valid_code(_), do: {:error, :mini_web_login_invalid}

  defp fetch(code, lock? \\ false) do
    query = WechatMiniWebLoginRequest |> Ash.Query.filter(public_code == ^code)
    query = if lock?, do: Ash.Query.lock(query, "FOR UPDATE"), else: query

    case Ash.read_one(query, authorize?: false) do
      {:ok, nil} -> {:error, :mini_web_login_invalid}
      other -> other
    end
  end

  defp proof(row, %{mini_web_proof: proof}) when is_binary(proof) and byte_size(proof) == 43 do
    if Plug.Crypto.secure_compare(row.browser_proof_hash, digest(proof)),
      do: :ok,
      else: {:error, :mini_web_login_invalid}
  end

  defp proof(_, _), do: {:error, :mini_web_login_invalid}

  defp active(row) do
    cond do
      DateTime.compare(row.expires_at, now()) != :gt -> {:error, :mini_web_login_expired}
      row.status == :cancelled -> {:error, :mini_web_login_cancelled}
      true -> :ok
    end
  end

  defp approved(%{status: :approved}), do: :ok
  defp approved(%{status: :consumed}), do: {:error, :mini_web_login_consumed}
  defp approved(_), do: {:error, :mini_web_login_not_approved}

  defp same_actor(%{user_id: id}, %{actor: %User{id: other}}) when id != other,
    do: {:error, :mini_web_login_account_conflict}

  defp same_actor(_, _), do: :ok

  defp transition(row, attrs) do
    row
    |> Ash.Changeset.for_update(:transition, Map.take(attrs, [:status]))
    |> Ash.Changeset.force_change_attributes(Map.drop(attrs, [:status]))
    |> Ash.update(authorize?: false)
  end

  defp cancel_previous(proof) when is_binary(proof) and byte_size(proof) == 43 do
    hash = digest(proof)

    rows =
      WechatMiniWebLoginRequest
      |> Ash.Query.filter(browser_proof_hash == ^hash and status in [:pending, :approved])
      |> Ash.Query.lock("FOR UPDATE")
      |> Ash.read!(authorize?: false)

    Enum.each(rows, fn row ->
      case transition(row, %{status: :cancelled, cancelled_at: now()}) do
        {:ok, _} -> :ok
        {:error, _} -> Repo.rollback(:mini_web_login_failed)
      end
    end)
  end

  defp cancel_previous(_), do: :ok

  # Refresh rotates the proof, but must not reset the browser's rate-limit bucket.
  defp browser_rate_key(proof) when is_binary(proof) and byte_size(proof) == 43 do
    hash = digest(proof)

    case WechatMiniWebLoginRequest
         |> Ash.Query.filter(browser_proof_hash == ^hash)
         |> Ash.read_one(authorize?: false) do
      {:ok, nil} -> {:ok, random(16)}
      {:ok, row} -> {:ok, row.browser_rate_key}
      _ -> {:error, :mini_web_login_failed}
    end
  end

  defp browser_rate_key(_), do: {:ok, random(16)}

  defp transaction(fun) do
    Repo.transaction(fn ->
      case fun.() do
        {:ok, value} -> value
        {:error, reason} when is_atom(reason) -> Repo.rollback(reason)
        _ -> Repo.rollback(:mini_web_login_failed)
      end
    end)
  rescue
    exception ->
      Logger.error("mini web login transaction failed", error_type: inspect(exception.__struct__))
      {:error, :mini_web_login_failed}
  end

  defp view(row) do
    status =
      if row.status in [:pending, :approved] and DateTime.compare(row.expires_at, now()) != :gt,
        do: :expired,
        else: row.status

    if status == :expired, do: event(:expired)

    %{
      request_id: row.public_code,
      status: status,
      expires_at: row.expires_at,
      poll_interval_seconds: 3,
      session_established: false
    }
  end

  defp result_view({:ok, row}, name),
    do:
      (
        event(name)
        {:ok, view(row)}
      )

  defp result_view(error, _), do: error

  defp limits(action, key, context) do
    alias Cgc2046Web.Plugs.RateLimit

    checks =
      case action do
        :start -> [{key, 3, 1}, {key, 3600, 20}, {context[:mini_web_ip], 3600, 60}]
        :preview -> [{key, 60, 30}, {context[:mini_web_ip], 60, 120}]
        :status -> [{key, 60, 30}]
        :confirm -> [{key, 60, 20}]
        _ -> [{key, 60, 10}]
      end

    checks
    |> Enum.with_index()
    |> Enum.reduce_while(:ok, fn {{value, seconds, max}, i}, _ ->
      bucket = RateLimit.build_key("mini-web:#{action}:#{i}", value)

      case RateLimit.check(bucket, window_seconds: seconds, max_attempts: max) do
        :ok -> {:cont, :ok}
        :error -> {:halt, {:error, :rate_limited}}
      end
    end)
  end

  defp event(name, measurements \\ %{count: 1}, metadata \\ %{}),
    do: :telemetry.execute([:cgc2046, :mini_web_login, name], measurements, metadata)

  @doc false
  def record_rejection(reason) do
    name =
      case reason do
        :mini_web_login_unavailable -> :launch_failed
        :mini_web_login_expired -> :expired
        :rate_limited -> :rate_limited
        _ -> :failed
      end

    event(name, %{count: 1}, %{code: domain_error_code(reason)})
  end

  defp digest(value), do: :crypto.hash(:sha256, value)
  defp random(size), do: Base.url_encode64(:crypto.strong_rand_bytes(size), padding: false)
  defp now, do: DateTime.utc_now() |> DateTime.truncate(:second)
  @doc false
  def error_code(reason), do: domain_error_code(reason)
  defp domain_error_code(:mini_web_login_invalid), do: "mini_web_login_invalid"
  defp domain_error_code(:mini_web_login_expired), do: "mini_web_login_expired"
  defp domain_error_code(:mini_web_login_cancelled), do: "mini_web_login_cancelled"
  defp domain_error_code(:mini_web_login_not_approved), do: "mini_web_login_not_approved"
  defp domain_error_code(:mini_web_login_consumed), do: "mini_web_login_consumed"
  defp domain_error_code(:mini_web_login_account_conflict), do: "mini_web_login_account_conflict"
  defp domain_error_code(:mini_web_login_phone_required), do: "mini_web_login_phone_required"
  defp domain_error_code(:mini_web_login_unavailable), do: "mini_web_login_unavailable"
  defp domain_error_code(:rate_limited), do: "rate_limited"
  defp domain_error_code(_), do: "mini_web_login_failed"
end
