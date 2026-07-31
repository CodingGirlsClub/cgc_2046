defmodule Cgc2046Web.GraphqlSchema do
  use Absinthe.Schema

  use AshGraphql, domains: [Cgc2046]

  query do
    @desc "Placeholder query until the first resource is added"
    field :ping, :string do
      resolve fn _, _, _ ->
        {:ok, "pong"}
      end
    end
  end

  mutation do
  end
end
