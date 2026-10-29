defmodule Cgc2046.Accounts.UserAdminTest do
  @moduledoc """
  AshAdmin User 暴露面：ops 需在 /admin/users 看到用户手机号（联系用户），
  故 phone 豁免于 sensitive 遮罩；hashed_password 仍永不展示。
  """

  use ExUnit.Case, async: true

  alias Cgc2046.Accounts.User

  test "admin 列表列含 phone" do
    assert :phone in AshAdmin.Resource.table_columns(User)
  end

  test "phone 豁免 sensitive 遮罩（列表/详情/表单直接显示明文）" do
    assert :phone in AshAdmin.Resource.show_sensitive_fields(User)
  end

  test "hashed_password 仍被遮罩" do
    refute :hashed_password in AshAdmin.Resource.show_sensitive_fields(User)
  end
end
