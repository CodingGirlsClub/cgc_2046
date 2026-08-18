"use client";

import { useId } from "react";
import AuthForm, { type AuthMode } from "./login/auth-form";
import { useAuthSubmit } from "./login/use-auth-submit";
import LanguageSwitcher from "@/components/language-switcher";

function BrandMark() {
  return (
    <span className="auth-brand-mark" aria-hidden="true">
      <span className="auth-brand-mark__cell auth-brand-mark__cell--left" />
      <span className="auth-brand-mark__cell auth-brand-mark__cell--right" />
      <span className="auth-brand-mark__cell auth-brand-mark__cell--bottom" />
    </span>
  );
}

function FeatureIcon({ kind }: { kind: "identity" | "workspaces" | "profile" }) {
  return (
    <span className="auth-feature-icon" aria-hidden="true">
      {kind === "identity" && (
        <svg viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="1.6">
          <circle cx="12" cy="8" r="3.2" />
          <path d="M5.5 19.5c.9-3.1 3.2-4.8 6.5-4.8s5.6 1.7 6.5 4.8" />
        </svg>
      )}
      {kind === "workspaces" && (
        <svg viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="1.6">
          <rect x="4" y="4" width="6" height="6" rx="1" />
          <rect x="14" y="4" width="6" height="6" rx="1" />
          <rect x="4" y="14" width="6" height="6" rx="1" />
          <rect x="14" y="14" width="6" height="6" rx="1" />
        </svg>
      )}
      {kind === "profile" && (
        <svg viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="1.6">
          <path d="M3.5 7.5h6l1.8 2h9.2v9.1a2 2 0 0 1-2 2H5.5a2 2 0 0 1-2-2V7.5Z" />
          <path d="M3.5 7.5V5.8a1.8 1.8 0 0 1 1.8-1.8h4.2l1.8 2h6.9a2 2 0 0 1 2 2v1.5" />
        </svg>
      )}
    </span>
  );
}

function AuthHelpLink() {
  const helpId = useId();

  return (
    <a
      className="auth-help"
      href={`#${helpId}`}
      onClick={(event) => event.preventDefault()}
    >
      <span className="auth-help__icon" aria-hidden="true">?</span>
      帮助中心
    </a>
  );
}

function RegisterBenefits() {
  return (
    <div className="auth-benefits" aria-label="注册账号的好处">
      <div className="auth-benefit">
        <FeatureIcon kind="identity" />
        <div>
          <h2>统一身份</h2>
          <p>使用同一账号与密码，安全访问 CGC 平台及所有功能。</p>
        </div>
      </div>
      <div className="auth-benefit">
        <FeatureIcon kind="workspaces" />
        <div>
          <h2>多工作区</h2>
          <p>一个账号可加入多个 Workspace，灵活切换，高效协作。</p>
        </div>
      </div>
      <div className="auth-benefit">
        <FeatureIcon kind="profile" />
        <div>
          <h2>资料随行</h2>
          <p>你的设置与偏好随账号同步，在不同工作区中无缝延续。</p>
        </div>
      </div>
    </div>
  );
}

export default function AuthShell({ mode }: { mode: AuthMode }) {
  const { onSubmit, busy, error } = useAuthSubmit();
  const isRegister = mode === "register";

  return (
    <div className={`auth-page ${isRegister ? "auth-page--register" : "auth-page--login"}`}>
      <aside className="auth-brand-panel" aria-label="CGC 平台介绍">
        <div className="auth-brand-lockup">
          <BrandMark />
          <span>CGC 2046</span>
        </div>

        <div className="auth-brand-copy">
          <h1>{isRegister ? "一个账号，连接多个工作区" : "连接社区，也连接你的创造力"}</h1>
          {isRegister && <RegisterBenefits />}
        </div>
      </aside>

      <main className="auth-form-panel">
        <div className="flex justify-end">
          <LanguageSwitcher />
        </div>
        <AuthHelpLink />
        <section className="auth-form-card" aria-labelledby="auth-page-title">
          <div className="auth-form-heading">
            <h2 id="auth-page-title">{isRegister ? "创建账号" : "登录"}</h2>
          </div>
          <AuthForm mode={mode} onSubmit={onSubmit} busy={busy} error={error} />
        </section>
      </main>
    </div>
  );
}
