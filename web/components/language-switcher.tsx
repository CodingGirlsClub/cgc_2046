"use client";

/**
 * 语言切换器（i18n Phase 1，L0 决策 5）。
 *
 * 切换 = 写 cgc_locale cookie（365d）+（登录态）静默 updateMyLocale 持久化
 * + next-intl router.replace 导航到对应 locale 前缀 URL。
 *
 * cookie 必须先于导航写入：as-needed 下切回 zh-CN 的目标 URL 无前缀，
 * 中间件按 cookie 协商，若 cookie 仍是 en 会把 `/` 重定向回 `/en`。
 * 登录持久化是 fire-and-forget：UI 已切换，DB 写入失败不阻塞（下次切换重试）。
 */

import { useLocale, useTranslations } from "next-intl";
import { usePathname, useRouter } from "@/i18n/navigation";
import { useAuthed } from "@/lib/use-authed";
import { updateMyLocale } from "@/lib/profile";
import { type Locale } from "@/i18n/routing";
import { writeLocaleCookie } from "@/lib/locale-cookie";

/** locale → 稳定按钮文案（跨 locale 不变，中文页也显示 "English"） */
const LOCALE_LABEL: Record<Locale, string> = {
	"zh-CN": "中文",
	en: "English",
};

export default function LanguageSwitcher({ className = "" }: { className?: string }) {
	const t = useTranslations("language");
	const locale = useLocale();
	const router = useRouter();
	const pathname = usePathname();
	const { authed, confirmed } = useAuthed();

	function switchTo(next: Locale) {
		if (next === locale) return;

		writeLocaleCookie(next);

		if (confirmed && authed) {
			void updateMyLocale(next).catch(() => {
				// 静默：cookie 与 UI 已切换，DB 持久化失败下次切换重试
			});
		}

		router.replace(pathname, { locale: next });
	}

	return (
		<div
			className={`flex items-center gap-1 text-sm ${className}`}
			role="group"
			aria-label={t("label")}
		>
			{(Object.keys(LOCALE_LABEL) as Locale[]).map((code, index) => (
				<span key={code} className="flex items-center gap-1">
					{index > 0 && <span className="text-ink-3" aria-hidden="true">·</span>}
					<button
						type="button"
						onClick={() => switchTo(code)}
						aria-current={code === locale ? "true" : undefined}
						className={
							code === locale
								? "font-medium text-ink cursor-default"
								: "text-ink-3 hover:text-ink"
						}
					>
						{LOCALE_LABEL[code]}
					</button>
				</span>
			))}
		</div>
	);
}
