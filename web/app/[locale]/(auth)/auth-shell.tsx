"use client";

import { useId, type ReactNode } from "react";
import { useTranslations } from "next-intl";
import { useSearchParams } from "next/navigation";
import AuthForm, { type AuthMode } from "./login/auth-form";
import LegacyWechatBindForm from "./login/legacy-wechat-bind-form";
import WechatQrPanel from "./login/wechat-qr-panel";
import { useAuthSubmit } from "./login/use-auth-submit";
import LanguageSwitcher from "@/components/language-switcher";
import { BrandLockup } from "@/components/brand";
import { Link } from "@/i18n/navigation";

function AuthHelpLink() {
  const helpId = useId();
  const t = useTranslations("auth");
  return <a className="auth-help" href={`#${helpId}`} onClick={event => event.preventDefault()}>
    <span className="auth-help__icon" aria-hidden="true">?</span>{t("helpCenter")}
  </a>;
}

/** Unified entry; children keep password recovery in the same brand shell. */
export default function AuthShell({ children }: { mode: AuthMode; children?: ReactNode }) {
  const { onSubmit, busy, error } = useAuthSubmit();
  const t = useTranslations("auth");
  const bindT = useTranslations("auth.wechatCallback");
  const bindTicket = useSearchParams()?.get("bind_ticket") ?? undefined;
  return (
    <div className="auth-page auth-page--login">
      <div className="auth-topbar"><AuthHelpLink /><LanguageSwitcher /></div>
      <aside className="auth-brand-panel" aria-label={t("brandPanelLabel")}>
        <Link href="/" className="auth-brand-lockup"><BrandLockup /></Link>
        <div className="auth-brand-copy"><h1>{t("brandCopy.loginTitle")}</h1></div>
      </aside>
      <main className="auth-form-panel">
        <section className="auth-form-card" aria-labelledby="auth-page-title">
          {children ?? (bindTicket ? (
            <>
              <div className="auth-form-heading"><h2 id="auth-page-title">{bindT("bindTitle")}</h2></div>
              <LegacyWechatBindForm bindTicket={bindTicket} />
              {/* A live OAuth binding must not launch a second browser login request. */}
              <p className="auth-wechat-hint">{t("wechat.bindingInProgress")}</p>
            </>
          ) : (
            <div className="auth-login-split">
              <div className="auth-login-split__main">
                <div className="auth-form-heading"><h2 id="auth-page-title">{t("unified.title")}</h2></div>
                <p className="auth-login-note">{t("unified.hint")}</p>
                <WechatQrPanel />
              </div>
              <aside className="auth-login-split__side" aria-labelledby="auth-password-title">
                <div className="auth-form-heading"><h2 id="auth-password-title">{t("unified.passwordTitle")}</h2></div>
                <p className="auth-login-note">{t("unified.passwordHint")}</p>
                <AuthForm onSubmit={onSubmit} busy={busy} error={error} />
              </aside>
            </div>
          ))}
        </section>
      </main>
    </div>
  );
}
