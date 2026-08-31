"use client";

import { Link } from "@/i18n/navigation";
import { useEffect, useRef, useState, type FormEvent } from "react";
import { useMutation } from "@apollo/client/react";
import { useTranslations } from "next-intl";
import {
  graphqlErrorDetails,
  REQUEST_PASSWORD_RESET,
} from "@/lib/graphql/auth";
import AuthShell from "../auth-shell";

export default function ForgotPasswordPage() {
  const t = useTranslations("auth.forgot");
  const [requestPasswordReset, { loading }] = useMutation(REQUEST_PASSWORD_RESET);
  const [email, setEmail] = useState("");
  const [submitted, setSubmitted] = useState(false);
  const [error, setError] = useState<string | null>(null);
  const statusRef = useRef<HTMLDivElement>(null);

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
          <Link className="auth-inline-link" href="/login">
            {t("backToLogin")}
          </Link>
        </div>
      ) : (
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
                autoFocus
                required
              />
              <span className="auth-field__hint">
                {t("hint")}
              </span>
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

          <p className="auth-switch">
            <Link className="auth-switch__action auth-inline-link" href="/login">
              {t("backToLogin")}
            </Link>
          </p>
        </div>
      )}
    </AuthShell>
  );
}
