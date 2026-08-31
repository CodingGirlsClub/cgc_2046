"use client";

import { useId, useState, type ReactNode } from "react";
import { useTranslations } from "next-intl";
import { useSearchParams } from "next/navigation";
import AuthForm, { type AuthMode } from "./login/auth-form";
import RegisterPhoneForm from "./login/register-phone-form";
import SmsForm from "./login/sms-form";
import WechatQrPanel from "./login/wechat-qr-panel";
import { useAuthSubmit } from "./login/use-auth-submit";
import LanguageSwitcher from "@/components/language-switcher";
import { BrandLockup } from "@/components/brand";
import { Link } from "@/i18n/navigation";

type LoginMethod = "password" | "sms";

function LoginMethodTabs({
	method,
	onChange,
}: {
	method: LoginMethod;
	onChange: (method: LoginMethod) => void;
}) {
	const t = useTranslations("auth.tabs");
	const methods: LoginMethod[] = ["password", "sms"];

	return (
		<div className="auth-tabs" role="tablist" aria-label={t("label")}>
			{methods.map((item) => (
				<button
					key={item}
					type="button"
					role="tab"
					aria-selected={method === item}
					className={`auth-tab ${method === item ? "auth-tab--active" : ""}`}
					onClick={() => onChange(item)}
				>
					{t(item)}
				</button>
			))}
		</div>
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

/**
 * auth 全家壳：topbar（帮助 + 语言）+ 品牌分屏 + 表单卡。
 * login/register 走内置表单；children 供同族流程页（忘记密码 / 重置密码）
 * 复用同一壳层，auth 页面间换壳零跳变。
 */
export default function AuthShell({
	mode,
	children,
}: {
	mode: AuthMode;
	children?: ReactNode;
}) {
  const { onSubmit, busy, error } = useAuthSubmit();
  const isRegister = mode === "register";
  const [loginMethod, setLoginMethod] = useState<LoginMethod>("password");
  const t = useTranslations("auth");
  const bindT = useTranslations("auth.wechatCallback");
  // 微信扫码 NEEDS_BINDING → /login?bind_ticket=：tabs 区原地切绑定表单
  // （卡片壳/品牌区/QR 面板一帧不动，用户无换页感）
  const bindTicket = useSearchParams()?.get("bind_ticket") ?? undefined;

  return (
    <div className={`auth-page ${isRegister ? "auth-page--register" : "auth-page--login"}`}>
      <div className="auth-topbar">
        <AuthHelpLink />
        <LanguageSwitcher />
      </div>
      <aside className="auth-brand-panel" aria-label={t("brandPanelLabel")}>
        <Link href="/" className="auth-brand-lockup">
          <BrandLockup />
        </Link>

        <div className="auth-brand-copy">
          <h1>{isRegister ? t("brandCopy.registerTitle") : t("brandCopy.loginTitle")}</h1>
          {isRegister && <RegisterBenefits />}
        </div>
      </aside>

      <main className="auth-form-panel">
        <section className="auth-form-card" aria-labelledby="auth-page-title">
          {children ?? (isRegister ? (
            <>
              <div className="auth-form-heading">
                <h2 id="auth-page-title">{t("heading.register")}</h2>
              </div>
              <RegisterPhoneForm />
            </>
          ) : (
            <div className="auth-login-split">
              <div className="auth-login-split__main">
                {bindTicket ? (
                  <>
                    <div className="auth-form-heading">
                      <h2 id="auth-page-title">{bindT("bindTitle")}</h2>
                    </div>
                    <SmsForm bindTicket={bindTicket} />
                  </>
                ) : (
                  <>
                    <div className="auth-form-heading">
                      <h2 id="auth-page-title">{t("heading.login")}</h2>
                    </div>
                    <LoginMethodTabs method={loginMethod} onChange={setLoginMethod} />
                    {loginMethod === "password" && (
                      <AuthForm onSubmit={onSubmit} busy={busy} error={error} />
                    )}
                    {loginMethod === "sms" && <SmsForm />}
                  </>
                )}
              </div>
              <aside className="auth-login-split__side" aria-label={t("wechat.sideLabel")}>
                {/* 绑定会话进行中不得再发起新扫码会话：wechatLoginStart 会下发
                    新 cgc_wechat_state cookie 覆盖旧 state，bind 请求
                    browser_mismatch 必败（生产事故 2026-08-31）。 */}
                {bindTicket ? (
                  <div className="auth-wechat-panel">
                    <p className="auth-wechat-hint" aria-live="polite">
                      {t("wechat.bindingInProgress")}
                    </p>
                  </div>
                ) : (
                  <WechatQrPanel />
                )}
              </aside>
            </div>
          ))}
        </section>
      </main>
    </div>
  );
}
