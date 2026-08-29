defmodule Cgc2046.Repo.Migrations.RenameMiniprogramTables do
  @moduledoc """
  ADR-0010 ⑩ 方案 A（资源跟写路径走）：表随资源归域改名。

  - `miniprogram_codes` → `invitation_codes`（资源 Accounts.InvitationCode，
    本质是 Invitation 的渠道码缓存；索引/约束/外键名同步更名）
  - `mp_notification_consents` → `notification_consents`（资源
    Notifications.NotificationConsent；支持 wechat/tt/xhs 三平台，mp_ 前缀
    名不副实）

  纯 rename 保数据（up/down 对称）；写方裸 SQL（invitation.ex /
  notifications/consent.ex）与 resource_snapshots 已同步。
  """
  use Ecto.Migration

  def up do
    rename(table(:miniprogram_codes), to: table(:invitation_codes))
    rename(table(:mp_notification_consents), to: table(:notification_consents))

    execute(
      "ALTER INDEX miniprogram_codes_pkey RENAME TO invitation_codes_pkey",
      "ALTER INDEX invitation_codes_pkey RENAME TO miniprogram_codes_pkey"
    )

    execute(
      "ALTER INDEX miniprogram_codes_unique_invitation_platform_index RENAME TO invitation_codes_unique_invitation_platform_index",
      "ALTER INDEX invitation_codes_unique_invitation_platform_index RENAME TO miniprogram_codes_unique_invitation_platform_index"
    )

    execute(
      "ALTER INDEX miniprogram_codes_unique_scene_index RENAME TO invitation_codes_unique_scene_index",
      "ALTER INDEX invitation_codes_unique_scene_index RENAME TO miniprogram_codes_unique_scene_index"
    )

    execute(
      "ALTER TABLE invitation_codes RENAME CONSTRAINT miniprogram_codes_workspace_id_fkey TO invitation_codes_workspace_id_fkey",
      "ALTER TABLE invitation_codes RENAME CONSTRAINT invitation_codes_workspace_id_fkey TO miniprogram_codes_workspace_id_fkey"
    )

    execute(
      "ALTER TABLE invitation_codes RENAME CONSTRAINT miniprogram_codes_invitation_id_fkey TO invitation_codes_invitation_id_fkey",
      "ALTER TABLE invitation_codes RENAME CONSTRAINT invitation_codes_invitation_id_fkey TO miniprogram_codes_invitation_id_fkey"
    )

    execute(
      "ALTER INDEX mp_notification_consents_pkey RENAME TO notification_consents_pkey",
      "ALTER INDEX notification_consents_pkey RENAME TO mp_notification_consents_pkey"
    )

    execute(
      "ALTER INDEX mp_notification_consents_unique_user_platform_template_index RENAME TO notification_consents_unique_user_platform_template_index",
      "ALTER INDEX notification_consents_unique_user_platform_template_index RENAME TO mp_notification_consents_unique_user_platform_template_index"
    )

    execute(
      "ALTER TABLE notification_consents RENAME CONSTRAINT mp_notification_consents_non_negative TO notification_consents_non_negative",
      "ALTER TABLE notification_consents RENAME CONSTRAINT notification_consents_non_negative TO mp_notification_consents_non_negative"
    )

    execute(
      "ALTER TABLE notification_consents RENAME CONSTRAINT mp_notification_consents_user_id_fkey TO notification_consents_user_id_fkey",
      "ALTER TABLE notification_consents RENAME CONSTRAINT notification_consents_user_id_fkey TO mp_notification_consents_user_id_fkey"
    )
  end

  def down do
    rename(table(:invitation_codes), to: table(:miniprogram_codes))
    rename(table(:notification_consents), to: table(:mp_notification_consents))

    execute(
      "ALTER INDEX invitation_codes_pkey RENAME TO miniprogram_codes_pkey",
      "ALTER INDEX miniprogram_codes_pkey RENAME TO invitation_codes_pkey"
    )

    execute(
      "ALTER INDEX invitation_codes_unique_invitation_platform_index RENAME TO miniprogram_codes_unique_invitation_platform_index",
      "ALTER INDEX miniprogram_codes_unique_invitation_platform_index RENAME TO invitation_codes_unique_invitation_platform_index"
    )

    execute(
      "ALTER INDEX invitation_codes_unique_scene_index RENAME TO miniprogram_codes_unique_scene_index",
      "ALTER INDEX miniprogram_codes_unique_scene_index RENAME TO invitation_codes_unique_scene_index"
    )

    execute(
      "ALTER TABLE miniprogram_codes RENAME CONSTRAINT invitation_codes_workspace_id_fkey TO miniprogram_codes_workspace_id_fkey",
      "ALTER TABLE miniprogram_codes RENAME CONSTRAINT miniprogram_codes_workspace_id_fkey TO invitation_codes_workspace_id_fkey"
    )

    execute(
      "ALTER TABLE miniprogram_codes RENAME CONSTRAINT invitation_codes_invitation_id_fkey TO miniprogram_codes_invitation_id_fkey",
      "ALTER TABLE miniprogram_codes RENAME CONSTRAINT miniprogram_codes_invitation_id_fkey TO invitation_codes_invitation_id_fkey"
    )

    execute(
      "ALTER INDEX notification_consents_pkey RENAME TO mp_notification_consents_pkey",
      "ALTER INDEX mp_notification_consents_pkey RENAME TO notification_consents_pkey"
    )

    execute(
      "ALTER INDEX notification_consents_unique_user_platform_template_index RENAME TO mp_notification_consents_unique_user_platform_template_index",
      "ALTER INDEX mp_notification_consents_unique_user_platform_template_index RENAME TO notification_consents_unique_user_platform_template_index"
    )

    execute(
      "ALTER TABLE mp_notification_consents RENAME CONSTRAINT notification_consents_non_negative TO mp_notification_consents_non_negative",
      "ALTER TABLE mp_notification_consents RENAME CONSTRAINT mp_notification_consents_non_negative TO notification_consents_non_negative"
    )

    execute(
      "ALTER TABLE mp_notification_consents RENAME CONSTRAINT notification_consents_user_id_fkey TO mp_notification_consents_user_id_fkey",
      "ALTER TABLE mp_notification_consents RENAME CONSTRAINT mp_notification_consents_user_id_fkey TO notification_consents_user_id_fkey"
    )
  end
end
