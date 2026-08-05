import Link from "next/link";
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
  return (
    <div className="join-status-card join-status-card--error">
      <Icon name="lock" />
      <h2>邀请无效</h2>
      <p>{error}</p>
      {invitation && invitation.status !== "active" && (
        <p className="join-status-detail">
          状态：{INVITATION_STATUS_LABEL[invitation.status]}
        </p>
      )}
      <div className="join-actions">
        <button
          type="button"
          className="join-button join-button--outline"
          onClick={onRetry}
        >
          重新输入
        </button>
        <Link href="/" className="join-button join-button--ghost">
          返回工作台
        </Link>
      </div>
    </div>
  );
}