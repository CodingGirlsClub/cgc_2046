import { cleanup } from "@testing-library/react";
import { afterEach, describe, expect, it } from "vitest";
import { renderHook } from "@/test-utils";
import { usePaymentErrorTranslator } from "./payment-errors";

/** hook 需在 NextIntlClientProvider 内渲染（errors namespace 来自 zh-CN messages） */
function setup() {
	const { result } = renderHook(() => usePaymentErrorTranslator(), {
		locale: "zh-CN",
	});
	return result.current;
}

afterEach(cleanup);

describe("usePaymentErrorTranslator（i18n Phase 3：errors namespace 迁移）", () => {
	it("已知 code 精确匹配 → zh-CN 文案（与 PR #227 表逐键一致）", () => {
		const translate = setup();

		expect(translate("enrollment_duplicate_active", "兜底")).toBe(
			"你已有待支付订单，请关闭后重新打开继续支付。",
		);
		expect(translate("order_provider_not_configured", "兜底")).toBe(
			"该支付渠道暂未开通，请选择其他方式。",
		);
		expect(translate("order_enrollment_required", "兜底")).toBe(
			"缺少报名信息，请重新发起报名。",
		);
	});

	it("messages errors namespace 覆盖 PR #227 全部 15 键", () => {
		const translate = setup();
		const codes = [
			"enrollment_duplicate_active",
			"enrollment_not_payment_pending",
			"order_not_payment_pending",
			"order_enrollment_not_found",
			"order_duplicate_active",
			"enrollment_already_processed",
			"order_already_processed",
			"order_provider_not_configured",
			"enrollment_capacity_full_or_registration_closed",
			"enrollment_target_not_open_or_registration_closed",
			"enrollment_invite_code_required",
			"enrollment_invite_quota_unavailable",
			"enrollment_tier_id_required",
			"enrollment_tier_not_available",
			"order_enrollment_required",
		];
		for (const code of codes) {
			expect(translate(code, "兜底")).not.toBe("兜底");
		}
	});

	it("未知 code 走调用方兜底，不透传原文", () => {
		const translate = setup();
		expect(translate("some_unknown_code", "提交失败")).toBe("提交失败");
	});

	it("code 匹配大小写敏感（snake_case 契约）", () => {
		const translate = setup();
		expect(translate("ENROLLMENT_TIER_NOT_AVAILABLE", "兜底")).toBe("兜底");
		expect(translate("enrollment_tier_not", "兜底")).toBe("兜底");
	});

	it("null / 空串 / undefined 直接返回兜底", () => {
		const translate = setup();
		expect(translate(null, "提交失败")).toBe("提交失败");
		expect(translate("", "提交失败")).toBe("提交失败");
		expect(translate(undefined, "提交失败")).toBe("提交失败");
	});
});
