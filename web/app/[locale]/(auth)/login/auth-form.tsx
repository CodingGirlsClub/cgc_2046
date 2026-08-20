"use client";

import { Link } from "@/i18n/navigation";
import { useState, type FormEvent } from "react";
import { useTranslations } from "next-intl";
import { useSearchParams } from "next/navigation";

export type AuthMode = "login" | "register";

export interface AuthSubmitPayload {
  mode: AuthMode;
  /** 保留为兼容字段；注册页当前只收集邮箱和密码。 */
  nickname?: string;
  /** 登录标识：登录模式下为手机号或邮箱（signIn login 入参）；注册模式下为邮箱。 */
  login: string;
  password: string;
}

function EyeIcon({ visible }: { visible: boolean }) {
  return (
    <svg viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="1.7" aria-hidden="true">
      {visible ? (
        <>
          <path d="M2.8 12s3.2-5 9.2-5 9.2 5 9.2 5-3.2 5-9.2 5-9.2-5-9.2-5Z" />
          <circle cx="12" cy="12" r="2.3" />
        </>
      ) : (
        <>
          <path d="M3 3l18 18" />
          <path d="M10.6 6.9A9.7 9.7 0 0 1 12 6.8c5.9 0 9.2 5.2 9.2 5.2a16 16 0 0 1-3.1 3.4M6.1 7.7C3.9 9.1 2.8 12 2.8 12s3.2 5.2 9.2 5.2c1.3 0 2.5-.2 3.5-.6" />
        </>
      )}
    </svg>
  );
}

export function PasswordField({
  id,
  placeholder,
  value,
  onChange,
  visible,
  onToggle,
  autoComplete,
  ariaDescribedBy,
  ariaInvalid = false,
}: {
  id: string;
  placeholder: string;
  value: string;
  onChange: (value: string) => void;
  visible: boolean;
  onToggle: () => void;
  autoComplete: string;
  ariaDescribedBy?: string;
  ariaInvalid?: boolean;
}) {
  const t = useTranslations("auth");
  return (
    <div className="auth-input-wrap">
      <input
        id={id}
        name={id}
        className="auth-input auth-input--password"
        type={visible ? "text" : "password"}
        placeholder={placeholder}
        value={value}
        onChange={(event) => onChange(event.target.value)}
        autoComplete={autoComplete}
        aria-describedby={ariaDescribedBy}
        aria-invalid={ariaInvalid}
        required
        minLength={8}
      />
      <button
        type="button"
        className="auth-password-toggle"
        onClick={onToggle}
        aria-label={visible ? t("passwordToggle.hide") : t("passwordToggle.show")}
      >
        <EyeIcon visible={visible} />
      </button>
    </div>
  );
}

function passwordStrength(password: string) {
  if (!password) return 0;

  let score = password.length >= 8 ? 2 : 1;
  if (password.length >= 12 && /[A-Z]/.test(password) && /\d/.test(password)) {
    score = 3;
  }
  return score;
}

export function PasswordStrength({ password }: { password: string }) {
  const t = useTranslations("auth");
  const score = passwordStrength(password);
  const label =
    score === 3
      ? t("passwordStrength.strong")
      : score === 2
        ? t("passwordStrength.medium")
        : score === 1
          ? t("passwordStrength.weak")
          : "";
  const tone = score === 3 ? "strong" : score === 2 ? "medium" : "weak";

  return (
    <div
      className="auth-password-strength"
      aria-label={label ? t("passwordStrength.label", { label }) : t("passwordStrength.notSet")}
    >
      <div className="auth-password-strength__bars" aria-hidden="true">
        {[1, 2, 3].map((level) => (
          <span
            key={level}
            className={level <= score ? `auth-password-strength__bar auth-password-strength__bar--${tone}` : "auth-password-strength__bar"}
          />
        ))}
      </div>
      <div className="auth-password-strength__labels" aria-hidden="true">
        {[t("passwordStrength.weak"), t("passwordStrength.medium"), t("passwordStrength.strong")].map((item) => (
          <span key={item} className={item === label ? "auth-password-strength__label--active" : undefined}>
            {item}
          </span>
        ))}
      </div>
    </div>
  );
}

export default function AuthForm({
  mode,
  setMode,
  onSubmit,
  busy = false,
  error,
}: {
  mode: AuthMode;
  /** 仅供旧的组件测试/嵌入方使用；正式认证页通过路由切换。 */
  setMode?: (mode: AuthMode) => void;
  onSubmit?: (payload: AuthSubmitPayload) => Promise<void>;
  busy?: boolean;
  error?: string | null;
}) {
  const [submitted, setSubmitted] = useState(false);
  const [login, setLogin] = useState("");
  const [password, setPassword] = useState("");
  const [confirmPassword, setConfirmPassword] = useState("");
  const [showPassword, setShowPassword] = useState(false);
  const [showConfirmPassword, setShowConfirmPassword] = useState(false);
  const [formError, setFormError] = useState<string | null>(null);
  const isRegister = mode === "register";
  const t = useTranslations("auth");

  const handleSubmit = async (event: FormEvent<HTMLFormElement>) => {
    event.preventDefault();
    setSubmitted(false);
    setFormError(null);

    if (isRegister && password.length < 8) {
      setFormError(t("error.shortPassword"));
      return;
    }
    if (isRegister && password !== confirmPassword) {
      setFormError(t("error.passwordMismatch"));
      return;
    }

    if (onSubmit) {
      await onSubmit({ mode, login, password });
    } else {
      setSubmitted(true);
    }
  };

  const displayError = formError ?? error;
  const switchLabel = isRegister ? t("switch.returnLogin") : t("switch.createAccount");
  // 切换登录/注册保留 next（报名页引导链路不回丢）
  const searchParams = useSearchParams();
  const nextRaw = searchParams?.get("next") ?? null;
  const switchHref =
    (isRegister ? "/login" : "/register") +
    (nextRaw ? `?next=${encodeURIComponent(nextRaw)}` : "");

  return (
    <div className="auth-form-body">
      <form className="auth-form" onSubmit={handleSubmit} noValidate>
        {displayError && (
          <div role="alert" className="auth-alert">
            {displayError}
          </div>
        )}

        <div className="auth-field">
          <input
            id="auth-email"
            name="login"
            className="auth-input"
            type={isRegister ? "email" : "text"}
            placeholder={isRegister ? "you@example.com" : t("placeholder.login")}
            value={login}
            onChange={(event) => {
              setLogin(event.target.value);
              setFormError(null);
            }}
            autoComplete={isRegister ? "email" : "username"}
            autoFocus
            required
          />
        </div>

        <div className="auth-field">
          <PasswordField
            id="auth-password"
            placeholder={t("placeholder.password")}
            value={password}
            onChange={(value) => {
              setPassword(value);
              setFormError(null);
            }}
            visible={showPassword}
            onToggle={() => setShowPassword((current) => !current)}
            autoComplete={isRegister ? "new-password" : "current-password"}
          />
          {isRegister && <PasswordStrength password={password} />}
        </div>

        {isRegister && (
          <div className="auth-field">
            <PasswordField
              id="auth-confirm-password"
              placeholder={t("placeholder.confirmPassword")}
              value={confirmPassword}
              onChange={(value) => {
                setConfirmPassword(value);
                setFormError(null);
              }}
              visible={showConfirmPassword}
              onToggle={() => setShowConfirmPassword((current) => !current)}
              autoComplete="new-password"
            />
          </div>
        )}

        <button type="submit" className="auth-submit" disabled={busy} aria-busy={busy}>
          {busy
            ? t("submit.processing")
            : isRegister
              ? t("submit.registerAndContinue")
              : t("submit.loginAndEnter")}
        </button>
      </form>
      <p className="auth-switch">
        {!isRegister ? (
          <Link href="/forgot-password" className="auth-inline-link auth-switch__action">
            {t("forgotPassword")}
          </Link>
        ) : (
          <span aria-hidden="true" />
        )}
        {setMode ? (
          <button
            type="button"
            className="auth-inline-link auth-switch__action"
            onClick={() => setMode(isRegister ? "login" : "register")}
          >
            {switchLabel}
          </button>
        ) : (
          <Link href={switchHref} className="auth-inline-link auth-switch__action">
            {switchLabel}
          </Link>
        )}
      </p>

      {submitted && !onSubmit && (
        <div className="auth-submit-note">
          {t.rich("submitNoteMock", {
            code: (chunks) => <code>{chunks}</code>,
          })}
        </div>
      )}


      <p className="auth-terms">
        {isRegister ? t("terms.registerAction") : t("terms.loginAction")}{t("terms.agreePrefix")}
        <Link href="/terms">{t("terms.serviceTerms")}</Link>
        {t("terms.and")}
        <Link href="/privacy">{t("terms.privacyPolicy")}</Link>
      </p>
    </div>
  );
}
