"use client";

/**
 * 设置页语言小节（i18n Phase 1，ProfileSettingsForm aside 内）。
 *
 * select 变化即生效：写 cgc_locale cookie + updateMyLocale 持久化 +
 * 导航到对应 locale 前缀 URL（与 LanguageSwitcher 同一语义，下拉形态）。
 * 不进表单草稿/handleSave：语言是全局身份偏好，与 per-workspace 档案保存解耦。
 */

import { useLocale, useTranslations } from "next-intl";
import { usePathname, useRouter } from "@/i18n/navigation";
import { updateMyLocale } from "@/lib/profile";
import { writeLocaleCookie } from "@/lib/locale-cookie";
import { LOCALE_OPTIONS, type Locale } from "@/i18n/routing";

export function ProfileLocaleSelect() {
	const t = useTranslations("settings");
	const locale = useLocale();
	const router = useRouter();
	const pathname = usePathname();

	function onChange(next: string) {
		if (next === locale) return;
		const target = next as Locale;

		writeLocaleCookie(target);
		void updateMyLocale(target).catch(() => {
			// 静默：cookie 与 UI 已切换，DB 持久化失败下次切换重试
		});
		// F4：取 window 原始 search/hash 拼回 query（不重序列化，与 proxy
		// x-pathname 同一保真决策）
		const search = typeof window === "undefined" ? "" : window.location.search;
		const hash = typeof window === "undefined" ? "" : window.location.hash;
		router.replace(`${pathname}${search}${hash}`, { locale: target });
	}

	return (
		<label>
			<span className="profile-form-label">{t("languageLabel")}</span>
			<select
				data-testid="profile-locale-input"
				value={locale}
				onChange={(event) => onChange(event.target.value)}
			>
				{LOCALE_OPTIONS.map((option) => (
					<option key={option.value} value={option.value}>
						{option.label}
					</option>
				))}
			</select>
			<p className="text-[13px] text-ink-3">{t("languageDescription")}</p>
		</label>
	);
}
