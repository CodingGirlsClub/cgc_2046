defmodule Cgc2046Web.AuthIntegrationTest do
  @moduledoc """
  T02 切片A(红→绿):GraphQL signUp/signIn mutation 经真实 HTTP 链路可用。

  验证接缝 1(主)的认证链路:注册/登录走真实 GraphQL 端点,返回 token 与用户。
  """

  use Cgc2046Web.HttpCase, async: true

  @sign_up """
  mutation SignUp($email: String!, $password: String!) {
    signUp(email: $email, password: $password) {
      token
      user {
        id
        email
      }
    }
  }
  """

  @sign_in """
  mutation SignIn($email: String!, $password: String!) {
    signIn(email: $email, password: $password) {
      token
      user {
        id
        email
      }
    }
  }
  """

  test "signUp 注册成功返回 token 与用户" do
    body =
      graphql_query(build_conn(), @sign_up, %{
        "email" => "alice@example.com",
        "password" => "password123"
      })

    assert %{
             "data" => %{
               "signUp" => %{"token" => token, "user" => %{"email" => "alice@example.com"}}
             }
           } = body

    assert is_binary(token) and byte_size(token) > 0
  end

  test "signIn 登录成功返回 token" do
    graphql_query(build_conn(), @sign_up, %{
      "email" => "bob@example.com",
      "password" => "password123"
    })

    body =
      graphql_query(build_conn(), @sign_in, %{
        "email" => "bob@example.com",
        "password" => "password123"
      })

    assert %{"data" => %{"signIn" => %{"token" => token}}} = body
    assert is_binary(token) and byte_size(token) > 0
  end
end
