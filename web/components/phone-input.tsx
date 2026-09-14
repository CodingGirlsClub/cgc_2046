"use client";

/**
 * 国际化手机号输入（注册 / 验证码登录 / 微信绑定 / 设置换绑共用）。
 *
 * - 国家/地区选择 + 本机号输入，受控产出 E.164 规范形（`+<区号><号码>`），
 *   对齐后端 `PhoneNumber.parse/1` 的「`+` 前缀 → E.164」契约——GraphQL 面
 *   零新参数，裸号输入仍走后端 +86 默认（既有行为不变）。
 * - 号码校验用 libphonenumber-js（isValidPhoneNumber）；错误文案由调用方用
 *   `auth.sms.errorInvalidPhone` 提示（沿用既有表单 alert 通道）。
 * - 国名展示走 Intl.DisplayNames（浏览器内置 locale 数据，不进 bundle）；
 *   文案 key `auth.sms.countryLabel` 双语齐备（i18n AST 脚本强制 parity）。
 */

import { useMemo, useState } from "react";
import {
	getCountries,
	getCountryCallingCode,
	isValidPhoneNumber,
	type CountryCode,
} from "libphonenumber-js";
import { useLocale, useTranslations } from "next-intl";

/** 本机号 + 地区 → E.164 规范形；空输入返回 ""（空值语义由调用方决定）。 */
export function composeE164(country: CountryCode, raw: string): string {
	// 剥非数字 + 去首位长途前缀 0（E.164 不含 trunk prefix；+86 移动号 1 开头不受影响）
	const digits = raw
		.replace(/\D/g, "")
		.replace(/^0+(?=.)/, "");
	if (!digits) return "";
	return `+${getCountryCallingCode(country)}${digits}`;
}

/** E.164 有效性校验（"" 视为未填，required 语义由调用方处理）。 */
export function isValidPhone(e164: string): boolean {
	return e164 !== "" && isValidPhoneNumber(e164);
}

function regionFlag(countryCode: string): string {
	return String.fromCodePoint(
		...[...countryCode].map((ch) => 0x1f1e6 + ch.charCodeAt(0) - 65),
	);
}

/** 国家/地区下拉：flag + 本化国名 + 区号（按本化国名排序）。 */
export function CountrySelect({
	value,
	onChange,
	className,
	ariaLabel,
}: {
	value: CountryCode;
	onChange: (country: CountryCode) => void;
	className?: string;
	ariaLabel?: string;
}) {
	const locale = useLocale();

	const options = useMemo(() => {
		const displayNames = new Intl.DisplayNames([locale], { type: "region" });
		const collator = new Intl.Collator(locale);

		return getCountries()
			.map((country) => ({
				country,
				label: `${regionFlag(country)} ${displayNames.of(country) ?? country} +${getCountryCallingCode(country)}`,
			}))
			.sort((a, b) => collator.compare(a.label, b.label));
	}, [locale]);

	return (
		<select
			className={className}
			aria-label={ariaLabel}
			value={value}
			onChange={(event) => onChange(event.target.value as CountryCode)}
		>
			{options.map(({ country, label }) => (
				<option key={country} value={country}>
					{label}
				</option>
			))}
		</select>
	);
}

export default function PhoneInput({
	id,
	name = "phone",
	value,
	onChange,
	placeholder,
	autoComplete = "tel",
	autoFocus = false,
	required = false,
	variant = "auth",
}: {
	id: string;
	name?: string;
	/** E.164 规范形（composeE164 产出）；"" 为空。 */
	value: string;
	onChange: (e164: string) => void;
	placeholder?: string;
	autoComplete?: string;
	autoFocus?: boolean;
	required?: boolean;
	/** auth：登录/注册页 .auth-* 行；profile：设置页 .profile-* 行（input 无类名，
		吃 .profile-edit-layout input 的既有描边风格）。 */
	variant?: "auth" | "profile";
}) {
	const rowClassName = variant === "profile" ? "profile-phone-row" : "auth-phone-row";
	const selectClassName =
		variant === "profile" ? undefined : "auth-phone-select";
	const inputClassName = variant === "profile" ? undefined : "auth-input";
	const locale = useLocale();
	const t = useTranslations("auth.sms");
	const [country, setCountry] = useState<CountryCode>(
		locale.startsWith("zh") ? "CN" : "US",
	);

	const dial = getCountryCallingCode(country);
	// 受控回显：value 恒由本组件产出（+区号前缀），剥离即得输入框内容
	const national = value.startsWith(`+${dial}`) ? value.slice(dial.length + 1) : "";

	return (
		<div className={rowClassName}>
			<CountrySelect
				className={selectClassName}
				ariaLabel={t("countryLabel")}
				value={country}
				onChange={(next) => {
					setCountry(next);
					onChange(composeE164(next, national));
				}}
			/>
			<input
				id={id}
				name={name}
				className={inputClassName}
				type="tel"
				placeholder={placeholder}
				value={national}
				onChange={(event) => onChange(composeE164(country, event.target.value))}
				autoComplete={autoComplete}
				autoFocus={autoFocus}
				required={required}
			/>
		</div>
	);
}
