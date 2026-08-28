defmodule Cgc2046.Notifications.Consent do
  @moduledoc "订阅消息授权配额的原子增减接口。"

  @platforms [:wechat, :tt, :xhs]

  def grant(user_id, platform, template_key)
      when platform in @platforms and is_binary(template_key) do
    if template_configured?(platform, template_key) do
      do_grant(user_id, platform, template_key)
    else
      {:error, :template_not_configured}
    end
  end

  def grant(user_id, platform, template_key) when is_binary(platform) do
    case normalize_platform(platform) do
      {:ok, normalized} -> grant(user_id, normalized, template_key)
      error -> error
    end
  end

  defp do_grant(user_id, platform, template_key) do
    sql = """
    INSERT INTO mp_notification_consents
      (id, user_id, platform, template_key, remaining_uses, inserted_at, updated_at)
    VALUES (gen_random_uuid(), $1, $2, $3, 1, NOW(), NOW())
    ON CONFLICT (user_id, platform, template_key)
    DO UPDATE SET remaining_uses = mp_notification_consents.remaining_uses + 1,
                  updated_at = NOW()
    RETURNING remaining_uses
    """

    count_result(
      Cgc2046.Repo.query(sql, [Cgc2046.Repo.uuid!(user_id), to_string(platform), template_key])
    )
  end

  def take(user_id, platform, template_key) when platform in @platforms do
    sql = """
    UPDATE mp_notification_consents
    SET remaining_uses = remaining_uses - 1, updated_at = NOW()
    WHERE user_id = $1 AND platform = $2 AND template_key = $3
      AND remaining_uses > 0
    RETURNING remaining_uses
    """

    case Cgc2046.Repo.query(sql, [Cgc2046.Repo.uuid!(user_id), to_string(platform), template_key]) do
      {:ok, %{rows: [[remaining]]}} -> {:ok, remaining}
      {:ok, %{num_rows: 0}} -> {:error, :consent_exhausted}
      {:error, reason} -> {:error, {:database, reason}}
    end
  end

  def remaining(user_id, platform, template_key) when platform in @platforms do
    sql = """
    SELECT remaining_uses FROM mp_notification_consents
    WHERE user_id = $1 AND platform = $2 AND template_key = $3
    """

    case Cgc2046.Repo.query(sql, [Cgc2046.Repo.uuid!(user_id), to_string(platform), template_key]) do
      {:ok, %{rows: [[remaining]]}} -> {:ok, remaining}
      {:ok, %{rows: []}} -> {:ok, 0}
      {:error, reason} -> {:error, {:database, reason}}
    end
  end

  def refund(user_id, platform, template_key) when platform in @platforms do
    sql = """
    UPDATE mp_notification_consents
    SET remaining_uses = remaining_uses + 1, updated_at = NOW()
    WHERE user_id = $1 AND platform = $2 AND template_key = $3
    RETURNING remaining_uses
    """

    count_result(
      Cgc2046.Repo.query(sql, [Cgc2046.Repo.uuid!(user_id), to_string(platform), template_key])
    )
  end

  defp count_result({:ok, %{rows: [[remaining]]}}), do: {:ok, remaining}
  defp count_result({:error, reason}), do: {:error, {:database, reason}}
  defp normalize_platform("wechat"), do: {:ok, :wechat}
  defp normalize_platform("tt"), do: {:ok, :tt}
  defp normalize_platform("xhs"), do: {:ok, :xhs}
  defp normalize_platform(_), do: {:error, :invalid_platform}

  defp template_configured?(platform, template_key) do
    case get_in(Application.get_env(:cgc_2046, :miniprogram_templates, %{}), [
           platform,
           template_key
         ]) do
      value when is_binary(value) and value != "" -> true
      _ -> false
    end
  end
end
