"use client";

import Link from "next/link";
import { useState, type FormEvent } from "react";
import { useSearchParams } from "next/navigation";

export type AuthMode = "login" | "register";

export interface AuthSubmitPayload {
  mode: AuthMode;
  /** 保留为兼容字段；注册页当前只收集邮箱和密码。 */
  nickname?: string;
  email: string;
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

function PasswordField({
  id,
  placeholder,
  value,
  onChange,
  visible,
  onToggle,
  autoComplete,
}: {
  id: string;
  placeholder: string;
  value: string;
  onChange: (value: string) => void;
  visible: boolean;
  onToggle: () => void;
  autoComplete: string;
}) {
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
        required
        minLength={8}
      />
      <button
        type="button"
        className="auth-password-toggle"
        onClick={onToggle}
        aria-label={visible ? "隐藏密码" : "显示密码"}
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

function PasswordStrength({ password }: { password: string }) {
  const score = passwordStrength(password);
  const label = score === 3 ? "强" : score === 2 ? "中" : score === 1 ? "弱" : "";
  const tone = score === 3 ? "strong" : score === 2 ? "medium" : "weak";

  return (
    <div className="auth-password-strength" aria-label={label ? `密码强度：${label}` : "密码强度未设置"}>
      <div className="auth-password-strength__bars" aria-hidden="true">
        {[1, 2, 3].map((level) => (
          <span
            key={level}
            className={level <= score ? `auth-password-strength__bar auth-password-strength__bar--${tone}` : "auth-password-strength__bar"}
          />
        ))}
      </div>
      <div className="auth-password-strength__labels" aria-hidden="true">
        {["弱", "中", "强"].map((item) => (
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
  const [email, setEmail] = useState("");
  const [password, setPassword] = useState("");
  const [confirmPassword, setConfirmPassword] = useState("");
  const [showPassword, setShowPassword] = useState(false);
  const [showConfirmPassword, setShowConfirmPassword] = useState(false);
  const [formError, setFormError] = useState<string | null>(null);
  const isRegister = mode === "register";

  const handleSubmit = async (event: FormEvent<HTMLFormElement>) => {
    event.preventDefault();
    setSubmitted(false);
    setFormError(null);

    if (isRegister && password.length < 8) {
      setFormError("密码至少需要 8 个字符");
      return;
    }
    if (isRegister && password !== confirmPassword) {
      setFormError("两次输入的密码不一致");
      return;
    }

    if (onSubmit) {
      await onSubmit({ mode, email, password });
    } else {
      setSubmitted(true);
    }
  };

  const switchLabel = isRegister ? "返回登录" : "创建账号";
  // 切换登录/注册保留 next（报名页引导链路不回丢）
  const searchParams = useSearchParams();
  const nextRaw = searchParams?.get("next") ?? null;
  const switchHref =
    (isRegister ? "/login" : "/register") +
    (nextRaw ? `?next=${encodeURIComponent(nextRaw)}` : "");
  const displayError = formError ?? error;

  return (
    <div className="auth-form-body">
      <form className="auth-form" onSubmit={handleSubmit} noValidate>
        {displayError && (
          <div role="alert" className="auth-alert">
            {displayError}
          </div>
        )}

        <div className="auth-field">
          <label className="auth-field__label" htmlFor="auth-email">邮箱</label>
          <input
            id="auth-email"
            name="email"
            className="auth-input"
            type="email"
            placeholder="you@example.com"
            value={email}
            onChange={(event) => {
              setEmail(event.target.value);
              setFormError(null);
            }}
            autoComplete="email"
            autoFocus
            required
          />
        </div>

        <div className="auth-field">
          <div className="auth-field__label-row">
            <label className="auth-field__label" htmlFor="auth-password">密码</label>
            {!isRegister && (
              <button type="button" className="auth-inline-link">
                忘记密码？
              </button>
            )}
          </div>
          <PasswordField
            id="auth-password"
            placeholder={isRegister ? "至少 8 个字符" : ""}
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
            <label className="auth-field__label" htmlFor="auth-confirm-password">确认密码</label>
            <PasswordField
              id="auth-confirm-password"
              placeholder="再次输入密码"
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
          {busy ? "处理中…" : isRegister ? "创建账号并继续" : "登录并进入工作台"}
        </button>
      </form>

      {submitted && !onSubmit && (
        <div className="auth-submit-note">
          （mock）提交成功——正式版经 signIn / signUp mutation 登录，token 写入 <code>cgc_token</code> cookie。
        </div>
      )}

      <p className="auth-switch">
        {isRegister ? "已经有账号？" : "还没有账号？"}{" "}
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

      <p className="auth-terms">
        {isRegister ? "注册" : "登录"}即表示你同意
        <a href="#terms" onClick={(event) => event.preventDefault()}>服务条款</a>
        与
        <a href="#privacy" onClick={(event) => event.preventDefault()}>隐私政策</a>
      </p>
    </div>
  );
}
