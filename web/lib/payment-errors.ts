"use client";

/**
 * 支付/报名 GraphQL 错误翻译层（i18n Phase 0 → Phase 3 迁移）。
 *
 * 背景：AshGraphql mutation 的业务错误经 BusinessError 携带稳定 code
 * （`<resource>_<reason>` snake_case，backend/lib/cgc_2046/errors/business_error.ex）。
 *
 * i18n Phase 3 起文案表迁入 messages 的 errors namespace（key 沿用 code 值），
 * 本层改为 next-intl hook：已知 code 查当前 locale 文案；未知 code / 无 code
 * 走调用方兜底，不透传英文原文。en 上线门槛 = 100% key 覆盖由
 * scripts/check-i18n-keys.mjs 在 CI 强制。
 *
 * 与小程序同文案互指：miniprogram/src/domain/error-copy.ts（两端各自换
 * locale 消息文件时同步替换）。
 */

import { useCallback } from "react";
import { useTranslations } from "next-intl";

type ErrorCode = string | null | undefined;

/**
 * 错误翻译 hook。返回 (code, fallback) => string：
 * 已知 code → 当前 locale 的 errors.<code> 文案；未知 / null → fallback。
 * 调用点保持 (code, fallback) 签名，与旧纯函数一致。
 */
export function usePaymentErrorTranslator() {
	const t = useTranslations("errors");

	return useCallback(
		(code: ErrorCode, fallback: string): string => {
			if (!code) return fallback;
			return t.has(code) ? t(code) : fallback;
		},
		[t],
	);
}
