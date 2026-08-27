"use client";

/**
 * 设置页「绑定/换绑手机号」区块（profile 设置表单侧栏卡片）。
 *
 * - 展示态：当前绑定（MY_PHONE 掩码）/「未绑定」+「修改/绑定」按钮展开表单。
 *   MY_PHONE 首挂 loading 渲染 settings-skeleton 占位（不显示「未绑定」），
 *   请求失败渲染 members-error + 重试（refetch）——账号安全状态不折叠语义。
 * - 表单态：新手机号 + 验证码行 + 提交；发码复用 useSmsLogin().sendCode
 *   （purpose CHANGE_PHONE）与 countdown（register-phone-form 先例：只用
 *   sendCode，submit 自己实现）；提交走 updateMyPhone，成功后 refetch
 *   MY_PHONE 并给 settings-saved 提示。
 * - 错误映射同 smsErrorMessage 思路；phone_already_registered 在换绑上下文
 *   用 workspaceAccount.phoneTakenByOther（「已被其他账号使用」），不复用注册文案。
 * - 类名沿用 profile-* / settings-*；短信行不复用 auth-sms-code-row
 *   （其 CSS 嵌在 .auth scope），用 settings 风格自写（globals.css
 *   .profile-phone-*）。
 */

import { useState, type FormEvent } from "react";
import { useMutation, useQuery } from "@apollo/client/react";
import { useTranslations } from "next-intl";
import {
  graphqlErrorDetails,
  MY_PHONE,
  UPDATE_MY_PHONE,
} from "@/lib/graphql/auth";
import { useSmsLogin } from "@/app/[locale]/(auth)/login/use-sms-login";

export function PhoneBindingSection() {
  const t = useTranslations("workspaceAccount");
  const tCommon = useTranslations("common");
  const smsT = useTranslations("auth.sms");
  const { data, loading, error: loadError, refetch } = useQuery(MY_PHONE);
  const {
    sendCode,
    countdown,
    sending,
    error: sendError,
    setError: setSendError,
  } = useSmsLogin();
  const [updatePhone, updateState] = useMutation(UPDATE_MY_PHONE);
  const [editing, setEditing] = useState(false);
  const [phone, setPhone] = useState("");
  const [code, setCode] = useState("");
  const [error, setError] = useState<string | null>(null);
  const [saved, setSaved] = useState<string | null>(null);
  // 发码失败（限流/非法手机号/投递失败）与提交错误共用同一 alert
  const displayError = error ?? sendError;

  const myPhone = data?.myPhone ?? null;

  const startEditing = () => {
    setEditing(true);
    setSaved(null);
    setError(null);
    setSendError(null);
  };

  const cancelEditing = () => {
    setEditing(false);
    setPhone("");
    setCode("");
    setError(null);
    setSendError(null);
  };

  const handleSend = async () => {
    if (!phone.trim()) {
      setError(smsT("errorInvalidPhone"));
      return;
    }
    setError(null);
    setSendError(null);
    await sendCode(phone.trim(), "CHANGE_PHONE");
  };

  const handleSubmit = async (event: FormEvent<HTMLFormElement>) => {
    event.preventDefault();
    if (!phone.trim()) {
      setError(smsT("errorInvalidPhone"));
      return;
    }
    if (!/^\d{6}$/.test(code.trim())) {
      setError(smsT("errorInvalidCode"));
      return;
    }

    try {
      const { data: result } = await updatePhone({
        variables: { phone: phone.trim(), code: code.trim() },
      });
      if (result?.updateMyPhone?.id) {
        await refetch();
        cancelEditing();
        setSaved(t("phoneBindSaved"));
        return;
      }
      setError(t("saveFailed"));
    } catch (e) {
      const errorCode = graphqlErrorDetails(e)?.code ?? null;
      if (errorCode === "phone_already_registered") {
        setError(t("phoneTakenByOther"));
        return;
      }
      if (errorCode === "invalid_or_expired_code") {
        setError(smsT("errorInvalidCode"));
        return;
      }
      if (errorCode === "rate_limited") {
        setError(smsT("errorRateLimited"));
        return;
      }
      if (errorCode === "invalid_phone") {
        setError(smsT("errorInvalidPhone"));
        return;
      }
      setError(t("saveFailed"));
    }
  };

  return (
    <section
      className="profile-card profile-phone"
      data-testid="phone-binding-section"
    >
      <h2>{t("phoneTitle")}</h2>
      {saved && !editing && (
        <div className="settings-saved" role="status">
          {saved}
        </div>
      )}
      {!editing ? (
        // 三态不折叠：首挂 loading → 骨架占位；失败 → 错误 + 重试；均不显示「未绑定」
        loading && !data ? (
          <div className="settings-skeleton" aria-label={t("loadingAria")} />
        ) : loadError ? (
          <div className="members-error" role="alert">
            {t("phoneLoadFailed")}
            <button
              type="button"
              className="profile-phone-edit"
              onClick={() => void refetch()}
            >
              {tCommon("retry")}
            </button>
          </div>
        ) : (
          <div className="profile-phone-summary">
            <span className="profile-phone-current">
              {myPhone ?? t("phoneUnbound")}
            </span>
            <button
              type="button"
              className="profile-phone-edit"
              onClick={startEditing}
            >
              {myPhone ? t("phoneChangeCta") : t("phoneBindCta")}
            </button>
          </div>
        )
      ) : (
        <form className="profile-phone-form" onSubmit={handleSubmit} noValidate>
          {displayError && (
            <div role="alert" className="members-error">
              {displayError}
            </div>
          )}
          <div className="profile-phone-field">
            <label className="profile-form-label" htmlFor="phone-binding-phone">
              {smsT("fieldPhone")}
            </label>
            <input
              id="phone-binding-phone"
              name="phone"
              type="tel"
              placeholder={smsT("placeholderPhone")}
              value={phone}
              onChange={(event) => {
                setPhone(event.target.value);
                setError(null);
                setSendError(null);
              }}
              autoComplete="tel"
              required
            />
          </div>
          <div className="profile-phone-field">
            <label className="profile-form-label" htmlFor="phone-binding-code">
              {smsT("fieldCode")}
            </label>
            <div className="profile-phone-code-row">
              <input
                id="phone-binding-code"
                name="code"
                type="text"
                inputMode="numeric"
                maxLength={6}
                placeholder={smsT("placeholderCode")}
                value={code}
                onChange={(event) => {
                  setCode(event.target.value);
                  setError(null);
                }}
                autoComplete="one-time-code"
                required
              />
              <button
                type="button"
                className="profile-phone-send"
                disabled={sending || countdown > 0 || !phone.trim()}
                onClick={handleSend}
              >
                {countdown > 0
                  ? smsT("resendCountdown", { seconds: countdown })
                  : sending
                    ? smsT("sending")
                    : smsT("sendCode")}
              </button>
            </div>
          </div>
          <div className="profile-phone-actions">
            <button
              type="button"
              className="profile-phone-cancel"
              onClick={cancelEditing}
            >
              {t("phoneCancel")}
            </button>
            <button
              type="submit"
              className="l-btn l-btn-primary"
              disabled={updateState.loading}
              aria-busy={updateState.loading}
            >
              {updateState.loading ? t("saving") : t("saveChanges")}
            </button>
          </div>
        </form>
      )}
    </section>
  );
}
