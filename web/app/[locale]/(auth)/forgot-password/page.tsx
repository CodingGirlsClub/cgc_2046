"use client";

import { Link } from "@/i18n/navigation";
import { useEffect, useRef, useState, type FormEvent } from "react";
import { useMutation, useQuery } from "@apollo/client/react";
import { useTranslations } from "next-intl";
import {
  graphqlErrorDetails,
  PASSWORD_CENTER_QR,
  REQUEST_PASSWORD_RESET,
} from "@/lib/graphql/auth";
import AuthShell from "../auth-shell";

/**
 * 账号找回（R7–R10）：小程序为主路径——扫码直达小程序密码页，凭微信登录态
 * 设置/重设密码，不依赖邮箱或短信。邮箱重置折叠保留给历史账号（phone 为空，
 * 小程序登录会按手机号新建账号，因此必须让这批人明确走邮箱）。
 */
export default function ForgotPasswordPage() {
  const t = useTranslations("auth.forgot");
  const [requestPasswordReset, { loading }] = useMutation(REQUEST_PASSWORD_RESET);
  const { data: qrData } = useQuery(PASSWORD_CENTER_QR, { fetchPolicy: "cache-first" });
  const [email, setEmail] = useState("");
  const [submitted, setSubmitted] = useState(false);
  const [error, setError] = useState<string | null>(null);
  const statusRef = useRef<HTMLDivElement>(null);

  const qr = qrData?.passwordCenterQr ?? null;

  useEffect(() => {
    if (submitted || error) statusRef.current?.focus();
  }, [submitted, error]);

  const handleSubmit = async (event: FormEvent<HTMLFormElement>) => {
    event.preventDefault();
    setError(null);

    try {
      const { data } = await requestPasswordReset({
        variables: { email: email.trim() },
      });

      if (data?.requestPasswordReset?.sent) {
        setSubmitted(true);
      } else {
        setError(t("errorSendFailed"));
      }
    } catch (reason) {
      const details = graphqlErrorDetails(reason);
      setError(
        details?.code === "rate_limited"
          ? t("errorRateLimited")
          : t("errorSendFailed"),
      );
    }
  };

  return (
    <AuthShell mode="login">
      <div className="auth-form-heading">
        <h2 id="auth-page-title">{t("title")}</h2>
      </div>

      <div className="auth-form-body">
        <p className="auth-field__hint">{t("mpHint")}</p>

        {qr ? (
          <div className="auth-field">
            {/* 固定 scene 码：不含凭证，进密码页仍需微信登录（R9） */}
            {/* eslint-disable-next-line @next/next/no-img-element */}
            <img src={qr} alt={t("mpQrAlt")} width={180} height={180} />
          </div>
        ) : (
          <p className="auth-field__hint" role="note">
            {t("mpUnavailable")}
          </p>
        )}

        <details className="auth-email-fallback">
          <summary>{t("emailToggle")}</summary>

          {submitted ? (
            <div
              ref={statusRef}
              className="auth-submit-note"
              role="status"
              tabIndex={-1}
              aria-live="polite"
            >
              <p>{t("sentP1")}</p>
              <p>{t("sentP2")}</p>
            </div>
          ) : (
            <>
              {error && (
                <div
                  ref={statusRef}
                  className="auth-alert"
                  role="alert"
                  tabIndex={-1}
                  aria-live="assertive"
                >
                  {error}
                </div>
              )}

              <form className="auth-form" onSubmit={handleSubmit} noValidate>
                <div className="auth-field">
                  <label className="auth-field__label" htmlFor="forgot-email">
                    {t("fieldEmail")}
                  </label>
                  <input
                    id="forgot-email"
                    name="email"
                    className="auth-input"
                    type="email"
                    placeholder="you@example.com"
                    value={email}
                    onChange={(event) => {
                      setEmail(event.target.value);
                      setError(null);
                    }}
                    autoComplete="email"
                    required
                  />
                  <span className="auth-field__hint">{t("emailFallbackHint")}</span>
                </div>

                <button
                  type="submit"
                  className="auth-submit"
                  disabled={loading}
                  aria-busy={loading}
                >
                  {loading ? t("sending") : t("submit")}
                </button>
              </form>
            </>
          )}
        </details>

        <p className="auth-switch">
          <Link className="auth-switch__action auth-inline-link" href="/login">
            {t("backToLogin")}
          </Link>
        </p>
      </div>
    </AuthShell>
  );
}
