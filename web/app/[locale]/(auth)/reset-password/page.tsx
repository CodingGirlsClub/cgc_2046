"use client";

import Link from "next/link";
import { useEffect, useRef, useState, type FormEvent } from "react";
import { useMutation } from "@apollo/client/react";
import {
  graphqlErrorDetails,
  RESET_PASSWORD,
} from "@/lib/graphql/auth";
import {
  PasswordField,
  PasswordStrength,
} from "../login/auth-form";

type ResetView = "loading" | "form" | "success" | "invalid";

export default function ResetPasswordPage() {
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
      setPasswordError("密码至少需要 8 个字符");
      return;
    }

    if (password !== confirmPassword) {
      setPasswordError("两次输入的密码不一致");
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
        setError("密码重置失败，请稍后重试");
      }
    } catch (reason) {
      const details = graphqlErrorDetails(reason);

      if (details?.code === "invalid_reset_token") {
        setView("invalid");
        return;
      }

      if (details?.fields?.includes("password")) {
        setPasswordError(details.message ?? "密码不符合要求");
        return;
      }

      setError(
        details?.code === "rate_limited"
          ? "请求过于频繁，请稍后再试"
          : "密码重置失败，请稍后重试",
      );
    }
  };

  return (
    <main className="auth-page auth-page--login">
      <meta name="referrer" content="no-referrer" />
      <section className="auth-form-panel">
        <div className="auth-form-card">
          <div className="auth-form-heading">
            <h2>{view === "success" ? "密码已重置" : "设置新密码"}</h2>
          </div>

          {view === "loading" && (
            <div className="auth-submit-note" role="status" aria-live="polite">
              正在检查重置链接…
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
              <p>链接无效或已过期。</p>
              <p>请重新申请密码重置邮件，或返回登录。</p>
              <p className="auth-switch">
                <Link className="auth-switch__action auth-inline-link" href="/forgot-password">
                  重新发送重置邮件
                </Link>
                <span aria-hidden="true"> · </span>
                <Link className="auth-switch__action auth-inline-link" href="/login">
                  返回登录
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
              <p>密码已更新。为安全起见，你已在所有设备（含小程序）退出登录。</p>
              <p className="auth-switch">
                <Link className="auth-switch__action auth-inline-link" href="/login">
                  去登录
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
                    新密码
                  </label>
                  <PasswordField
                    id="reset-password"
                    placeholder="至少 8 个字符"
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
                    确认新密码
                  </label>
                  <PasswordField
                    id="reset-confirm-password"
                    placeholder="再次输入密码"
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
                  {loading ? "保存中…" : "保存新密码"}
                </button>
              </form>
            </div>
          )}
        </div>
      </section>
    </main>
  );
}
