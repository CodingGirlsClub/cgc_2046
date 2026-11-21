defmodule Cgc2046.LlmGateway.ProviderCatalog do
  @moduledoc """
  LLM Gateway 上游 Provider、API Key 与模型目录的管理门面。

  所有写操作在数据库事务内同步落 `AdminActionLog`（绝不记入明文 Key）并即时
  刷新缓存；运行时查询与缓存委托给 `CatalogQueries`。
  """

  import Ecto.Query

  alias Cgc2046.Accounts.AdminActionLog
  alias Cgc2046.LlmGateway.CatalogQueries
  alias Cgc2046.LlmGateway.CatalogValidation, as: V
  alias Cgc2046.LlmGateway.Provider
  alias Cgc2046.LlmGateway.ProviderApiKey
  alias Cgc2046.LlmGateway.ProviderModel
  alias Cgc2046.LlmGateway.SecretBox
  alias Cgc2046.LlmGateway.UpstreamDiscovery
  alias Cgc2046.Repo

  defdelegate ensure_cache_table!, to: CatalogQueries
  defdelegate invalidate_cache!, to: CatalogQueries
  defdelegate cleanup_expired_cache!, to: CatalogQueries, as: :cleanup_expired!
  defdelegate list_available_models, to: CatalogQueries
  defdelegate has_any_active_channel?, to: CatalogQueries
  defdelegate resolve_candidates_for_model(model_id), to: CatalogQueries

  @doc """
  平台管理员读取全部 Provider（含脱敏 Key 预览与已配置模型），按 priority 升序。
  """
  def list_providers do
    Provider
    |> Ash.Query.sort(priority: :asc, inserted_at: :asc)
    |> Ash.Query.load([:api_keys, :models])
    |> Ash.read!(authorize?: false)
    |> Enum.map(&V.project_admin_provider/1)
  end

  @doc """
  创建新 Provider 并同步写入 `AdminActionLog`。
  """
  def create_provider(actor, attrs) when is_map(attrs) do
    with {:ok, validated} <- V.validate_provider_attrs(attrs, :create) do
      case Repo.transaction(fn ->
             changeset = Ash.Changeset.for_create(Provider, :create, validated)

             case Ash.create(changeset, authorize?: false) do
               {:ok, provider} ->
                 log_admin!(actor, :llm_provider_create, :llm_provider, provider.id, %{
                   slug: provider.slug,
                   protocol: provider.protocol,
                   priority: provider.priority,
                   enabled: provider.enabled
                 })

                 provider

               {:error, error} ->
                 Repo.rollback(V.classify_provider_ash_error(error))
             end
           end) do
        {:ok, provider} ->
          invalidate_cache!()
          {:ok, load_admin_provider!(provider.id)}

        {:error, reason} when is_atom(reason) ->
          {:error, reason}

        {:error, error} ->
          {:error, V.classify_provider_ash_error(error)}
      end
    end
  end

  @doc """
  更新 Provider 并同步写入 `AdminActionLog`。
  """
  def update_provider(actor, provider_id, attrs) when is_map(attrs) do
    with {:ok, provider} <- fetch_provider(provider_id),
         {:ok, validated} <- V.validate_provider_attrs(attrs, :update, provider) do
      case Repo.transaction(fn ->
             changeset = Ash.Changeset.for_update(provider, :update, validated)

             case Ash.update(changeset, authorize?: false) do
               {:ok, updated} ->
                 log_admin!(actor, :llm_provider_update, :llm_provider, updated.id, %{
                   slug: updated.slug,
                   protocol: updated.protocol,
                   priority: updated.priority,
                   enabled: updated.enabled
                 })

                 updated

               {:error, error} ->
                 Repo.rollback(V.classify_provider_ash_error(error))
             end
           end) do
        {:ok, updated} ->
          invalidate_cache!()
          {:ok, load_admin_provider!(updated.id)}

        {:error, reason} when is_atom(reason) ->
          {:error, reason}

        {:error, error} ->
          {:error, V.classify_provider_ash_error(error)}
      end
    end
  end

  @doc """
  删除 Provider（级联删除关联 Key 与模型）并写入 `AdminActionLog`。
  """
  def delete_provider(actor, provider_id) do
    with {:ok, provider} <- fetch_provider(provider_id) do
      case Repo.transaction(fn ->
             case Ash.destroy(provider, authorize?: false) do
               :ok ->
                 log_admin!(actor, :llm_provider_delete, :llm_provider, provider.id, %{
                   slug: provider.slug
                 })

                 :ok

               {:error, error} ->
                 Repo.rollback(V.classify_provider_ash_error(error))
             end
           end) do
        {:ok, :ok} ->
          invalidate_cache!()
          :ok

        {:error, reason} ->
          {:error, reason}
      end
    end
  end

  @doc """
  为指定 Provider 添加 API Key（AES-256-GCM 加密存储 + 指纹判重 + 脱敏预览）。
  """
  def add_api_key(actor, provider_id, attrs) when is_map(attrs) do
    raw_key = attrs |> V.map_get(:api_key) |> V.trim_or_empty()
    label = attrs |> V.map_get(:label) |> V.trim_or_empty()
    enabled = V.map_get(attrs, :enabled) != false

    with {:ok, provider} <- fetch_provider(provider_id),
         true <- label != "" || {:error, :key_label_empty},
         true <- raw_key != "" || {:error, :key_empty} do
      fingerprint = SecretBox.fingerprint(raw_key)
      encrypted = SecretBox.encrypt(raw_key)
      preview = SecretBox.mask(raw_key)

      case Repo.transaction(fn ->
             changeset =
               ProviderApiKey
               |> Ash.Changeset.for_create(:create, %{
                 provider_id: provider.id,
                 label: label,
                 enabled: enabled
               })
               |> Ash.Changeset.force_change_attribute(:encrypted_api_key, encrypted)
               |> Ash.Changeset.force_change_attribute(:key_preview, preview)
               |> Ash.Changeset.force_change_attribute(:key_fingerprint, fingerprint)

             case Ash.create(changeset, authorize?: false) do
               {:ok, key_record} ->
                 log_admin!(
                   actor,
                   :llm_provider_api_key_create,
                   :llm_provider_api_key,
                   key_record.id,
                   %{provider_id: provider.id, label: label, key_preview: preview}
                 )

                 key_record

               {:error, error} ->
                 Repo.rollback(V.classify_key_ash_error(error))
             end
           end) do
        {:ok, key_record} ->
          invalidate_cache!()
          {:ok, V.project_admin_key(key_record)}

        {:error, reason} when is_atom(reason) ->
          {:error, reason}

        {:error, error} ->
          {:error, V.classify_key_ash_error(error)}
      end
    else
      {:error, _} = err -> err
    end
  end

  @doc """
  更新 API Key 的备注名或启用状态。
  """
  def update_api_key(actor, key_id, attrs) when is_map(attrs) do
    with {:ok, key_record} <- fetch_api_key(key_id),
         {:ok, updates} <- V.validate_key_update_attrs(attrs) do
      case Repo.transaction(fn ->
             changeset = Ash.Changeset.for_update(key_record, :update, updates)

             case Ash.update(changeset, authorize?: false) do
               {:ok, updated} ->
                 log_admin!(
                   actor,
                   :llm_provider_api_key_update,
                   :llm_provider_api_key,
                   updated.id,
                   %{
                     provider_id: updated.provider_id,
                     label: updated.label,
                     enabled: updated.enabled
                   }
                 )

                 updated

               {:error, _error} ->
                 Repo.rollback(:key_not_found)
             end
           end) do
        {:ok, updated} ->
          invalidate_cache!()
          {:ok, V.project_admin_key(updated)}

        {:error, reason} ->
          {:error, reason}
      end
    end
  end

  @doc """
  删除 API Key 并写入 `AdminActionLog`。
  """
  def delete_api_key(actor, key_id) do
    with {:ok, key_record} <- fetch_api_key(key_id) do
      case Repo.transaction(fn ->
             case Ash.destroy(key_record, authorize?: false) do
               :ok ->
                 log_admin!(
                   actor,
                   :llm_provider_api_key_delete,
                   :llm_provider_api_key,
                   key_record.id,
                   %{provider_id: key_record.provider_id, key_preview: key_record.key_preview}
                 )

                 :ok

               {:error, _} ->
                 Repo.rollback(:key_not_found)
             end
           end) do
        {:ok, :ok} ->
          invalidate_cache!()
          :ok

        {:error, reason} ->
          {:error, reason}
      end
    end
  end

  @doc """
  调上游 `/models` 拉取候选模型，并结合预设表预填单价与能力。
  """
  def fetch_upstream_models(provider_id, override_api_key \\ nil, opts \\ []) do
    with {:ok, provider} <- fetch_provider(provider_id),
         {:ok, plaintext_key} <- resolve_discovery_key(provider.id, override_api_key) do
      case UpstreamDiscovery.fetch_models(provider, plaintext_key, opts) do
        {:ok, models} -> {:ok, models}
        {:error, :invalid_url} -> {:error, :invalid_url}
        {:error, _reason} -> {:error, :upstream_fetch_failed}
      end
    end
  end

  @doc """
  批量 upsert 指定 Provider 下的模型目录与单价配置。
  """
  def save_provider_models(actor, provider_id, models_attrs) when is_list(models_attrs) do
    with {:ok, provider} <- fetch_provider(provider_id),
         {:ok, validated_list} <- V.validate_models_batch(models_attrs) do
      case Repo.transaction(fn ->
             saved =
               Enum.map(validated_list, fn model_attrs ->
                 attrs_with_provider = Map.put(model_attrs, :provider_id, provider.id)
                 changeset = Ash.Changeset.for_create(ProviderModel, :create, attrs_with_provider)

                 case Ash.create(changeset, authorize?: false) do
                   {:ok, record} -> record
                   {:error, _} -> Repo.rollback(:model_invalid)
                 end
               end)

             log_admin!(actor, :llm_provider_model_upsert, :llm_provider, provider.id, %{
               provider_slug: provider.slug,
               model_ids: Enum.map(saved, & &1.model_id)
             })

             saved
           end) do
        {:ok, saved} ->
          invalidate_cache!()
          {:ok, Enum.map(saved, &V.project_admin_model/1)}

        {:error, reason} ->
          {:error, reason}
      end
    end
  end

  @doc """
  删除单个 ProviderModel 并写入 `AdminActionLog`。
  """
  def delete_provider_model(actor, model_record_id) do
    with {:ok, model_record} <- fetch_provider_model(model_record_id) do
      case Repo.transaction(fn ->
             case Ash.destroy(model_record, authorize?: false) do
               :ok ->
                 log_admin!(
                   actor,
                   :llm_provider_model_delete,
                   :llm_provider_model,
                   model_record.id,
                   %{provider_id: model_record.provider_id, model_id: model_record.model_id}
                 )

                 :ok

               {:error, _} ->
                 Repo.rollback(:model_not_found)
             end
           end) do
        {:ok, :ok} ->
          invalidate_cache!()
          :ok

        {:error, reason} ->
          {:error, reason}
      end
    end
  end

  @doc """
  将 domain 错误 atom 映射为稳定 `error_code` 字符串。
  """
  @spec error_code(atom()) :: String.t()
  def error_code(reason), do: domain_error_code(reason)

  defp domain_error_code(:invalid_name), do: "llm_provider_invalid_name"
  defp domain_error_code(:invalid_slug), do: "llm_provider_invalid_slug"
  defp domain_error_code(:slug_taken), do: "llm_provider_slug_taken"
  defp domain_error_code(:invalid_protocol), do: "llm_provider_invalid_protocol"
  defp domain_error_code(:invalid_url), do: "llm_provider_invalid_url"
  defp domain_error_code(:invalid_priority), do: "llm_provider_invalid_priority"
  defp domain_error_code(:provider_not_found), do: "llm_provider_not_found"
  defp domain_error_code(:key_empty), do: "llm_provider_key_empty"
  defp domain_error_code(:key_label_empty), do: "llm_provider_key_label_empty"
  defp domain_error_code(:key_duplicate), do: "llm_provider_key_duplicate"
  defp domain_error_code(:key_not_found), do: "llm_provider_key_not_found"
  defp domain_error_code(:no_active_key), do: "llm_provider_no_active_key"
  defp domain_error_code(:upstream_fetch_failed), do: "llm_provider_upstream_fetch_failed"
  defp domain_error_code(:model_invalid), do: "llm_provider_model_invalid"
  defp domain_error_code(:model_not_found), do: "llm_provider_model_not_found"
  defp domain_error_code(_other), do: "llm_provider_invalid_request"

  defp fetch_provider(id) when is_binary(id) do
    with {:ok, uuid} <- Ecto.UUID.cast(id),
         {:ok, provider} <- Ash.get(Provider, uuid, authorize?: false),
         false <- is_nil(provider) do
      {:ok, provider}
    else
      _ -> {:error, :provider_not_found}
    end
  end

  defp fetch_provider(_), do: {:error, :provider_not_found}

  defp load_admin_provider!(id) do
    Provider
    |> Ash.get!(id, load: [:api_keys, :models], authorize?: false)
    |> V.project_admin_provider()
  end

  defp fetch_api_key(id) when is_binary(id) do
    with {:ok, uuid} <- Ecto.UUID.cast(id),
         {:ok, key_record} <- Ash.get(ProviderApiKey, uuid, authorize?: false),
         false <- is_nil(key_record) do
      {:ok, key_record}
    else
      _ -> {:error, :key_not_found}
    end
  end

  defp fetch_api_key(_), do: {:error, :key_not_found}

  defp fetch_provider_model(id) when is_binary(id) do
    with {:ok, uuid} <- Ecto.UUID.cast(id),
         {:ok, model_record} <- Ash.get(ProviderModel, uuid, authorize?: false),
         false <- is_nil(model_record) do
      {:ok, model_record}
    else
      _ -> {:error, :model_not_found}
    end
  end

  defp fetch_provider_model(_), do: {:error, :model_not_found}

  @doc """
  把仍用 `secret_key_base` 回落密钥加密的上游 API Key 重加密为独立主密钥。

  独立主密钥上线后旧密文仍能解密（`SecretBox.decrypt_with_source/1` 会尝试两把
  密钥），但轮换 `secret_key_base` 会让它们失效，因此需尽早执行本函数。
  无法解密的行原样保留并计入 `failed`，需管理员重录。

  ## 用法

      mix cgc2046.reencrypt_llm_keys
  """
  @spec reencrypt_api_keys() ::
          {:ok, %{reencrypted: non_neg_integer(), failed: non_neg_integer()}}
          | {:error, :primary_key_missing}
  def reencrypt_api_keys do
    if SecretBox.primary_configured?() do
      result = Repo.transaction(fn -> do_reencrypt_api_keys() end)
      invalidate_cache!()
      result
    else
      {:error, :primary_key_missing}
    end
  end

  defp do_reencrypt_api_keys do
    from(k in "llm_provider_api_keys", select: {type(k.id, Ecto.UUID), k.encrypted_api_key})
    |> Repo.all()
    |> Enum.reduce(%{reencrypted: 0, failed: 0}, fn {id, ciphertext}, acc ->
      case SecretBox.decrypt_with_source(ciphertext) do
        {:ok, _plaintext, :primary} ->
          acc

        {:ok, plaintext, :fallback} ->
          from(k in "llm_provider_api_keys", where: k.id == type(^id, Ecto.UUID))
          |> Repo.update_all(
            set: [encrypted_api_key: SecretBox.encrypt(plaintext), updated_at: DateTime.utc_now()]
          )

          %{acc | reencrypted: acc.reencrypted + 1}

        {:error, :decryption_failed} ->
          %{acc | failed: acc.failed + 1}
      end
    end)
  end

  defp resolve_discovery_key(_provider_id, raw_key)
       when is_binary(raw_key) and byte_size(raw_key) > 0 do
    trimmed = String.trim(raw_key)
    if trimmed != "", do: {:ok, trimmed}, else: {:error, :no_active_key}
  end

  defp resolve_discovery_key(provider_id, _override) do
    query =
      from(k in "llm_provider_api_keys",
        where: k.provider_id == type(^provider_id, Ecto.UUID) and k.enabled == true,
        order_by: [asc: k.inserted_at],
        limit: 1,
        select: k.encrypted_api_key
      )

    case Repo.one(query) do
      nil -> {:error, :no_active_key}
      encrypted -> SecretBox.decrypt(encrypted)
    end
  end

  defp log_admin!(actor, action, target_type, target_id, metadata) do
    actor_id =
      case actor do
        %{id: id} -> id
        _ -> nil
      end

    AdminActionLog.log!(%{
      actor_id: actor_id,
      action: action,
      target_type: target_type,
      target_id: target_id,
      metadata: metadata
    })
  end
end
