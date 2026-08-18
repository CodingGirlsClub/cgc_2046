import { Link } from "@/i18n/navigation";
import { useTranslations } from "next-intl";
import { Icon } from "@/components/icons";
import { INVITATION_STATUS_LABEL } from "@/lib/graphql/invitation";
import type { InvitationItem } from "@/lib/invitations";

interface InviteInvalidStepProps {
  error: string | null;
  invitation: InvitationItem | null;
  onRetry: () => void;
}

export function InviteInvalidStep({
  error,
  invitation,
  onRetry,
}: InviteInvalidStepProps) {
  const t = useTranslations("join");
  const labelsT = useTranslations();
  return (
    <div className="join-status-card join-status-card--error">
      <Icon name="lock" />
      <h2>{t("inviteInvalidTitle")}</h2>
      <p>{error}</p>
      {invitation && invitation.status !== "active" && (
        <p className="join-status-detail">
          {t("inviteInvalidStatus", {
            status: labelsT(INVITATION_STATUS_LABEL[invitation.status]),
          })}
        </p>
      )}
      <div className="join-actions">
        <button
          type="button"
          className="join-button join-button--outline"
          onClick={onRetry}
        >
          {t("reenter")}
        </button>
        <Link href="/" className="join-button join-button--ghost">
          {t("backToHome")}
        </Link>
      </div>
    </div>
  );
}
