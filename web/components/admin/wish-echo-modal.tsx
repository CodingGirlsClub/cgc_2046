"use client";

/**
 * admin 愿望回响管理弹窗（#835，Echo 一期 2/4）。
 *
 * - 按时间正序列出某愿望的全部回响（draft / published / corrected / revoked）；
 * - 支持新建草稿、编辑草稿、发布、更正已发布、撤回（撤回为终态）；
 * - 发布确认框展示「将尝试通知 N 位附议者」；更正/撤回确认框写明不重新通知；
 * - 正文 trim 后 1–500 字，与后端校验（#834 WishEchoes）一致，超长禁用提交。
 */
import { useCallback, useEffect, useMemo, useState } from "react";
import { useTranslations } from "next-intl";
import {
  createFlashbackWishEcho,
  correctFlashbackWishEcho,
  fetchFlashbackAdminWishEchoes,
  publishFlashbackWishEcho,
  revokeFlashbackWishEcho,
  updateFlashbackWishEchoDraft,
} from "@/lib/admin";
import { formatDateTime } from "@/lib/format";
import type {
  FlashbackAdminWishEcho,
  FlashbackAdminWishEchoesResult,
} from "@/lib/graphql/admin";

const MAX_ECHO_LENGTH = 500;

type PendingAction =
  | { kind: "publish"; echo: FlashbackAdminWishEcho }
  | { kind: "revoke"; echo: FlashbackAdminWishEcho }
  | { kind: "correct"; echo: FlashbackAdminWishEcho; content: string }
  | null;

interface WishEchoModalProps {
  wishId: string;
  wishPreview: string;
  onClose: () => void;
  /** 回响计数变化后通知父级刷新队列计数 */
  onChanged?: () => void;
}

function normalizeContent(input: string): string {
  return input.trim();
}

export function WishEchoModal({
  wishId,
  wishPreview,
  onClose,
  onChanged,
}: WishEchoModalProps) {
  const t = useTranslations("admin");
  const [data, setData] = useState<FlashbackAdminWishEchoesResult | null>(null);
  const [loadError, setLoadError] = useState(false);
  const [loaded, setLoaded] = useState(false);

  // 编辑器：draft 只有一份在编辑状态即可；新建草稿编辑与既有草稿编辑共用。
  const [editingId, setEditingId] = useState<string | "new" | null>(null);
  const [draftText, setDraftText] = useState("");
  const [submitError, setSubmitError] = useState<string | null>(null);
  const [busy, setBusy] = useState(false);
  const [pending, setPending] = useState<PendingAction>(null);

  const reload = useCallback(() => {
    return fetchFlashbackAdminWishEchoes(wishId)
      .then((result) => {
        setData(result);
        setLoadError(false);
        setLoaded(true);
      })
      .catch(() => {
        setLoadError(true);
        setLoaded(true);
      });
  }, [wishId]);

  useEffect(() => {
    reload().catch(() => undefined);
  }, [reload]);

  const trimmed = normalizeContent(draftText);
  const draftTooLong = [...trimmed].length > MAX_ECHO_LENGTH;
  const draftInvalid = trimmed.length === 0 || draftTooLong;

  const startCreate = () => {
    setEditingId("new");
    setDraftText("");
    setSubmitError(null);
  };

  const startEditDraft = (echo: FlashbackAdminWishEcho) => {
    setEditingId(echo.id);
    setDraftText(echo.content);
    setSubmitError(null);
  };

  const cancelEdit = () => {
    setEditingId(null);
    setDraftText("");
    setSubmitError(null);
  };

  const runMutation = (fn: () => Promise<unknown>) => {
    setBusy(true);
    setSubmitError(null);
    fn()
      .then(async () => {
        cancelEdit();
        setPending(null);
        await reload();
        onChanged?.();
      })
      .catch(() => {
        setSubmitError(t("fbEchoSaveFailed"));
        setPending(null);
      })
      .finally(() => setBusy(false));
  };

  const submitDraft = () => {
    if (draftInvalid || busy || editingId === null) return;
    const content = trimmed;
    runMutation(() =>
      editingId === "new"
        ? createFlashbackWishEcho(wishId, content)
        : updateFlashbackWishEchoDraft(editingId, content),
    );
  };

  const confirmPending = () => {
    if (!pending || busy) return;
    if (pending.kind === "publish") {
      runMutation(() => publishFlashbackWishEcho(pending.echo.id));
    } else if (pending.kind === "revoke") {
      runMutation(() => revokeFlashbackWishEcho(pending.echo.id));
    } else {
      runMutation(() =>
        correctFlashbackWishEcho(pending.echo.id, pending.content.trim()),
      );
    }
  };

  const statusLabel = useMemo(
    () => (status: string) => t(`fbEchoStatus_${status}`),
    [t],
  );

  const echoes = data?.echoes ?? [];
  const notifiableCount = data?.currentNotifiableEndorsementCount ?? 0;

  return (
    <div
      className="admin-modal-overlay"
      role="presentation"
      onClick={busy ? undefined : onClose}
    >
      <div
        className="admin-modal"
        style={{ width: "min(100%, 680px)", textAlign: "left" }}
        onClick={(e) => e.stopPropagation()}
        role="dialog"
        aria-modal="true"
        aria-label={t("fbEchoModalTitle")}
      >
        <h2>{t("fbEchoModalTitle")}</h2>
        <p className="admin-page__desc" title={wishPreview}>
          {wishPreview}
        </p>

        {loaded && loadError && (
          <p className="admin-alert admin-alert--error" role="alert">
            {t("fbEchoLoadFailed")}
          </p>
        )}

        {loaded && !loadError && data && (
          <>
            <p className="admin-page__desc" data-testid="fb-echo-notifiable">
              {t("fbEchoNotifiable", { count: notifiableCount })}
            </p>

            {echoes.length === 0 && editingId === null && (
              <p className="admin-empty">{t("fbEchoListEmpty")}</p>
            )}

            <ul
              style={{ listStyle: "none", margin: 0, padding: 0 }}
              data-testid="fb-echo-list"
            >
              {echoes.map((echo) => (
                <li
                  key={echo.id}
                  data-testid={`fb-echo-${echo.id}`}
                  style={{
                    borderTop: "1px solid var(--line)",
                    padding: "10px 0",
                  }}
                >
                  <div
                    style={{
                      display: "flex",
                      justifyContent: "space-between",
                      gap: 8,
                    }}
                  >
                    <strong data-testid="fb-echo-status">
                      {statusLabel(echo.status)}
                    </strong>
                    <span
                      className="admin-page__desc"
                      style={{ margin: 0, whiteSpace: "nowrap" }}
                    >
                      {formatDateTime(echo.publishedAt ?? echo.insertedAt)}
                    </span>
                  </div>

                  {editingId === echo.id ? (
                    <div style={{ marginTop: 8 }}>
                      <textarea
                        value={draftText}
                        onChange={(e) => setDraftText(e.target.value)}
                        rows={4}
                        disabled={busy}
                        style={{ width: "100%" }}
                        aria-label={t("fbEchoEditorLabel")}
                      />
                      <p
                        className="admin-page__desc"
                        role={draftInvalid ? "alert" : undefined}
                        style={
                          draftTooLong
                            ? { color: "var(--danger, #c00)" }
                            : undefined
                        }
                      >
                        {t("fbEchoLengthHint", {
                          count: [...trimmed].length,
                          max: MAX_ECHO_LENGTH,
                        })}
                      </p>
                      <div className="admin-modal__actions">
                        <button
                          type="button"
                          className="l-btn-outline"
                          onClick={cancelEdit}
                          disabled={busy}
                        >
                          {t("fbEchoCancel")}
                        </button>
                        <button
                          type="button"
                          className="l-btn-primary"
                          onClick={submitDraft}
                          disabled={busy || draftInvalid}
                        >
                          {t("fbEchoSaveDraft")}
                        </button>
                      </div>
                    </div>
                  ) : (
                    <p style={{ whiteSpace: "pre-wrap", margin: "8px 0" }}>
                      {echo.content}
                    </p>
                  )}

                  {editingId !== echo.id && (
                    <div className="admin-table__actions">
                      {echo.status === "draft" && (
                        <>
                          <button
                            type="button"
                            className="l-btn-outline"
                            onClick={() => startEditDraft(echo)}
                            disabled={busy || editingId !== null}
                          >
                            {t("fbEchoEditDraft")}
                          </button>
                          <button
                            type="button"
                            className="l-btn-primary"
                            onClick={() =>
                              setPending({ kind: "publish", echo })
                            }
                            disabled={busy}
                          >
                            {t("fbEchoPublish")}
                          </button>
                        </>
                      )}
                      {(echo.status === "published" ||
                        echo.status === "corrected") && (
                        <>
                          <button
                            type="button"
                            className="l-btn-outline"
                            onClick={() =>
                              setPending({
                                kind: "correct",
                                echo,
                                content: echo.content,
                              })
                            }
                            disabled={busy || editingId !== null}
                          >
                            {t("fbEchoCorrect")}
                          </button>
                          <button
                            type="button"
                            className="l-btn-outline"
                            onClick={() => setPending({ kind: "revoke", echo })}
                            disabled={busy}
                          >
                            {t("fbEchoRevoke")}
                          </button>
                        </>
                      )}
                    </div>
                  )}
                </li>
              ))}
            </ul>

            {editingId === "new" && (
              <div style={{ marginTop: 8 }} data-testid="fb-echo-new-editor">
                <textarea
                  value={draftText}
                  onChange={(e) => setDraftText(e.target.value)}
                  rows={4}
                  disabled={busy}
                  style={{ width: "100%" }}
                  aria-label={t("fbEchoEditorLabel")}
                />
                <p
                  className="admin-page__desc"
                  role={draftInvalid ? "alert" : undefined}
                  style={
                    draftTooLong ? { color: "var(--danger, #c00)" } : undefined
                  }
                >
                  {t("fbEchoLengthHint", {
                    count: [...trimmed].length,
                    max: MAX_ECHO_LENGTH,
                  })}
                </p>
                <div className="admin-modal__actions">
                  <button
                    type="button"
                    className="l-btn-outline"
                    onClick={cancelEdit}
                    disabled={busy}
                  >
                    {t("fbEchoCancel")}
                  </button>
                  <button
                    type="button"
                    className="l-btn-primary"
                    onClick={submitDraft}
                    disabled={busy || draftInvalid}
                  >
                    {t("fbEchoSaveDraft")}
                  </button>
                </div>
              </div>
            )}

            {editingId === null && (
              <div className="admin-modal__actions" style={{ marginTop: 12 }}>
                <button
                  type="button"
                  className="l-btn-outline"
                  onClick={onClose}
                  disabled={busy}
                >
                  {t("fbEchoClose")}
                </button>
                <button
                  type="button"
                  className="l-btn-primary"
                  onClick={startCreate}
                  disabled={busy}
                >
                  {t("fbEchoNew")}
                </button>
              </div>
            )}

            {submitError && (
              <p className="admin-alert admin-alert--error" role="alert">
                {submitError}
              </p>
            )}
          </>
        )}

        {pending?.kind === "publish" && (
          <ConfirmLayer
            title={t("fbEchoPublishConfirmTitle")}
            body={t("fbEchoPublishConfirmBody", { count: notifiableCount })}
            preview={pending.echo.content}
            confirmLabel={t("fbEchoPublishConfirmOk")}
            busy={busy}
            onCancel={() => setPending(null)}
            onConfirm={confirmPending}
          />
        )}
        {pending?.kind === "revoke" && (
          <ConfirmLayer
            title={t("fbEchoRevokeConfirmTitle")}
            body={t("fbEchoRevokeConfirmBody")}
            preview={pending.echo.content}
            confirmLabel={t("fbEchoRevokeConfirmOk")}
            busy={busy}
            onCancel={() => setPending(null)}
            onConfirm={confirmPending}
          />
        )}
        {pending?.kind === "correct" && (
          <div className="admin-modal-overlay" role="presentation">
            <div
              className="admin-modal"
              role="dialog"
              aria-modal="true"
              aria-label={t("fbEchoCorrectConfirmTitle")}
              onClick={(e) => e.stopPropagation()}
            >
              <h2>{t("fbEchoCorrectConfirmTitle")}</h2>
              <p>{t("fbEchoCorrectConfirmBody")}</p>
              <textarea
                value={pending.content}
                onChange={(e) =>
                  setPending({
                    kind: "correct",
                    echo: pending.echo,
                    content: e.target.value,
                  })
                }
                rows={4}
                disabled={busy}
                style={{ width: "100%" }}
                aria-label={t("fbEchoEditorLabel")}
              />
              <p className="admin-page__desc">
                {t("fbEchoLengthHint", {
                  count: [...pending.content.trim()].length,
                  max: MAX_ECHO_LENGTH,
                })}
              </p>
              <div className="admin-modal__actions">
                <button
                  type="button"
                  className="l-btn-outline"
                  onClick={() => setPending(null)}
                  disabled={busy}
                >
                  {t("fbEchoCancel")}
                </button>
                <button
                  type="button"
                  className="l-btn-primary"
                  onClick={confirmPending}
                  disabled={
                    busy ||
                    pending.content.trim().length === 0 ||
                    [...pending.content.trim()].length > MAX_ECHO_LENGTH
                  }
                >
                  {t("fbEchoCorrectConfirmOk")}
                </button>
              </div>
            </div>
          </div>
        )}
      </div>
    </div>
  );
}

interface ConfirmLayerProps {
  title: string;
  body: string;
  preview: string;
  confirmLabel: string;
  busy: boolean;
  onCancel: () => void;
  onConfirm: () => void;
}

function ConfirmLayer({
  title,
  body,
  preview,
  confirmLabel,
  busy,
  onCancel,
  onConfirm,
}: ConfirmLayerProps) {
  const t = useTranslations("admin");
  return (
    <div className="admin-modal-overlay" role="presentation">
      <div
        className="admin-modal"
        role="dialog"
        aria-modal="true"
        aria-label={title}
        onClick={(e) => e.stopPropagation()}
      >
        <h2>{title}</h2>
        <p>{body}</p>
        <p
          className="admin-page__desc"
          style={{ whiteSpace: "pre-wrap" }}
          data-testid="fb-echo-confirm-preview"
        >
          {preview}
        </p>
        <div className="admin-modal__actions">
          <button
            type="button"
            className="l-btn-outline"
            onClick={onCancel}
            disabled={busy}
          >
            {t("fbEchoCancel")}
          </button>
          <button
            type="button"
            className="l-btn-primary"
            onClick={onConfirm}
            disabled={busy}
          >
            {confirmLabel}
          </button>
        </div>
      </div>
    </div>
  );
}
