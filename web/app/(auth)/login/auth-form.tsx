"use client";

import { useState } from "react";

export type AuthMode = "login" | "register";

export interface AuthSubmitPayload {
  mode: AuthMode;
  nickname?: string;
  email: string;
  password: string;
}

/**
 * 登录/注册表单（#61 A-2-FE 静态骨架）。
 *
 * 形态与 prototype-m0/app/prototype/auth/page.tsx 的 AuthForm 一致（Linear 双主题）。
 * 静态阶段：提交仅本地提示；#60（signIn/signUp mutation）就绪后，
 * 由页面传入真实 onSubmit（走 lib/graphql/auth.ts + setAuthToken 写 cookie）。
 */
export default function AuthForm({
  mode,
  setMode,
  onSubmit,
  busy,
  error,
}: {
  mode: AuthMode;
  setMode: (m: AuthMode) => void;
  onSubmit?: (payload: AuthSubmitPayload) => Promise<void>;
  busy?: boolean;
  /** 后端返回的错误提示（signUp: result.errors / signIn: ApolloError） */
  error?: string | null;
}) {
  const [submitted, setSubmitted] = useState(false);
  const [nickname, setNickname] = useState("");
  const [email, setEmail] = useState("");
  const [password, setPassword] = useState("");

  const handleSubmit = async (e: React.FormEvent) => {
    e.preventDefault();
    if (onSubmit) {
      await onSubmit({ mode, nickname: nickname || undefined, email, password });
    } else {
      setSubmitted(true);
    }
  };

  return (
    <div>
      <div className="flex rounded-[6px] bg-soft p-0.5 ring-1 ring-line">
        {(["login", "register"] as const).map((m) => (
          <button
            key={m}
            type="button"
            onClick={() => setMode(m)}
            className={`flex-1 rounded-[5px] py-1.5 text-[13px] font-[510] transition ${
              mode === m ? "bg-view text-ink ring-1 ring-line" : "text-ink-3 hover:text-ink-2"
            }`}
          >
            {m === "login" ? "登录" : "注册"}
          </button>
        ))}
      </div>

      <form className="mt-5 space-y-3" onSubmit={handleSubmit}>
        {error && (
          <div
            role="alert"
            className="rounded-[6px] bg-red-50 px-3 py-2 text-xs text-red-700 ring-1 ring-red-200 dark:bg-red-950/40 dark:text-red-300 dark:ring-red-900"
          >
            {error}
          </div>
        )}
        {mode === "register" && (
          <div>
            <label className="l-overline block" htmlFor="auth-nickname">
              昵称
            </label>
            <input
              id="auth-nickname"
              className="l-input mt-1 w-full"
              placeholder="你的昵称"
              value={nickname}
              onChange={(e) => setNickname(e.target.value)}
            />
          </div>
        )}
        <div>
          <label className="l-overline block" htmlFor="auth-email">
            邮箱
          </label>
          <input
            id="auth-email"
            className="l-input mt-1 w-full"
            type="email"
            placeholder="you@example.com"
            value={email}
            onChange={(e) => setEmail(e.target.value)}
          />
        </div>
        <div>
          <div className="flex items-center justify-between">
            <label className="l-overline block" htmlFor="auth-password">
              密码
            </label>
            {mode === "login" && (
              <button type="button" className="text-xs text-accent transition hover:text-accent-mention">
                忘记密码？
              </button>
            )}
          </div>
          <input
            id="auth-password"
            className="l-input mt-1 w-full"
            type="password"
            placeholder="••••••••"
            value={password}
            onChange={(e) => setPassword(e.target.value)}
          />
        </div>
        <button type="submit" className="l-btn-primary w-full justify-center" disabled={busy}>
          {busy ? "处理中…" : mode === "login" ? "登录" : "创建账号"}
        </button>
      </form>

      {submitted && !onSubmit && (
        <div className="l-p mt-3 rounded-[6px] bg-soft p-3 text-xs text-ink-2 ring-1 ring-line">
          （mock）提交成功——正式版经 signIn / signUp mutation 登录，token 写入{" "}
          <span className="l-code px-1 py-0.5">cgc_token</span> cookie。
        </div>
      )}

      <p className="l-p mt-4 text-center text-xs text-ink-3">
        {mode === "login" ? "还没有账号？" : "已有账号？"}{" "}
        <button
          type="button"
          onClick={() => setMode(mode === "login" ? "register" : "login")}
          className="l-link text-accent transition hover:text-accent-mention"
        >
          {mode === "login" ? "立即注册" : "去登录"}
        </button>
      </p>
    </div>
  );
}
