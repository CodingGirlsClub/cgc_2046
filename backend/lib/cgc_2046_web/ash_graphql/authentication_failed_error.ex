defimpl AshGraphql.Error, for: AshAuthentication.Errors.AuthenticationFailed do
  def to_error(error) do
    %{
      message: "Invalid email or password",
      short_message: "invalid_credentials",
      code: "authentication_failed",
      vars: Map.new(error.vars || []),
      fields: []
    }
  end
end
