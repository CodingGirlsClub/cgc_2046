import { describe, it, expect } from "vitest";
import { translatePaymentError } from "./payment-errors";

describe("translatePaymentError（支付/报名错误翻译层）", () => {
  it.each([
    // [原文（后端 domain_error_message / Ecto unique），期望人话]
    ["has already been taken", "你已有待支付订单，请关闭后重新打开继续支付。"],
    [
      "enrollment is not awaiting payment",
      "报名状态已变化（已支付或已取消），请重新报名或查看我的报名。",
    ],
    ["enrollment does not exist", "报名不存在或已被处理，请查看我的报名。"],
    [
      "enrollment has already been processed",
      "该报名已处理完成，请查看我的报名。",
    ],
    // 未签约渠道：adapter 落 inspect 兜底的裸原子
    ["provider_not_configured", "该支付渠道暂未开通，请选择其他方式。"],
    ["capacity is full", "名额已满，报名已截止。"],
    [
      "target is not open or registration deadline passed",
      "报名已截止或活动未开放。",
    ],
    ["invite code is required", "该报名需要邀请码，请输入后提交。"],
    ["invite quota is unavailable", "邀请名额已用完，请联系组织者。"],
    [
      "a price tier is required for paid enrollment",
      "该报名为收费项，请先选择价格档位。",
    ],
    [
      "selected price tier is not available",
      "所选档位已过期或不可用，请重新选择。",
    ],
    ["enrollment_id is required", "缺少报名信息，请重新发起报名。"],
  ])("映射：%s → %s", (raw, expected) => {
    expect(translatePaymentError(raw, "兜底文案")).toBe(expected);
  });

  it("大小写不敏感：大写原文同样命中", () => {
    expect(
      translatePaymentError("Enrollment Is Not Awaiting Payment", "兜底"),
    ).toBe("报名状态已变化（已支付或已取消），请重新报名或查看我的报名。");
  });

  it("未知错误 / null / 空串 → 兜底文案（不透传原文）", () => {
    expect(
      translatePaymentError("some unknown english error", "提交失败"),
    ).toBe("提交失败");
    expect(translatePaymentError(null, "提交失败")).toBe("提交失败");
    expect(translatePaymentError("", "提交失败")).toBe("提交失败");
    expect(translatePaymentError(undefined, "提交失败")).toBe("提交失败");
  });
});
