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

  @doc """
  admin 放行待审愿望 = 挂树（#817）：`listed_at` 置位 + `hidden_at` 清空。

  授权不变量（红线）：仅 `listing_consent_at` 非空（作者创建时授权挂树）的
  公开未删愿望可放行；无授权证据 → `flashback_wish_listing_not_authorized`
  拒绝（同码不泄露具体原因）。已挂树（listed_at 非空）幂等返回当前行
  （并发双击兜底）。**不动**作者信用字段（放行不清信用，与 set_wish_hidden
  语义一致；信用解除走独立流程）。
  """
  @spec approve_wish_listing(String.t(), String.t()) ::
          {:ok, Wish.t()} | {:error, term()}
  def approve_wish_listing(wish_id, admin_user_id) do
    with {:ok, _admin} <- validate_admin(admin_user_id),
         {:ok, wish} <- fetch_wish(wish_id) do
      cond do
        not is_nil(wish.listed_at) ->
          {:ok, wish}

        is_nil(wish.listing_consent_at) or wish.visibility != "public" or
            not is_nil(wish.deleted_at) ->
          {:error,
           %{
             code: "flashback_wish_listing_not_authorized",
             message: "该愿望无有效挂树授权，不能放行"
           }}

        true ->
          now = DateTime.utc_now() |> DateTime.truncate(:microsecond)

          wish
          |> Ash.Changeset.for_update(:update, %{listed_at: now, hidden_at: nil})
          |> Ash.update(authorize?: false)
      end
    end
  end

  @doc "作者 user_id 的 wishes_review_required_at 置位（G1 信用字段）"
  @spec set_author_credit_required(Wish.t(), DateTime.t()) ::
          {:ok, User.t()} | {:error, term()} | :noop
  def set_author_credit_required(wish, timestamp) do
    case Cgc2046.Flashback.WishAuthors.user_id(wish) do
      nil ->
        :noop

      user_id ->
        Repo.query!(
          "UPDATE users SET wishes_review_required_at=$1 WHERE id=$2 AND wishes_review_required_at IS NULL",
          [timestamp, Repo.uuid!(user_id)]
        )

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
        case Cgc2046.Flashback.WishAuthors.user_id(wish) do
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
        wisher_masked: if(wish.person, do: AlumniProjection.masked_name(wish.person), else: "匿名"),
        # **仅 admin**，GraphQL 公开禁出
        wisher_user_contact: user_contact
      }
    end)
  end

  @doc """
  回响管理队列（#835）：公开树可见愿望（listed + public + 未 hidden + 未删）
  按挂树时间倒序，附每个愿望的回响计数（published_ed = published+corrected 公开
  可见数；draft = 仅 admin 可见）。
  """
  @spec list_listed_wishes() :: list(map())
  def list_listed_wishes do
    Wish
    |> Ash.Query.filter(
      visibility == "public" and not is_nil(listed_at) and is_nil(hidden_at) and
        is_nil(deleted_at)
    )
    |> Ash.Query.sort(listed_at: :desc)
    |> Ash.read!(authorize?: false, page: false)
    |> Enum.map(fn wish ->
      %{rows: rows} =
        Repo.query!(
          """
          SELECT
            COUNT(*) FILTER (WHERE status IN ('published', 'corrected')),
            COUNT(*) FILTER (WHERE status = 'draft')
          FROM flashback_wish_echoes
          WHERE wish_id = $1
          """,
          [Repo.uuid!(wish.id)]
        )

      {published_echo_count, draft_echo_count} =
        case rows do
          [[published_count, draft_count]] -> {published_count, draft_count}
          _ -> {0, 0}
        end

      %{
        wish_id: wish.id,
        content: wish.content,
        signature: wish.signature,
        city: wish.city,
        listed_at: wish.listed_at,
        published_echo_count: published_echo_count,
        draft_echo_count: draft_echo_count
      }
    end)
  end

  @doc """
  #817 admin 巡检：作者已授权挂树（listing_consent_at 非空）的公开愿望。
  待审置前（hidden_at 升序）→ 已下架（listed+hidden）→ 已挂树
  （listed_at 倒序）。三态标记 listed / pending_review / hidden——admin 面
  派生口径，与 `Wishes.listing_status/2` 公开三态区分（后者把「已挂树后
  下架」归入 listed，且不含本投影的授权门槛）。`author_credit_reduced` =
  作者 user 的 `wishes_review_required_at` 置位（person-only 作者恒 false）。
  """
  @spec list_public_wishes_for_admin(non_neg_integer() | nil) :: list(map())
  def list_public_wishes_for_admin(limit \\ nil) do
    limit = clamp_limit(limit, 50, 200)

    %{rows: rows} =
      Repo.query!(
        """
        SELECT w.id, w.content, w.signature, w.city, w.inserted_at, w.listed_at, w.hidden_at,
               (u.wishes_review_required_at IS NOT NULL) AS author_credit_reduced,
               (SELECT COUNT(*) FROM flashback_wish_expectations e WHERE e.wish_id = w.id),
               (SELECT COUNT(*) FROM flashback_wish_endorsements en WHERE en.wish_id = w.id)
        FROM flashback_wishes w
        LEFT JOIN users u ON u.id = w.user_id
        WHERE w.visibility = 'public'
          AND w.deleted_at IS NULL
          AND w.listing_consent_at IS NOT NULL
        ORDER BY
          CASE
            WHEN w.listed_at IS NULL AND w.hidden_at IS NOT NULL THEN 0
            WHEN w.listed_at IS NOT NULL AND w.hidden_at IS NOT NULL THEN 1
            ELSE 2
          END,
          w.hidden_at ASC NULLS LAST,
          w.listed_at DESC NULLS LAST,
          w.inserted_at DESC
        LIMIT $1
        """,
        [limit]
      )

    Enum.map(rows, fn [
                        id,
                        content,
                        signature,
                        city,
                        inserted_at,
                        listed_at,
                        hidden_at,
                        credit_reduced,
                        expectation_count,
                        endorsement_count
                      ] ->
      %{
        wish_id: Ecto.UUID.load!(id),
        content: content,
        signature: signature,
        city: city,
        inserted_at: DateTime.from_naive!(inserted_at, "Etc/UTC"),
        listed_at: naive_to_utc(listed_at),
        hidden_at: naive_to_utc(hidden_at),
        status: admin_listing_status(listed_at, hidden_at),
        author_credit_reduced: credit_reduced || false,
        expectation_count: expectation_count || 0,
        endorsement_count: endorsement_count || 0
      }
    end)
  end

  @doc """
  #817 admin 附议留言聚合：有附议的未删愿望，按最新附议时间倒序取前 `limit`
  个；明细（类型/留言/时间/附议者登录账号 phone/email）按提交时间正序。
  `user_id IS NULL`（存量 token 附议）联系方式为 nil，**不回退档案私有字段**
  （KTD5：phone/email 仅 admin，公开响应禁出——双层断言钉住）。
  """
  @spec list_wish_endorsements_for_admin(non_neg_integer() | nil) :: list(map())
  def list_wish_endorsements_for_admin(limit \\ nil) do
    limit = clamp_limit(limit, 50, 100)

    %{rows: wish_rows} =
      Repo.query!(
        """
        SELECT w.id, w.content, w.signature, w.city, w.listed_at,
               (SELECT MAX(en.inserted_at) FROM flashback_wish_endorsements en WHERE en.wish_id = w.id),
               (SELECT COUNT(*) FROM flashback_wish_endorsements en WHERE en.wish_id = w.id)
        FROM flashback_wishes w
        WHERE w.deleted_at IS NULL
          AND EXISTS (
            SELECT 1 FROM flashback_wish_endorsements en WHERE en.wish_id = w.id
          )
        ORDER BY 6 DESC
        LIMIT $1
        """,
        [limit]
      )

    wishes =
      Map.new(wish_rows, fn [id, content, signature, city, listed_at, _last, _count] ->
        {id,
         %{
           wish_id: Ecto.UUID.load!(id),
           content: content,
           signature: signature,
           city: city,
           listed_at: naive_to_utc(listed_at),
           endorsement_count: 0,
           contribution_distribution: %{},
           endorsements: []
         }}
      end)

    ids = Enum.map(wish_rows, &hd/1)

    grouped =
      if ids == [] do
        []
      else
        {:ok, %{rows: detail_rows}} =
          Repo.query(
            """
            SELECT en.wish_id, en.id, en.contribution_types, en.message, en.inserted_at,
                   u.phone, u.email
            FROM flashback_wish_endorsements en
            LEFT JOIN users u ON u.id = en.user_id
            WHERE en.wish_id = ANY($1)
            ORDER BY en.inserted_at ASC
            """,
            [ids]
          )

        detail_rows
      end
      |> Enum.reduce(wishes, fn [
                                  wish_uuid,
                                  id,
                                  contribution_types,
                                  message,
                                  inserted_at,
                                  phone,
                                  email
                                ],
                                acc ->
        entry = %{
          id: Ecto.UUID.load!(id),
          contribution_types: contribution_types || [],
          message: message,
          inserted_at: DateTime.from_naive!(inserted_at, "Etc/UTC"),
          endorser_phone: phone,
          endorser_email: email
        }

        Map.update!(acc, wish_uuid, fn wish ->
          %{
            wish
            | endorsement_count: wish.endorsement_count + 1,
              contribution_distribution:
                Enum.reduce(entry.contribution_types, wish.contribution_distribution, fn type,
                                                                                         dist ->
                  Map.update(dist, type, 1, &(&1 + 1))
                end),
              endorsements: wish.endorsements ++ [entry]
          }
        end)
      end)

    # 按 SQL 返回顺序（最新附议倒序）输出；分布 map → 稳定序 list
    Enum.map(ids, fn id ->
      wish = Map.fetch!(grouped, id)
      %{wish | contribution_distribution: distribution_list(wish.contribution_distribution)}
    end)
  end

  # admin 巡检三态：listed（挂树可见）/ pending_review（未挂树待审）/
  # hidden（挂树后被下架）。未授权（listing_consent_at nil）不进巡检面。
  defp admin_listing_status(listed_at, hidden_at)
       when is_nil(listed_at) and not is_nil(hidden_at),
       do: "pending_review"

  defp admin_listing_status(listed_at, hidden_at)
       when not is_nil(listed_at) and not is_nil(hidden_at),
       do: "hidden"

  defp admin_listing_status(_listed_at, _hidden_at), do: "listed"

  # 输出类型固定序（与表单/校验枚举一致），未知类型（历史数据）按字典序垫后
  @contribution_type_order ~w(venue organize speak sponsor other)

  defp distribution_list(dist) do
    unknown = dist |> Map.keys() |> Enum.reject(&(&1 in @contribution_type_order)) |> Enum.sort()

    Enum.map(@contribution_type_order ++ unknown, fn type ->
      case dist do
        %{^type => count} -> %{type: type, count: count}
        _ -> nil
      end
    end)
    |> Enum.reject(&is_nil/1)
  end

  # limit clamp（先例：WishPublic.wishes/1）——nil 取默认，越界收拢
  defp clamp_limit(nil, default, _max), do: default

  defp clamp_limit(limit, _default, max) when is_integer(limit),
    do: limit |> max(1) |> min(max)

  defp clamp_limit(_other, default, _max), do: default

  defp naive_to_utc(nil), do: nil

  defp naive_to_utc(naive), do: DateTime.from_naive!(naive, "Etc/UTC")

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
