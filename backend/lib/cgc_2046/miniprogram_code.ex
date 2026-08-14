defmodule Cgc2046.MiniprogramCode do
  @moduledoc """
  Workspace Invitation → 平台小程序码服务。

  scene 是 128-bit 随机 Base32（只含字母数字、26 字符）；扫码时 scene 作为 bearer
  proof 映射到 Invitation。平台每日生成配额由 Postgres 条件 UPSERT 原子计数，缓存
  命中不重复请求平台。
  """

  require Ash.Query

  alias Cgc2046.Accounts.{Invitation, MembershipContext, Role}
  alias Cgc2046.Miniprogram.Client
  alias Cgc2046.Miniprogram.Code

  @scene_regex ~r/^[A-Za-z0-9_]{1,32}$/
  @default_expiry_days 7

  @spec generate(String.t(), term(), atom(), keyword()) :: {:ok, map()} | {:error, term()}
  def generate(workspace_id, actor, platform, opts \\ []) do
    with :ok <- authorize_generator(actor, workspace_id),
         {:ok, platform} <- normalize_platform(platform) do
      Cgc2046.Repo.transaction(fn ->
        with {:ok, invitation} <- create_invitation(workspace_id, actor, opts),
             {:ok, code} <- generate_for_invitation(invitation, platform) do
          %{
            invitation_id: invitation.id,
            platform: to_string(code.platform),
            scene: code.scene,
            code_base64: Base.encode64(code.code),
            expires_at: code.expires_at
          }
        else
          {:error, reason} -> Cgc2046.Repo.rollback(reason)
        end
      end)
    end
    |> case do
      {:ok, result} -> {:ok, result}
      {:error, reason} -> {:error, reason}
    end
  end

  @spec generate_for_invitation(Invitation.t(), atom()) :: {:ok, Code.t()} | {:error, term()}
  def generate_for_invitation(%Invitation{} = invitation, platform) do
    with :ok <- active_invitation?(invitation),
         {:ok, platform} <- normalize_platform(platform) do
      Cgc2046.Repo.transaction(fn ->
        lock_code_generation(invitation.id, platform)

        case cached(invitation.id, platform) do
          {:ok, %Code{} = code} ->
            code

          {:ok, nil} ->
            with :ok <- consume_daily_quota(platform),
                 scene = new_scene(),
                 {:ok, bytes} <- Client.generate_code(platform, scene),
                 {:ok, code} <- persist_code(invitation, platform, scene, bytes) do
              code
            else
              {:error, reason} -> Cgc2046.Repo.rollback(reason)
            end

          {:error, reason} ->
            Cgc2046.Repo.rollback(reason)
        end
      end)
    end
    |> case do
      {:ok, %Code{} = code} -> {:ok, code}
      {:error, reason} -> {:error, reason}
    end
  end

  @spec valid_scene?(term()) :: boolean()
  def valid_scene?(scene), do: is_binary(scene) and Regex.match?(@scene_regex, scene)

  @spec code_for_scene(String.t()) :: {:ok, Code.t()} | {:error, term()}
  def code_for_scene(scene) do
    if valid_scene?(scene) do
      Code
      |> Ash.Query.filter(scene == ^scene and expires_at > ^DateTime.utc_now())
      |> Ash.read_one(authorize?: false)
      |> case do
        {:ok, %Code{} = code} -> {:ok, code}
        {:ok, nil} -> {:error, :invalid_or_expired_scene}
        {:error, reason} -> {:error, reason}
      end
    else
      {:error, :invalid_scene}
    end
  end

  defp authorize_generator(actor, workspace_id) do
    roles = MembershipContext.role_names(actor, workspace_id)

    if Enum.any?(roles, &Role.manage_role?/1) do
      :ok
    else
      {:error, :forbidden}
    end
  end

  defp create_invitation(workspace_id, actor, opts) do
    expires_at =
      Keyword.get(opts, :expires_at, DateTime.add(DateTime.utc_now(), @default_expiry_days, :day))

    role_names = Keyword.get(opts, :preauthorized_role_names, [:member])

    Invitation
    |> Ash.Changeset.for_create(:create, %{
      workspace_id: workspace_id,
      inviter_id: actor.id,
      expires_at: expires_at,
      preauthorized_role_names: role_names
    })
    |> Ash.create(actor: actor)
  end

  defp cached(invitation_id, platform) do
    Code
    |> Ash.Query.filter(
      invitation_id == ^invitation_id and platform == ^platform and
        expires_at > ^DateTime.utc_now()
    )
    |> Ash.read_one(authorize?: false)
  end

  defp persist_code(invitation, platform, scene, bytes) do
    expires_at =
      invitation.expires_at || DateTime.add(DateTime.utc_now(), @default_expiry_days, :day)

    Code
    |> Ash.Changeset.for_create(:create, %{
      invitation_id: invitation.id,
      platform: platform,
      scene: scene,
      code: bytes,
      expires_at: expires_at
    })
    |> Ash.create(tenant: invitation.workspace_id, authorize?: false)
  end

  defp consume_daily_quota(platform) do
    limit = Application.get_env(:cgc_2046, :miniprogram_code_daily_limit, 100_000)

    sql = """
    INSERT INTO miniprogram_code_daily_quotas (platform, quota_date, used)
    VALUES ($1, CURRENT_DATE, 1)
    ON CONFLICT (platform, quota_date)
    DO UPDATE SET used = miniprogram_code_daily_quotas.used + 1
    WHERE miniprogram_code_daily_quotas.used < $2
    RETURNING used
    """

    case Cgc2046.Repo.query(sql, [to_string(platform), limit]) do
      {:ok, %{num_rows: 1}} -> :ok
      {:ok, %{num_rows: 0}} -> {:error, :daily_quota_exhausted}
      {:error, reason} -> {:error, {:database, reason}}
    end
  end

  defp lock_code_generation(invitation_id, platform) do
    key = "#{invitation_id}:#{platform}"
    # PR-I D1：hashtextextended($1, 0) 键域与 workspace 锁分离，显式传 hash 选项
    # （误换 hashtext 会碰撞/漂移）；新增 lock_timeout 5s + 友好错误映射（D5）。
    Cgc2046.Repo.acquire_lock!(key, hash: :hashtextextended)
    :ok
  end

  defp normalize_platform(platform) when platform in [:wechat, :tt, :xhs], do: {:ok, platform}
  defp normalize_platform("wechat"), do: {:ok, :wechat}
  defp normalize_platform("tt"), do: {:ok, :tt}
  defp normalize_platform("xhs"), do: {:ok, :xhs}
  defp normalize_platform(_), do: {:error, :invalid_platform}

  defp active_invitation?(%Invitation{status: :active, expires_at: nil}), do: :ok

  defp active_invitation?(%Invitation{status: :active, expires_at: expires_at}) do
    if DateTime.compare(expires_at, DateTime.utc_now()) == :gt,
      do: :ok,
      else: {:error, :invitation_expired}
  end

  defp active_invitation?(_), do: {:error, :invitation_not_active}

  defp new_scene do
    16
    |> :crypto.strong_rand_bytes()
    |> Base.encode32(padding: false)
  end
end
