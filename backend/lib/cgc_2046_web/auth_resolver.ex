defmodule Cgc2046Web.AuthResolver do
  @moduledoc """
  认证 mutation(signUp/signIn)的 resolver。

  ash_authentication 4.x 不提供内置 GraphQL 集成,这里显式调用
  Password strategy 的动作与 JWT 签发,返回 `%{token:, user:}`。

  错误统一折叠成 `{:error, message}`(Absinthe 渲染为 field error)。
  """

  alias AshAuthentication.{Info, Jwt}
  alias AshAuthentication.Strategy.Password
  alias AshAuthentication.Strategy.Password.Actions

  @spec sign_up(map, map) :: {:ok, map} | {:error, String.t()}
  def sign_up(%{email: email, password: password}, _resolution) do
    with {:ok, strategy} <- password_strategy(),
         {:ok, user} <-
           Actions.register(
             strategy,
             %{"email" => email, "password" => password, "password_confirmation" => password},
             []
           ),
         {:ok, token, _claims} <- Jwt.token_for_user(user) do
      {:ok, %{token: token, user: user}}
    else
      {:error, error} -> {:error, error_message(error)}
    end
  end

  @spec sign_in(map, map) :: {:ok, map} | {:error, String.t()}
  def sign_in(%{email: email, password: password}, _resolution) do
    with {:ok, strategy} <- password_strategy(),
         {:ok, user} <-
           Actions.sign_in(strategy, %{"email" => email, "password" => password}, []),
         {:ok, token, _claims} <- Jwt.token_for_user(user) do
      {:ok, %{token: token, user: user}}
    else
      {:error, error} -> {:error, error_message(error)}
    end
  end

  defp password_strategy do
    case Info.strategy(Cgc2046.Accounts.User, :password) do
      {:ok, %Password{} = strategy} -> {:ok, strategy}
      :error -> {:error, "password strategy is not configured on the user resource"}
    end
  end

  defp error_message(%{message: message}) when is_binary(message), do: message
  defp error_message(%{errors: [%{message: message} | _]}), do: message
  defp error_message(message) when is_binary(message), do: message
  defp error_message(_), do: "authentication failed"
end
