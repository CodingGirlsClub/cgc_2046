import { describe, it, expect } from "vitest";
import { translatePaymentError } from "./payment-errors";

describe("translatePaymentError（支付/报名错误翻译层，code 精确匹配）", () => {
  it.each([
    // [后端业务 code，期望人话]
    ["enrollment_duplicate_active", "你已有待支付订单，请关闭后重新打开继续支付。"],
    ["order_duplicate_active", "你已有待支付订单，请关闭后重新打开继续支付。"],
    ["order_not_payment_pending", "报名状态已变化（已支付或已取消），请重新报名或查看我的报名。"],
    [
      "enrollment_not_payment_pending",
      "报名状态已变化（已支付或已取消），请重新报名或查看我的报名。",
    ],
    ["order_enrollment_not_found", "报名不存在或已被处理，请查看我的报名。"],
    [
      "enrollment_already_processed",
      "该报名已处理完成，请查看我的报名。",
    ],
    ["order_already_processed", "该订单已处理，请刷新查看状态。"],
    ["order_provider_not_configured", "该支付渠道暂未开通，请选择其他方式。"],
    [
      "enrollment_capacity_full_or_registration_closed",
      "名额已满，报名已截止。",
    ],
    [
      "enrollment_target_not_open_or_registration_closed",
      "报名已截止或活动未开放。",
    ],
    ["enrollment_invite_code_required", "该报名需要邀请码，请输入后提交。"],
    ["enrollment_invite_quota_unavailable", "邀请名额已用完，请联系组织者。"],
    ["enrollment_tier_id_required", "该报名为收费项，请先选择价格档位。"],
    ["enrollment_tier_not_available", "所选档位已过期或不可用，请重新选择。"],
    ["order_enrollment_required", "缺少报名信息，请重新发起报名。"],
  ])("映射：%s → %s", (code, expected) => {
    expect(translatePaymentError(code, "兜底文案")).toBe(expected);
  });

  it("未知 code → 兜底文案（不透传 code/原文）", () => {
    expect(translatePaymentError("some_unknown_code", "提交失败")).toBe(
      "提交失败",
    );
  });

  it("大小写敏感：code 变体不误命中（精确匹配，无前缀子串）", () => {
    expect(
      translatePaymentError("ENROLLMENT_TIER_NOT_AVAILABLE", "兜底"),
    ).toBe("兜底");
    expect(translatePaymentError("enrollment_tier_not", "兜底")).toBe("兜底");
  });

  it("null / 空串 / undefined → 兜底文案", () => {
    expect(translatePaymentError(null, "提交失败")).toBe("提交失败");
    expect(translatePaymentError("", "提交失败")).toBe("提交失败");
    expect(translatePaymentError(undefined, "提交失败")).toBe("提交失败");
  });
});
