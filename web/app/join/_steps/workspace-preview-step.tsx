import { useState } from "react";
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
            {loading ? "加入中…" : "直接加入"}
          </button>
        </div>
      )}

      {workspace.joinPolicy === "request" && (
        <div className="join-action-area">
          <label className="join-field">
            <span>申请留言（可选）</span>
            <textarea
              className="join-textarea"
              placeholder="简单介绍一下自己…"
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
            {loading ? "提交中…" : "提交申请"}
          </button>
        </div>
      )}

      {workspace.joinPolicy === "invite_only" && (
        <div className="join-action-area">
          <div className="join-invite-notice">
            <Icon name="lock" />
            <span>该工作区为邀请制，需要有效邀请链接才能加入。</span>
          </div>
          <button
            type="button"
            className="join-button join-button--outline"
            onClick={onHaveInvite}
          >
            我有邀请链接
          </button>
        </div>
      )}

      <button
        type="button"
        className="join-button join-button--ghost"
        onClick={onBack}
      >
        ← 查找其他工作区
      </button>
    </div>
  );
}
