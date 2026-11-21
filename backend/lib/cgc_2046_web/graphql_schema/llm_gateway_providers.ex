defmodule Cgc2046Web.GraphqlSchema.LlmGatewayProviders do
  @moduledoc """
  LLM Gateway Provider / API Key / 模型目录管理与用户侧可用模型查询 GraphQL 面。
  """

  use Absinthe.Schema.Notation

  import Cgc2046Web.GraphqlSchema.Helpers

  alias Cgc2046.LlmGateway.PricingPresets
  alias Cgc2046.LlmGateway.ProviderCatalog

  object :available_llm_model do
    field(:model_id, non_null(:string))
    field(:display_name, non_null(:string))
    field(:context_window, non_null(:integer))
    field(:max_output_tokens, non_null(:integer))
    field(:supports_thinking, non_null(:boolean))
    field(:supports_tools, non_null(:boolean))
    field(:supports_images, non_null(:boolean))
    field(:reasoning_efforts, non_null(list_of(non_null(:string))))
    field(:input_price_mc, non_null(:bigint))
    field(:cache_hit_price_mc, non_null(:bigint))
    field(:output_price_mc, non_null(:bigint))
  end

  object :admin_llm_provider_api_key do
    field(:id, non_null(:id))
    field(:provider_id, non_null(:id))
    field(:label, non_null(:string))
    field(:key_preview, non_null(:string))
    field(:enabled, non_null(:boolean))
    field(:inserted_at, non_null(:datetime))
  end

  object :admin_llm_provider_model do
    field(:id, non_null(:id))
    field(:provider_id, non_null(:id))
    field(:model_id, non_null(:string))
    field(:upstream_model_id, non_null(:string))
    field(:display_name, non_null(:string))
    field(:enabled, non_null(:boolean))
    field(:context_window, non_null(:integer))
    field(:max_output_tokens, non_null(:integer))
    field(:supports_thinking, non_null(:boolean))
    field(:supports_tools, non_null(:boolean))
    field(:supports_images, non_null(:boolean))
    field(:reasoning_efforts, non_null(list_of(non_null(:string))))
    field(:cache_hit_price_mc, non_null(:bigint))
    field(:cache_miss_price_mc, non_null(:bigint))
    field(:output_price_mc, non_null(:bigint))
    field(:markup_ratio, non_null(:float))
    field(:inserted_at, non_null(:datetime))
  end

  object :admin_llm_provider do
    field(:id, non_null(:id))
    field(:name, non_null(:string))
    field(:slug, non_null(:string))
    field(:protocol, non_null(:string))
    field(:base_url, non_null(:string))
    field(:chat_path, :string)
    field(:models_path, :string)
    field(:priority, non_null(:integer))
    field(:off_peak_discount_enabled, non_null(:boolean))
    field(:enabled, non_null(:boolean))
    field(:api_keys, non_null(list_of(non_null(:admin_llm_provider_api_key))))
    field(:models, non_null(list_of(non_null(:admin_llm_provider_model))))
    field(:inserted_at, non_null(:datetime))
    field(:updated_at, non_null(:datetime))
  end

  object :llm_upstream_discovered_model do
    field(:model_id, non_null(:string))
    field(:upstream_model_id, non_null(:string))
    field(:display_name, non_null(:string))
    field(:context_window, non_null(:integer))
    field(:max_output_tokens, non_null(:integer))
    field(:supports_thinking, non_null(:boolean))
    field(:supports_tools, non_null(:boolean))
    field(:supports_images, non_null(:boolean))
    field(:reasoning_efforts, non_null(list_of(non_null(:string))))
    field(:cache_hit_price_mc, non_null(:bigint))
    field(:cache_miss_price_mc, non_null(:bigint))
    field(:output_price_mc, non_null(:bigint))
    field(:markup_ratio, non_null(:float))
    field(:preset_matched, non_null(:boolean))
  end

  object :llm_model_pricing_preset do
    field(:model_id, non_null(:string))
    field(:display_name, non_null(:string))
    field(:context_window, non_null(:integer))
    field(:max_output_tokens, non_null(:integer))
    field(:supports_thinking, non_null(:boolean))
    field(:supports_tools, non_null(:boolean))
    field(:supports_images, non_null(:boolean))
    field(:reasoning_efforts, non_null(list_of(non_null(:string))))
    field(:cache_hit_price_mc, non_null(:bigint))
    field(:cache_miss_price_mc, non_null(:bigint))
    field(:output_price_mc, non_null(:bigint))
    field(:markup_ratio, non_null(:float))
  end

  input_object :admin_llm_provider_input do
    field(:name, non_null(:string))
    field(:slug, non_null(:string))
    field(:protocol, non_null(:string))
    field(:base_url, non_null(:string))
    field(:chat_path, :string)
    field(:models_path, :string)
    field(:priority, :integer)
    field(:off_peak_discount_enabled, :boolean)
    field(:enabled, :boolean)
  end

  input_object :admin_llm_provider_model_input do
    field(:model_id, non_null(:string))
    field(:upstream_model_id, :string)
    field(:display_name, non_null(:string))
    field(:enabled, :boolean)
    field(:context_window, non_null(:integer))
    field(:max_output_tokens, non_null(:integer))
    field(:supports_thinking, :boolean)
    field(:supports_tools, :boolean)
    field(:supports_images, :boolean)
    field(:reasoning_efforts, list_of(non_null(:string)))
    field(:cache_hit_price_mc, non_null(:bigint))
    field(:cache_miss_price_mc, non_null(:bigint))
    field(:output_price_mc, non_null(:bigint))
    field(:markup_ratio, :float)
  end

  object :llm_gateway_provider_queries do
    @desc "当前登录用户可用的 CGC 官方网关模型列表"
    field :available_llm_models, non_null(list_of(non_null(:available_llm_model))) do
      resolve(fn _, _, %{context: context} ->
        with_actor(context, fn _actor -> {:ok, ProviderCatalog.list_available_models()} end)
      end)
    end

    @desc "PlatformAdmin 读取全部上游 LLM Provider（含脱敏 Key 与模型目录）"
    field :admin_llm_providers, non_null(list_of(non_null(:admin_llm_provider))) do
      resolve(fn _, _, %{context: context} ->
        with_admin(context, fn _actor -> {:ok, ProviderCatalog.list_providers()} end)
      end)
    end

    @desc "PlatformAdmin 读取内置主流模型参考单价与能力预设"
    field :admin_llm_pricing_presets, non_null(list_of(non_null(:llm_model_pricing_preset))) do
      resolve(fn _, _, %{context: context} ->
        with_admin(context, fn _actor -> {:ok, PricingPresets.list_presets()} end)
      end)
    end
  end

  object :llm_gateway_provider_mutations do
    @desc "PlatformAdmin 创建上游 LLM Provider"
    field :admin_create_llm_provider, :admin_llm_provider do
      arg(:input, non_null(:admin_llm_provider_input))

      resolve(fn _, %{input: input}, %{context: context} ->
        with_admin(context, fn actor ->
          ProviderCatalog.create_provider(actor, input) |> map_catalog_result()
        end)
      end)
    end

    @desc "PlatformAdmin 更新上游 LLM Provider"
    field :admin_update_llm_provider, :admin_llm_provider do
      arg(:id, non_null(:id))
      arg(:input, non_null(:admin_llm_provider_input))

      resolve(fn _, %{id: id, input: input}, %{context: context} ->
        with_admin(context, fn actor ->
          ProviderCatalog.update_provider(actor, id, input) |> map_catalog_result()
        end)
      end)
    end

    @desc "PlatformAdmin 删除上游 LLM Provider"
    field :admin_delete_llm_provider, non_null(:boolean) do
      arg(:id, non_null(:id))

      resolve(fn _, %{id: id}, %{context: context} ->
        with_admin(context, fn actor ->
          case ProviderCatalog.delete_provider(actor, id) do
            :ok -> {:ok, true}
            {:error, reason} -> {:error, catalog_error(reason)}
          end
        end)
      end)
    end

    @desc "PlatformAdmin 为 Provider 添加 API Key"
    field :admin_add_llm_provider_api_key, :admin_llm_provider_api_key do
      arg(:provider_id, non_null(:id))
      arg(:label, non_null(:string))
      arg(:api_key, non_null(:string))

      resolve(fn _, args, %{context: context} ->
        with_admin(context, fn actor ->
          ProviderCatalog.add_api_key(actor, args.provider_id, %{
            label: args.label,
            api_key: args.api_key
          })
          |> map_catalog_result()
        end)
      end)
    end

    @desc "PlatformAdmin 更新 Provider API Key 备注或启停状态"
    field :admin_update_llm_provider_api_key, :admin_llm_provider_api_key do
      arg(:id, non_null(:id))
      arg(:label, :string)
      arg(:enabled, :boolean)

      resolve(fn _, args, %{context: context} ->
        with_admin(context, fn actor ->
          attrs =
            %{}
            |> maybe_put(:label, Map.get(args, :label))
            |> maybe_put(:enabled, Map.get(args, :enabled))

          ProviderCatalog.update_api_key(actor, args.id, attrs) |> map_catalog_result()
        end)
      end)
    end

    @desc "PlatformAdmin 删除 Provider API Key"
    field :admin_delete_llm_provider_api_key, non_null(:boolean) do
      arg(:id, non_null(:id))

      resolve(fn _, %{id: id}, %{context: context} ->
        with_admin(context, fn actor ->
          case ProviderCatalog.delete_api_key(actor, id) do
            :ok -> {:ok, true}
            {:error, reason} -> {:error, catalog_error(reason)}
          end
        end)
      end)
    end

    @desc "PlatformAdmin 从上游 Provider 拉取可用模型列表并预填参考单价"
    field :admin_fetch_llm_provider_upstream_models,
          non_null(list_of(non_null(:llm_upstream_discovered_model))) do
      arg(:provider_id, non_null(:id))
      arg(:api_key, :string)

      resolve(fn _, args, %{context: context} ->
        with_admin(context, fn _actor ->
          ProviderCatalog.fetch_upstream_models(args.provider_id, Map.get(args, :api_key))
          |> map_catalog_result()
        end)
      end)
    end

    @desc "PlatformAdmin 批量保存 Provider 下的模型配置与单价"
    field :admin_save_llm_provider_models,
          non_null(list_of(non_null(:admin_llm_provider_model))) do
      arg(:provider_id, non_null(:id))
      arg(:models, non_null(list_of(non_null(:admin_llm_provider_model_input))))

      resolve(fn _, %{provider_id: provider_id, models: models}, %{context: context} ->
        with_admin(context, fn actor ->
          ProviderCatalog.save_provider_models(actor, provider_id, models)
          |> map_catalog_result()
        end)
      end)
    end

    @desc "PlatformAdmin 删除单个模型配置"
    field :admin_delete_llm_provider_model, non_null(:boolean) do
      arg(:id, non_null(:id))

      resolve(fn _, %{id: id}, %{context: context} ->
        with_admin(context, fn actor ->
          case ProviderCatalog.delete_provider_model(actor, id) do
            :ok -> {:ok, true}
            {:error, reason} -> {:error, catalog_error(reason)}
          end
        end)
      end)
    end
  end

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, key, val), do: Map.put(map, key, val)

  defp map_catalog_result({:ok, val}), do: {:ok, val}
  defp map_catalog_result({:error, reason}), do: {:error, catalog_error(reason)}

  defp catalog_error(reason) do
    message =
      case reason do
        :invalid_name -> "Provider 名称不能为空"
        :invalid_slug -> "Slug 仅允许小写字母、数字、连字符或下划线"
        :slug_taken -> "Provider Slug 已存在"
        :invalid_protocol -> "不支持的上游协议（仅支持 openai_compatible 或 anthropic）"
        :invalid_url -> "上游 Base URL 不合法或指向受限内网地址"
        :invalid_priority -> "优先级必须为非负整数"
        :provider_not_found -> "Provider 不存在"
        :key_empty -> "API Key 不能为空"
        :key_label_empty -> "Key 备注名不能为空"
        :key_duplicate -> "该 Provider 下已存在相同的 API Key"
        :key_not_found -> "API Key 不存在"
        :no_active_key -> "该 Provider 尚无启用的 API Key，请先添加或临时传入 Key"
        :upstream_fetch_failed -> "从上游拉取模型列表失败，请检查地址与 API Key"
        :model_invalid -> "模型参数或定价配置无效"
        :model_not_found -> "模型配置不存在"
        _ -> "请求参数无效"
      end

    [message: message, code: ProviderCatalog.error_code(reason)]
  end
end
