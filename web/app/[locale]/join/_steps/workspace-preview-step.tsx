import { useState } from "react";
import { useTranslations } from "next-intl";
import { Icon } from "@/components/icons";
import {
  JOIN_POLICY_LABEL,
  JOIN_POLICY_HINT,
  type Workspace,
} from "@/lib/graphql/workspace";

interface WorkspacePreviewStepProps {
  workspace: Workspace;
  loading: boolean;
  onJoinOpen: () => void;
  onSubmitRequest: (message: string) => void;
  onHaveInvite: () => void;
  onBack: () => void;
}

export function WorkspacePreviewStep({
  workspace,
  loading,
  onJoinOpen,
  onSubmitRequest,
  onHaveInvite,
  onBack,
}: WorkspacePreviewStepProps) {
  const [message, setMessage] = useState("");
  const t = useTranslations("join");

  return (
    <div className="join-workspace-preview">
      <div className="join-workspace-info">
        <h2>{workspace.name}</h2>
        <code>{workspace.slug}</code>
        <span
          className={`workspace-policy workspace-policy--${workspace.joinPolicy}`}
        >
          {JOIN_POLICY_LABEL[workspace.joinPolicy]}
        </span>
        <p className="join-policy-hint">
          {JOIN_POLICY_HINT[workspace.joinPolicy]}
        </p>
      </div>

      {workspace.joinPolicy === "open" && (
        <div className="join-action-area">
          <button
            type="button"
            className="join-button join-button--primary"
            onClick={onJoinOpen}
            disabled={loading}
          >
            {loading ? t("joining") : t("joinDirect")}
          </button>
        </div>
      )}

      {workspace.joinPolicy === "request" && (
        <div className="join-action-area">
          <label className="join-field">
            <span>{t("requestMsgLabel")}</span>
            <textarea
              className="join-textarea"
              placeholder={t("requestMsgPlaceholder")}
              value={message}
              onChange={(e) => setMessage(e.target.value)}
              disabled={loading}
              rows={3}
            />
          </label>
          <button
            type="button"
            className="join-button join-button--primary"
            onClick={() => onSubmitRequest(message)}
            disabled={loading}
          >
            {loading ? t("submitting") : t("submitRequest")}
          </button>
        </div>
      )}

      {workspace.joinPolicy === "invite_only" && (
        <div className="join-action-area">
          <div className="join-invite-notice">
            <Icon name="lock" />
            <span>{t("inviteOnlyNotice")}</span>
          </div>
          <button
            type="button"
            className="join-button join-button--outline"
            onClick={onHaveInvite}
          >
            {t("haveInvite")}
          </button>
        </div>
      )}

      <button
        type="button"
        className="join-button join-button--ghost"
        onClick={onBack}
      >
        {t("searchOther")}
      </button>
    </div>
  );
}
