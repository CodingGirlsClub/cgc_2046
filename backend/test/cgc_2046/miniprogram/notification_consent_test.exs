defmodule Cgc2046.Miniprogram.NotificationConsentTest do
  @moduledoc """
  #209 fail-closed：授权余额资源 read 仅 platform_admin。

  行写入经 `Cgc2046.Notifications.Consent` 原始 SQL（grant，不经 Ash action），
  这里只验授权面：member/nil actor Forbidden，platform_admin 放行。
  """
  use Cgc2046.DataCase, async: true

  alias Cgc2046.Miniprogram.NotificationConsent

  test "member 与 nil actor 读被拒（Forbidden）" do
    member = Cgc2046.AccountsFixtures.register_user("mp-consent-fc")

    assert {:error, %Ash.Error.Forbidden{}} = NotificationConsent |> Ash.read(actor: member)
    assert {:error, %Ash.Error.Forbidden{}} = NotificationConsent |> Ash.read()
  end

  test "platform_admin 可读授权余额（观测面放行）" do
    admin = Cgc2046.AccountsFixtures.platform_admin("mp-consent-admin")
    user = Cgc2046.AccountsFixtures.register_user("mp-consent-grantee")

    assert {:ok, _} = Cgc2046.Notifications.Consent.grant(user.id, :wechat, "approval_result")

    assert {:ok, rows} = NotificationConsent |> Ash.read(actor: admin)
    assert Enum.any?(rows, &(&1.user_id == user.id))
  end
end
