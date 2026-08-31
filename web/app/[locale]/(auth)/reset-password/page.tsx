"use client";

import { Link } from "@/i18n/navigation";
import { useEffect, useRef, useState, type FormEvent } from "react";
import { useMutation } from "@apollo/client/react";
import { useTranslations } from "next-intl";
import {
  graphqlErrorDetails,
  RESET_PASSWORD,
} from "@/lib/graphql/auth";
import {
  PasswordField,
  PasswordStrength,
} from "../login/auth-form";
import AuthShell from "../auth-shell";

type ResetView = "loading" | "form" | "success" | "invalid";

export default function ResetPasswordPage() {
  const t = useTranslations("auth.reset");
  const authT = useTranslations("auth");
  const [resetPassword, { loading }] = useMutation(RESET_PASSWORD);
  const [view, setView] = useState<ResetView>("loading");
  const [token, setToken] = useState<string | null>(null);
  const [password, setPassword] = useState("");
  const [confirmPassword, setConfirmPassword] = useState("");
  const [passwordError, setPasswordError] = useState<string | null>(null);
  const [error, setError] = useState<string | null>(null);
  const [showPassword, setShowPassword] = useState(false);
  const [showConfirmPassword, setShowConfirmPassword] = useState(false);
  const statusRef = useRef<HTMLDivElement>(null);

  useEffect(() => {
    const url = new URL(window.location.href);
    const resetToken = url.searchParams.get("token");

    if (resetToken) {
      url.searchParams.delete("token");
      window.history.replaceState(window.history.state, "", `${url.pathname}${url.search}${url.hash}`);
    }

    const timer = window.setTimeout(() => {
      setToken(resetToken);
      setView(resetToken ? "form" : "invalid");
    }, 0);

    return () => window.clearTimeout(timer);
  }, []);

  useEffect(() => {
    if (view === "success" || view === "invalid" || error || passwordError) {
      statusRef.current?.focus();
    }
  }, [view, error, passwordError]);

  const handleSubmit = async (event: FormEvent<HTMLFormElement>) => {
    event.preventDefault();
    setError(null);
    setPasswordError(null);

    if (password.length < 8) {
      setPasswordError(t("errorShortPassword"));
      return;
    }

    if (password !== confirmPassword) {
      setPasswordError(t("errorPasswordMismatch"));
      return;
    }

    if (!token) {
      setView("invalid");
      return;
    }

    try {
      const { data } = await resetPassword({
        variables: { resetToken: token, password },
      });

      if (data?.resetPassword?.ok) {
        setView("success");
      } else {
        setError(t("errorFailed"));
      }
    } catch (reason) {
      const details = graphqlErrorDetails(reason);

      if (details?.code === "invalid_reset_token") {
        setView("invalid");
        return;
      }

      if (details?.fields?.includes("password")) {
        setPasswordError(details.message ?? t("errorInvalidPassword"));
        return;
      }

      setError(
        details?.code === "rate_limited"
          ? t("errorRateLimited")
          : t("errorFailed"),
      );
    }
  };

  return (
    <AuthShell mode="login">
      <meta name="referrer" content="no-referrer" />
      <div className="auth-form-heading">
        <h2 id="auth-page-title">
          {view === "success" ? t("titleSuccess") : t("titleForm")}
        </h2>
      </div>

      {view === "loading" && (
        <div className="auth-submit-note" role="status" aria-live="polite">
          {t("checking")}
        </div>
      )}

      {view === "invalid" && (
        <div
          ref={statusRef}
          className="auth-submit-note"
          role="status"
          tabIndex={-1}
          aria-live="polite"
        >
          <p>{t("invalidP1")}</p>
          <p>{t("invalidP2")}</p>
          <p className="auth-switch">
            <Link className="auth-switch__action auth-inline-link" href="/forgot-password">
              {t("resend")}
            </Link>
            <span aria-hidden="true"> · </span>
            <Link className="auth-switch__action auth-inline-link" href="/login">
              {t("backToLogin")}
            </Link>
          </p>
        </div>
      )}

      {view === "success" && (
        <div
          ref={statusRef}
          className="auth-submit-note"
          role="status"
          tabIndex={-1}
          aria-live="polite"
        >
          <p>{t("successP1")}</p>
          <p className="auth-switch">
            <Link className="auth-switch__action auth-inline-link" href="/login">
              {t("goLogin")}
            </Link>
          </p>
        </div>
      )}

      {view === "form" && (
        <div className="auth-form-body">
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
              <label className="auth-field__label" htmlFor="reset-password">
                {t("fieldNewPassword")}
              </label>
              <PasswordField
                id="reset-password"
                placeholder={authT("placeholder.passwordMin")}
                value={password}
                onChange={(value) => {
                  setPassword(value);
                  setPasswordError(null);
                }}
                visible={showPassword}
                onToggle={() => setShowPassword((current) => !current)}
                autoComplete="new-password"
                ariaDescribedBy={passwordError ? "reset-password-error" : undefined}
                ariaInvalid={Boolean(passwordError)}
              />
              <PasswordStrength password={password} />
            </div>

            <div className="auth-field">
              <label className="auth-field__label" htmlFor="reset-confirm-password">
                {t("fieldConfirmNewPassword")}
              </label>
              <PasswordField
                id="reset-confirm-password"
                placeholder={authT("placeholder.confirmPassword")}
                value={confirmPassword}
                onChange={(value) => {
                  setConfirmPassword(value);
                  setPasswordError(null);
                }}
                visible={showConfirmPassword}
                onToggle={() => setShowConfirmPassword((current) => !current)}
                autoComplete="new-password"
              />
            </div>

            {passwordError && (
              <div
                ref={statusRef}
                id="reset-password-error"
                className="auth-alert"
                role="alert"
                tabIndex={-1}
                aria-live="assertive"
              >
                {passwordError}
              </div>
            )}

            <button
              type="submit"
              className="auth-submit"
              disabled={loading}
              aria-busy={loading}
            >
              {loading ? t("saving") : t("submitSave")}
            </button>
          </form>
        </div>
      )}
    </AuthShell>
  );
}
