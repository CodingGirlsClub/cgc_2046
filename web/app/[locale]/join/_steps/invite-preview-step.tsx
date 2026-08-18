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
  return (
    <div className="join-workspace-preview">
      <div className="join-workspace-info">
        <h2>{invitation.workspaceName ?? "未知工作区"}</h2>
        {invitation.workspaceSlug && <code>{invitation.workspaceSlug}</code>}
        {invitation.preauthorizedRoleNames &&
          invitation.preauthorizedRoleNames.length > 0 && (
            <div className="join-preauthorized-roles">
              <span>预授权角色：</span>
              {invitation.preauthorizedRoleNames.map((role) => (
                <span className="workspace-role-chip" key={role}>
                  {invitationRoleLabel(role)}
                </span>
              ))}
            </div>
          )}
        {(!invitation.preauthorizedRoleNames ||
          invitation.preauthorizedRoleNames.length === 0) && (
          <p className="join-note">
            此邀请未预授权角色，加入后需 Owner 分配角色。
          </p>
        )}
      </div>
      <div className="join-action-area">
        <button
          type="button"
          className="join-button join-button--primary"
          onClick={onAccept}
          disabled={loading}
        >
          {loading ? "接受中…" : "确认加入"}
        </button>
      </div>
    </div>
  );
}