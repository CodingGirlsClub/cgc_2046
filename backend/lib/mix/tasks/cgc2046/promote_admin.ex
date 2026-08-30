defmodule Mix.Tasks.Cgc2046.PromoteAdmin do
  @shortdoc "Set is_platform_admin = true on an existing user (R2 bootstrap)"

  @moduledoc """
  平台管理员 bootstrap CLI task（R2）。

  为已存在的用户设置 `is_platform_admin = true`，用于在没有 admin UI 时
  bootstrap 第一个 platform admin。

  `is_platform_admin` attribute 为 `writable?: false`，普通 update action
  无法修改；本 task 调用专用 `set_platform_admin` action（`force_change_attribute`
  绕过），并以 `authorize?: false` 执行（CLI 无 actor）。

  ## 用法

      mix cgc2046.promote_admin alice@example.com

  ## 退出码

  - 0: 成功
  - 1: 用户未找到 / 更新失败
  """

  use Mix.Task

  alias Cgc2046.Accounts.User

  @impl true
  def run([]) do
    Mix.raise("Usage: mix cgc2046.promote_admin <email>")
  end

  def run([email]) do
    Mix.Task.run("app.start", [])

    require Ash.Query

    user =
      User
      |> Ash.Query.filter(email == ^email)
      |> Ash.read_one!(authorize?: false, domain: Cgc2046.Accounts)

    if user do
      {:ok, updated} =
        user
        |> Ash.Changeset.for_update(:set_platform_admin, %{is_platform_admin: true},
          authorize?: false,
          domain: Cgc2046.Accounts
        )
        |> Ash.update()

      Mix.shell().info("Promoted #{updated.email || "(no email)"} to platform admin")
    else
      Mix.raise("User not found: #{email}")
    end
  end

  def run(_args) do
    Mix.raise("Usage: mix cgc2046.promote_admin <email>")
  end
end
