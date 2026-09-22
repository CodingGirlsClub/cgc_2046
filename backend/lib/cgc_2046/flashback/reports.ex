defmodule Cgc2046.Flashback.Reports do
  @moduledoc """
  举报 + admin 治理（KTD5 U5）。

  举报路径（公开 mutation `flashbackReportWish`）：
  - target_type ∈ "wish" / "wish_comment"，目标必须存在（不泄露不存在 vs 已删）
  - reason_type ∈ preset；reason_free ≤200；reporter 登录强制 u:，匿名可 a:
  - 频控：10 次 / 15 分钟 / IP（KTD5 频控规格）
  - **不**隐藏 target，仅入库到 `flashback_reports(status='pending')`

  Admin 路径（Flashback namespace；`flashbackAdmin*` 命名）：
  - `set_wish_hidden(wish_id, admin_user_id, true|false)`：置位/清除 hidden_at。
    置位时**同步**给 wish 作者的 user 置 `wishes_review_required_at`（G1 信用字段）；
  - `dismiss_report(report_id, admin_user_id)`：status=dismissed
  - `approve_report(report_id, admin_user_id)`：status=actioned + 置 hidden_at（联动）
  - `list_pending_reports/0`：admin 队列
  - `list_inbox_private_wishes/0`：visibility=private 作者联络信息（**仅 admin**）
  """

  require Ash.Query

  alias Cgc2046.Accounts.User
  alias Cgc2046.Flashback.{AlumniProjection, Report, Wish}
  alias Cgc2046.Repo

  @ip_window_seconds 900
  @ip_max_attempts 10

  @doc """
  公开举报。要求 actor 登录（或匿名带 device key）+ IP 频控。
  """
  @spec report(String.t(), String.t(), String.t(), keyword()) ::
          {:ok, Report.t()} | {:error, term()}
  def report(target_type, target_id, reason_type, opts \\ []) do
    reason_free = Keyword.get(opts, :reason_free, nil)
    actor_user_id = Keyword.get(opts, :actor_user_id, nil)
    anon_voter_key = Keyword.get(opts, :anon_voter_key, nil)
    remote_ip = Keyword.get(opts, :remote_ip, nil)

    with {:ok, reason_type} <- validate_reason_type(reason_type),
         :ok <- validate_reason_free(reason_free),
         {:ok, reporter_voter_key} <- resolve_reporter_key(actor_user_id, anon_voter_key),
         :ok <- check_rate_limit(remote_ip),
         :ok <- validate_target_exists(target_type, target_id) do
      target_uuid = Repo.uuid!(target_id)

      # FIX-4（plan U5）：同人同目标幂等——命中既有行直接返回（不报错、不重复
      # 入队）；唯一索引兜底并发窗口（撞唯一冲突 → 重查返回既有行）。
      case find_existing_report(target_type, target_uuid, reporter_voter_key) do
        %Report{} = existing ->
          {:ok, existing}

        nil ->
          Report
          |> Ash.Changeset.for_create(:create, %{
            target_type: target_type,
            target_id: target_uuid,
            reporter_user_id: actor_user_id && Repo.uuid!(actor_user_id),
            reporter_voter_key: reporter_voter_key,
            reason_type: reason_type,
            reason_free: reason_free,
            status: "pending"
          })
          |> Ash.create(authorize?: false)
          |> case do
            {:ok, report} ->
              {:ok, report}

            # 并发双击：唯一索引冲突 → 落到既有行（幂等语义）
            {:error, %Ash.Error.Invalid{} = error} ->
              if unique_report_conflict?(error) do
                case find_existing_report(target_type, target_uuid, reporter_voter_key) do
                  %Report{} = existing -> {:ok, existing}
                  nil -> {:error, error}
                end
              else
                {:error, error}
              end

            {:error, other} ->
              {:error, other}
          end
      end
    end
  end

  defp find_existing_report(target_type, target_uuid, reporter_voter_key) do
    Report
    |> Ash.Query.filter(
      target_type == ^target_type and target_id == ^target_uuid and
        reporter_voter_key == ^reporter_voter_key
    )
    |> Ash.Query.limit(1)
    |> Ash.read_one(authorize?: false)
    |> case do
      {:ok, nil} -> nil
      {:ok, report} -> report
      _ -> nil
    end
  end

  defp unique_report_conflict?(%Ash.Error.Invalid{errors: errors}) do
    errors
    |> List.wrap()
    |> Enum.any?(fn
      %Ash.Error.Changes.InvalidAttribute{field: :reporter_voter_key} -> true
      %{code: :unique_violation} -> true
      _ -> false
    end)
  end

  # ── Admin ────────────────────────────────────────────────────────────

  @doc """
  admin 隐藏/还原愿望。`hidden?=true` 时**同步**给作者 user 置
  `wishes_review_required_at`（G1 信用字段）。
  解除 `hidden?=false` 只**清 wish.hidden_at**，不动 user credit 字段。
  """
  @spec set_wish_hidden(String.t(), String.t(), boolean()) ::
          {:ok, Wish.t()} | {:error, term()}
  def set_wish_hidden(wish_id, admin_user_id, hidden?) do
    with {:ok, _admin} <- validate_admin(admin_user_id),
         {:ok, wish} <- fetch_wish(wish_id) do
      timestamp = DateTime.utc_now() |> DateTime.truncate(:microsecond)

      Repo.transaction(fn ->
        # 1) 更新 wish.hidden_at
        case wish
             |> Ash.Changeset.for_update(:update, %{
               hidden_at: if(hidden?, do: timestamp, else: nil)
             })
             |> Ash.update(authorize?: false) do
          {:ok, updated} ->
            # 2) 若置 hidden → 给 author.user_id 置 wishes_review_required_at
            if hidden? do
              set_author_credit_required(updated, timestamp)
            end

            updated

          {:error, reason} ->
            Repo.rollback(reason)
        end
      end)
    end
  end

  @doc "作者 user_id 的 wishes_review_required_at 置位（G1 信用字段）"
  @spec set_author_credit_required(Wish.t(), DateTime.t()) ::
          {:ok, User.t()} | {:error, term()} | :noop
  def set_author_credit_required(wish, timestamp) do
    case Repo.query(
           "SELECT user_id FROM flashback_people WHERE id = $1",
           [Repo.uuid!(wish.person_id)]
         ) do
      {:ok, %{rows: [[nil]]}} ->
        :noop

      {:ok, %{rows: [[user_id]]}} ->
        # User resource 无 :update action（ash_authentication 控制）——直接 SQL
        # UPDATE；already-set 不动（credit chronology 保持）。
        {:ok, _} =
          Repo.query(
            """
            UPDATE users SET wishes_review_required_at = $1
            WHERE id = $2 AND wishes_review_required_at IS NULL
            """,
            [timestamp, user_id]
          )

        :noop

      _ ->
        :noop
    end
  end

  @doc "admin 撤销举报：status=dismissed"
  @spec dismiss_report(String.t(), String.t()) :: {:ok, Report.t()} | {:error, term()}
  def dismiss_report(report_id, admin_user_id) do
    with {:ok, _admin} <- validate_admin(admin_user_id),
         {:ok, report} <- fetch_report(report_id) do
      report
      |> Ash.Changeset.for_update(:update, %{
        status: "dismissed",
        acted_at: DateTime.utc_now() |> DateTime.truncate(:microsecond),
        acted_by_user_id: Repo.uuid!(admin_user_id)
      })
      |> Ash.update(authorize?: false)
    end
  end

  @doc "admin 批准举报：status=actioned + 联动 set_wish_hidden(target, admin, true)"
  @spec approve_report(String.t(), String.t()) :: {:ok, Report.t()} | {:error, term()}
  def approve_report(report_id, admin_user_id) do
    with {:ok, _, report} <- fetch_report_and_validate_admin(report_id, admin_user_id),
         {:ok, _hidden_wish} <- set_wish_hidden(report.target_id, admin_user_id, true) do
      report
      |> Ash.Changeset.for_update(:update, %{
        status: "actioned",
        acted_at: DateTime.utc_now() |> DateTime.truncate(:microsecond),
        acted_by_user_id: Repo.uuid!(admin_user_id)
      })
      |> Ash.update(authorize?: false)
    end
  end

  @doc "admin 队列：status=pending 按插入时间正序"
  @spec list_pending_reports() :: list(Report.t())
  def list_pending_reports do
    Report
    |> Ash.Query.filter(status == "pending")
    |> Ash.Query.sort(inserted_at: :asc)
    |> Ash.read!(authorize?: false, page: false)
  end

  @doc """
  「说给主办方听」**收件箱置前**（KTD5）：visibility=private 未删；携作者
  的登录账号 phone/email（仅 admin，**双层断言**：resolver 层 + Ash
  GraphQL `hide` 字段层）。
  """
  @spec list_inbox_private_wishes() :: list(map())
  def list_inbox_private_wishes do
    Wish
    |> Ash.Query.filter(visibility == "private" and is_nil(deleted_at))
    |> Ash.Query.sort(inserted_at: :desc)
    |> Ash.read!(authorize?: false, page: false, load: [:person])
    |> Enum.map(fn wish ->
      user_contact =
        case wish.person.user_id do
          nil ->
            nil

          user_id ->
            case Repo.query(
                   "SELECT phone, email FROM users WHERE id = $1",
                   [Repo.uuid!(user_id)]
                 ) do
              {:ok, %{rows: [[phone, email]]}} -> %{phone: phone, email: email}
              _ -> nil
            end
        end

      %{
        wish: wish,
        wisher_masked: AlumniProjection.masked_name(wish.person),
        # **仅 admin**，GraphQL 公开禁出
        wisher_user_contact: user_contact
      }
    end)
  end

  # FIX-4（KTD9 收口）：公开举报面目标资格 = listed + public + 未 hidden + 未删
  # （plan 允许收口 listed-only——成员面举报入口本批无 UI 消费方）。统一
  # target_not_found：private/未 listed/hidden/不存在同形，不泄露存在性。
  defp validate_target_exists(target_type, target_id) do
    uuid =
      case Ecto.UUID.cast(target_id) do
        {:ok, u} -> u
        _ -> nil
      end

    found =
      case {target_type, uuid} do
        {"wish", id} when is_binary(id) ->
          Wish
          |> Ash.Query.filter(
            id == ^id and visibility == "public" and
              not is_nil(listed_at) and is_nil(hidden_at) and is_nil(deleted_at)
          )
          |> Ash.exists?(authorize?: false)

        _ ->
          false
      end

    if found do
      :ok
    else
      {:error, %{code: "flashback_report_target_not_found", message: "举报目标不存在"}}
    end
  end

  defp validate_reason_type(reason_type) when is_binary(reason_type) do
    if reason_type in Report.reason_types() do
      {:ok, reason_type}
    else
      {:error, %{code: "flashback_report_invalid_reason_type", message: "举报类型不合法"}}
    end
  end

  defp validate_reason_type(_), do: {:error, %{code: "flashback_report_invalid_reason_type"}}

  defp validate_reason_free(nil), do: :ok

  defp validate_reason_free(text) when is_binary(text) do
    trimmed = String.trim(text)

    if String.length(trimmed) > 200 do
      {:error, %{code: "flashback_report_reason_free_too_long", message: "补充 ≤200 字"}}
    else
      :ok
    end
  end

  defp validate_reason_free(_), do: {:error, %{code: "flashback_report_reason_free_too_long"}}

  defp resolve_reporter_key(actor_user_id, _anon) when is_binary(actor_user_id),
    do: {:ok, "u:#{actor_user_id}"}

  defp resolve_reporter_key(nil, anon) when is_binary(anon), do: {:ok, anon}
  defp resolve_reporter_key(nil, nil), do: {:error, %{code: "flashback_invalid_voter_key"}}

  defp check_rate_limit(remote_ip) do
    ip_key =
      Cgc2046Web.Plugs.RateLimit.build_key("rate:flashback-report:ip", remote_ip || "unknown")

    case Cgc2046Web.Plugs.RateLimit.check(ip_key,
           window_seconds: @ip_window_seconds,
           max_attempts: @ip_max_attempts
         ) do
      :ok ->
        :ok

      _ ->
        {:error,
         %{
           code: "flashback_report_rate_limited",
           message: "Too many reports, try later",
           reason: :rate_limited
         }}
    end
  end

  defp validate_admin(user_id) do
    case User
         |> Ash.Query.filter(id == ^Repo.uuid!(user_id))
         |> Ash.read_one(authorize?: false) do
      {:ok, %User{is_platform_admin: true} = admin} ->
        {:ok, admin}

      _ ->
        {:error, %{code: "flashback_auth_required", message: "需要平台管理员身份"}}
    end
  end

  defp fetch_wish(wish_id) do
    Wish
    |> Ash.Query.filter(id == ^Repo.uuid!(wish_id))
    |> Ash.read_one(authorize?: false)
    |> case do
      {:ok, nil} ->
        {:error, %{code: "flashback_wish_not_found"}}

      {:ok, wish} ->
        {:ok, wish}

      err ->
        err
    end
  end

  defp fetch_report(report_id) do
    Report
    |> Ash.Query.filter(id == ^Repo.uuid!(report_id))
    |> Ash.read_one(authorize?: false)
    |> case do
      {:ok, nil} ->
        {:error, %{code: "flashback_report_not_found"}}

      {:ok, report} ->
        {:ok, report}

      err ->
        err
    end
  end

  defp fetch_report_and_validate_admin(report_id, admin_user_id) do
    with {:ok, report} <- fetch_report(report_id),
         {:ok, admin} <- validate_admin(admin_user_id) do
      {:ok, admin, report}
    end
  end
end
