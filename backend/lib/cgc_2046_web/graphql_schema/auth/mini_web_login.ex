defmodule Cgc2046Web.GraphqlSchema.Auth.MiniWebLogin do
  @moduledoc "Protocol-only interface to browser-bound mini-program approval."
  use Absinthe.Schema.Notation
  alias Cgc2046.Accounts.WechatMiniWebLogin, as: Login

  enum :mini_web_login_mode do
    value(:qr)
    value(:link)
  end

  enum :mini_web_login_status do
    value(:pending)
    value(:approved)
    value(:consumed)
    value(:cancelled)
    value(:expired)
  end

  object :mini_web_login_result do
    field(:id, :id)
    field(:request_id, :string)
    field(:status, non_null(:mini_web_login_status))
    field(:expires_at, :datetime)
    field(:poll_interval_seconds, :integer)
    field(:qr_data_url, :string)
    field(:launch_url, :string)
    field(:session_established, :boolean)
  end

  object :mini_web_login_queries do
    field :wechat_mini_web_login_status, :mini_web_login_result do
      arg(:request_id, non_null(:string))
      resolve(fn _, %{request_id: id}, %{context: ctx} -> result(Login.status(id, ctx)) end)
    end

    field :wechat_mini_web_login_preview, :mini_web_login_result do
      arg(:request_id, non_null(:string))
      resolve(fn _, %{request_id: id}, %{context: ctx} -> result(Login.preview(id, ctx)) end)
    end
  end

  object :mini_web_login_mutations do
    field :wechat_mini_web_login_start, :mini_web_login_result do
      arg(:mode, non_null(:mini_web_login_mode))
      resolve(fn _, %{mode: mode}, %{context: ctx} -> result(Login.start(mode, ctx)) end)
      middleware(&__MODULE__.cookie_context/2)
    end

    field :wechat_mini_web_login_confirm, :mini_web_login_result do
      arg(:request_id, non_null(:string))
      resolve(fn _, %{request_id: id}, %{context: ctx} -> result(Login.confirm(id, ctx)) end)
    end

    field :wechat_mini_web_login_consume, :mini_web_login_result do
      arg(:request_id, non_null(:string))
      resolve(fn _, %{request_id: id}, %{context: ctx} -> result(Login.consume(id, ctx)) end)
      middleware(&__MODULE__.cookie_context/2)
    end

    field :wechat_mini_web_login_cancel, :mini_web_login_result do
      arg(:request_id, non_null(:string))
      resolve(fn _, %{request_id: id}, %{context: ctx} -> result(Login.cancel(id, ctx)) end)
    end
  end

  def cookie_context(res, _) do
    case res.value do
      %{__proof__: proof} -> %{res | context: Map.put(res.context, :mini_web_proof_set, proof)}
      %{__token__: token} -> %{res | context: Map.put(res.context, :cgc_auth_token, token)}
      _ -> res
    end
  end

  defp result({:ok, value}), do: {:ok, value}

  defp result({:error, reason}) do
    Login.record_rejection(reason)

    {:error,
     [
       message: "Unable to complete login",
       code: Login.error_code(reason),
       retry_after: if(reason == :rate_limited, do: 60, else: 0)
     ]}
  end
end
