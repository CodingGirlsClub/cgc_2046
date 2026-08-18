"use client";

import { useId } from "react";
import { useTranslations } from "next-intl";
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
  const t = useTranslations("auth");

  return (
    <a
      className="auth-help"
      href={`#${helpId}`}
      onClick={(event) => event.preventDefault()}
    >
      <span className="auth-help__icon" aria-hidden="true">?</span>
      {t("helpCenter")}
    </a>
  );
}

function RegisterBenefits() {
  const t = useTranslations("auth");

  return (
    <div className="auth-benefits" aria-label={t("benefitsLabel")}>
      <div className="auth-benefit">
        <FeatureIcon kind="identity" />
        <div>
          <h2>{t("benefits.identityTitle")}</h2>
          <p>{t("benefits.identityDesc")}</p>
        </div>
      </div>
      <div className="auth-benefit">
        <FeatureIcon kind="workspaces" />
        <div>
          <h2>{t("benefits.workspacesTitle")}</h2>
          <p>{t("benefits.workspacesDesc")}</p>
        </div>
      </div>
      <div className="auth-benefit">
        <FeatureIcon kind="profile" />
        <div>
          <h2>{t("benefits.profileTitle")}</h2>
          <p>{t("benefits.profileDesc")}</p>
        </div>
      </div>
    </div>
  );
}

export default function AuthShell({ mode }: { mode: AuthMode }) {
  const { onSubmit, busy, error } = useAuthSubmit();
  const isRegister = mode === "register";
  const t = useTranslations("auth");

  return (
    <div className={`auth-page ${isRegister ? "auth-page--register" : "auth-page--login"}`}>
      <aside className="auth-brand-panel" aria-label={t("brandPanelLabel")}>
        <div className="auth-brand-lockup">
          <BrandMark />
          <span>CGC 2046</span>
        </div>

        <div className="auth-brand-copy">
          <h1>{isRegister ? t("brandCopy.registerTitle") : t("brandCopy.loginTitle")}</h1>
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
            <h2 id="auth-page-title">{isRegister ? t("heading.register") : t("heading.login")}</h2>
          </div>
          <AuthForm mode={mode} onSubmit={onSubmit} busy={busy} error={error} />
        </section>
      </main>
    </div>
  );
}
