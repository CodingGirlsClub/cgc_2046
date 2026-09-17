defmodule Cgc2046.Flashback.Recover do
  @moduledoc """
  自助找回（U6/R21/KTD7「找回即正门」）：未收到链接的当年报名者凭预留
  手机号/邮箱验证身份 → 建号（find-or-create）→ 档案自动绑定。

  ## 防枚举与限流

  - 命中与未命中返回同一形态（`dispatched: true`），不泄露存在性；
  - 双窗口限流（identifier + IP，1 小时，照 `WebAuthFlow.check_password_reset_request_limits`
    形状）；超限 → `flashback_recover_rate_limited`；
  - 手机验证码复用 `:register` purpose（找回即正门，KTD7）。

  ## 通道分派

  - 手机号命中：`PhoneVerificationCode.issue/2` 发码；verify 通过后
    find-or-create User 并**绑定全部匹配档案**（一人多场报名多卡全绑），
    返回脱敏卡列表（「你的 N 张卡」由本人选择先看哪张）；
  - 邮箱命中：每个匹配档案铸一个一次性 token，恢复邮件列出全部入口
    链接（明文 token 只进邮件正文，不落任何持久化载体——生成→渲染→
    发送→只落 hash，KTD2）。
  """

  require Ash.Query
  require Logger

  alias Cgc2046.Accounts.{PhoneNumber, PhoneVerificationCode, SignInFlow, TokenCredential}
  alias Cgc2046.Flashback.{Person, Token}
  alias Cgc2046.Mailer

  @recover_window_seconds 3_600
  @id_max_attempts 5
  @ip_max_attempts 20

  # ── 发起 ─────────────────────────────────────────────────────────────

  @doc """
  发起找回：限流 → 匹配（手机精确 → 邮箱兜底）→ 命中则发码（手机）或
  发恢复邮件（邮箱）。未命中静默同形返回（防枚举）。
  """
  @spec initiate(String.t(), String.t()) ::
          {:ok, %{dispatched: boolean()}}
          | {:error, %{code: String.t(), message: String.t(), reason: atom()}}
  def initiate(identifier, remote_ip) do
    with :ok <- check_rate_limits(identifier, remote_ip) do
      dispatch(identifier)
      {:ok, %{dispatched: true}}
    end
  end

  defp dispatch(identifier) do
    case classify(identifier) do
      {:phone, phone} ->
        case match_people(:phone, identifier, phone) do
          [] -> :ok
          _people -> issue_phone_code(phone)
        end

      {:email, email} ->
        case match_people(:email, email, nil) do
          [] -> :ok
          people -> send_recovery_email(email, people)
        end

      :unrecognized ->
        :ok
    end
  end

  defp issue_phone_code(phone) do
    case PhoneVerificationCode.issue(phone, :register) do
      {:ok, _code, _request_id} ->
        :ok

      {:error, reason} ->
        # 发码失败只降级（发起面仍同形返回 dispatched——防枚举优先）
        Logger.warning("[flashback] recover code issue failed: #{inspect(reason)}")
        :ok
    end
  end

  # ── 验证（手机通道） ─────────────────────────────────────────────────

  @doc """
  验证找回：码通过 → find-or-create User → 绑定**全部**匹配档案（并作废
  其全部有效 token，R1 账号接管）→ 签会话 token（httpOnly cookie 经
  GraphQL middleware 交付）。返回脱敏卡列表（多档案=「你的 N 张卡」）。
  """
  @spec verify(String.t(), String.t(), map()) ::
          {:ok, %{__token__: String.t(), bound: boolean(), cards: [map()]}}
          | {:error, term()}
  def verify(identifier, code, context) do
    case classify(identifier) do
      {:phone, phone} when is_binary(phone) ->
        do_verify(identifier, phone, code, context)

      _ ->
        # 非手机形态（邮箱走邮件链路）：与码错同文案，不泄露通道差异
        {:error, invalid_code_error()}
    end
  end

  defp do_verify(identifier, phone, code, context) do
    with :ok <- consume_code(phone, code),
         people when people != [] <- match_people(:phone, identifier, phone),
         {:ok, user, created?} <- SignInFlow.find_or_create_user(phone),
         :ok <- SignInFlow.maybe_admit_to_default_workspace(user, created?),
         :ok <- SignInFlow.revoke_stored_tokens(user, :web),
         {:ok, user} <- SignInFlow.generate_token(user, :web, context),
         :ok <- bind_all(people, user) do
      {:ok,
       %{
         __token__: user.__metadata__[:token],
         bound: true,
         cards: Enum.map(people, &card_payload/1)
       }}
    else
      [] ->
        # 码对但无档案（边缘）：与码错同文案，不泄露存在性
        {:error, invalid_code_error()}

      {:error, %{code: error_code} = error} when is_binary(error_code) ->
        {:error, error}

      {:error, _reason} ->
        {:error, invalid_code_error()}
    end
  end

  defp consume_code(phone, code) do
    case PhoneVerificationCode.consume_valid(phone, code, :register) do
      :ok -> :ok
      {:error, _} -> {:error, invalid_code_error()}
    end
  end

  defp invalid_code_error do
    %{code: "invalid_or_expired_code", message: "Invalid or expired code", reason: :invalid_code}
  end

  defp bind_all(people, user) do
    Enum.each(people, fn person ->
      person
      |> Ash.Changeset.for_update(:update, %{})
      |> Ash.Changeset.force_change_attribute(:user_id, user.id)
      |> Ash.update!(authorize?: false)

      # R1 注册即链接作废：该档案全部有效 token 置 claimed（账号接管）
      Token
      |> Ash.Query.for_read(:read)
      |> Ash.Query.filter(person_id == ^person.id and is_nil(claimed_by_user_id))
      |> Ash.read!(authorize?: false)
      |> Enum.each(fn token ->
        token
        |> Ash.Changeset.for_update(:update, %{})
        |> Ash.Changeset.force_change_attribute(:claimed_by_user_id, user.id)
        |> Ash.Changeset.force_change_attribute(:claimed_at, DateTime.utc_now())
        |> Ash.update!(authorize?: false)
      end)
    end)

    :ok
  end

  # ── 内部 ─────────────────────────────────────────────────────────────

  defp classify(raw) when is_binary(raw) do
    trimmed = String.trim(raw)

    cond do
      trimmed == "" ->
        :unrecognized

      String.contains?(trimmed, "@") ->
        {:email, String.downcase(trimmed)}

      true ->
        case PhoneNumber.normalize(trimmed) do
          {:ok, phone} -> {:phone, phone}
          {:error, :invalid} -> :unrecognized
        end
    end
  end

  defp classify(_), do: :unrecognized

  # 手机形态兼容：导入数据可能存裸 11 位或 +86 归一形态，双形态 OR 匹配
  # （do_verify 走 classify 后的归一形态；verify 再取本人输入原文补一路）
  defp match_people(:phone, raw, normalized) do
    raw_trimmed = raw && String.trim(raw)

    Person
    |> Ash.Query.for_read(:read)
    |> Ash.Query.filter(phone == ^normalized or phone == ^raw_trimmed)
    |> Ash.Query.sort(inserted_at: :asc)
    |> Ash.read!(authorize?: false)
  end

  defp match_people(:email, email, _nil) do
    Person
    |> Ash.Query.for_read(:read)
    |> Ash.Query.filter(email == ^email)
    |> Ash.Query.sort(inserted_at: :asc)
    |> Ash.read!(authorize?: false)
  end

  defp card_payload(person) do
    person = Ash.load!(person, :archive_event, authorize?: false)

    %{
      person_id: person.id,
      surname_masked: masked(person),
      event_name: person.archive_event && person.archive_event.name,
      city: person.city
    }
  end

  defp masked(%{full_name: full_name, surname: surname}) do
    if is_binary(surname) and surname != "" and String.starts_with?(full_name, surname) do
      surname <> String.duplicate("*", max(String.length(full_name) - String.length(surname), 1))
    else
      case String.graphemes(full_name) do
        [first | rest] -> first <> String.duplicate("*", max(length(rest), 1))
        [] -> ""
      end
    end
  end

  # 双窗口限流：identifier 5 次/小时 + IP 20 次/小时
  defp check_rate_limits(identifier, remote_ip) do
    identifier_key = Cgc2046Web.Plugs.RateLimit.build_key("rate:flashback-recover:id", identifier)

    ip_key =
      Cgc2046Web.Plugs.RateLimit.build_key("rate:flashback-recover:ip", remote_ip || "unknown")

    with :ok <-
           Cgc2046Web.Plugs.RateLimit.check(identifier_key,
             window_seconds: @recover_window_seconds,
             max_attempts: @id_max_attempts
           ),
         :ok <-
           Cgc2046Web.Plugs.RateLimit.check(
             ip_key,
             window_seconds: @recover_window_seconds,
             max_attempts: @ip_max_attempts
           ) do
      :ok
    else
      _ ->
        {:error,
         %{
           code: "flashback_recover_rate_limited",
           message: "Too many recovery attempts, try later",
           reason: :rate_limited
         }}
    end
  end

  # 恢复邮件：每档案一行入口链接（KTD2：明文 token 只进邮件正文）
  defp send_recovery_email(email, people) do
    links =
      Enum.map(people, fn person ->
        plain = "fb_" <> (:crypto.strong_rand_bytes(32) |> Base.url_encode64(padding: false))
        {:ok, hash} = TokenCredential.hash(plain)

        Token
        |> Ash.Changeset.for_create(:create, %{person_id: person.id, token_hash: hash})
        |> Ash.create!(authorize?: false)

        "- #{masked(person)} · #{person.city || ""}：#{base_url()}/flashback/enter?token=#{plain}"
      end)

    body = """
    这里是闪念间（In a Flash）。

    有人（希望是你）用这个邮箱发起了档案找回。你的档案入口：

    #{Enum.join(links, "\n")}

    如果这不是你本人的操作，请忽略本邮件——链接只发给预留邮箱，别人拿不到。
    """

    config = Application.get_env(:cgc_2046, Cgc2046.Mailer, [])
    from = Keyword.get(config, :from, "no-reply@example.com")
    from_name = Keyword.get(config, :from_name, "CGC 2046")

    message =
      Swoosh.Email.new()
      |> Swoosh.Email.from({from_name, from})
      |> Swoosh.Email.to(email)
      |> Swoosh.Email.subject("你的闪念间档案入口")
      |> Swoosh.Email.text_body(body)

    case Mailer.deliver(message) do
      {:ok, _} ->
        :ok

      {:error, reason} ->
        Logger.warning("[flashback] recovery email failed: #{inspect(reason)}")
    end
  end

  defp base_url do
    Application.get_env(:cgc_2046, :web_base_url, "http://localhost:3000")
    |> to_string()
    |> String.trim_trailing("/")
  end
end
