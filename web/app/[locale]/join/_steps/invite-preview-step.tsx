import { useTranslations } from "next-intl";
import { invitationRoleLabel, type InvitationItem } from "@/lib/invitations";

interface InvitePreviewStepProps {
  invitation: InvitationItem;
  loading: boolean;
  onAccept: () => void;
}

export function InvitePreviewStep({
  invitation,
  loading,
  onAccept,
}: InvitePreviewStepProps) {
  const t = useTranslations("join");
  const labelsT = useTranslations();
  return (
    <div className="join-workspace-preview">
      <div className="join-workspace-info">
        <h2>{invitation.workspaceName ?? t("unknownWorkspace")}</h2>
        {invitation.workspaceSlug && <code>{invitation.workspaceSlug}</code>}
        {invitation.preauthorizedRoleNames &&
          invitation.preauthorizedRoleNames.length > 0 && (
            <div className="join-preauthorized-roles">
              <span>{t("preauthorizedRoles")}</span>
              {invitation.preauthorizedRoleNames.map((role) => (
                <span className="workspace-role-chip" key={role}>
                  {invitationRoleLabel(role, labelsT("labels.memberNoLabel"))}
                </span>
              ))}
            </div>
          )}
        {(!invitation.preauthorizedRoleNames ||
          invitation.preauthorizedRoleNames.length === 0) && (
          <p className="join-note">{t("noPreauthNote")}</p>
        )}
      </div>
      <div className="join-action-area">
        <button
          type="button"
          className="join-button join-button--primary"
          onClick={onAccept}
          disabled={loading}
        >
          {loading ? t("accepting") : t("confirmJoin")}
        </button>
      </div>
    </div>
  );
}
