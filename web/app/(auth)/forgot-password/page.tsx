"use client";

import Link from "next/link";
import { useEffect, useRef, useState, type FormEvent } from "react";
import { useMutation } from "@apollo/client/react";
import {
  graphqlErrorDetails,
  REQUEST_PASSWORD_RESET,
} from "@/lib/graphql/auth";

export default function ForgotPasswordPage() {
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
        setError("发送重置邮件失败，请稍后重试");
      }
    } catch (reason) {
      const details = graphqlErrorDetails(reason);
      setError(
        details?.code === "rate_limited"
          ? "请求过于频繁，请稍后再试"
          : "发送重置邮件失败，请稍后重试",
      );
    }
  };

  return (
    <main className="auth-page auth-page--login">
      <section className="auth-form-panel">
        <div className="auth-form-card">
          <div className="auth-form-heading">
            <h2>找回密码</h2>
          </div>

          {submitted ? (
            <div
              ref={statusRef}
              className="auth-submit-note"
              role="status"
              tabIndex={-1}
              aria-live="polite"
            >
              <p>如果该邮箱已注册，重置链接已发送，请检查收件箱。</p>
              <p>如果没有收到邮件，请检查垃圾邮件，或稍后重新申请。</p>
              <Link className="auth-inline-link" href="/login">
                返回登录
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
                    注册邮箱
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
                    我们会向邮箱发送一次性密码重置链接。
                  </span>
                </div>

                <button
                  type="submit"
                  className="auth-submit"
                  disabled={loading}
                  aria-busy={loading}
                >
                  {loading ? "发送中…" : "发送重置邮件"}
                </button>
              </form>

              <p className="auth-switch">
                <Link className="auth-switch__action auth-inline-link" href="/login">
                  返回登录
                </Link>
              </p>
            </div>
          )}
        </div>
      </section>
    </main>
  );
}
