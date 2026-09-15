"use client";

/**
 * 核销码出示卡（押金制 KTD5/KTD10；R11）：6 位码 + 承载核销 URL 的二维码 +
 * 「请勿截图转发」提示。参与者面共用（/participations 报名卡、公开详情页本人卡）。
 *
 * 码由后端字段级 resolve 门控（仅本人 confirmed 活动报名返回），本组件只负责
 * 展示——调用方负责 confirmed 与非空门控。
 */

import { useLocale, useTranslations } from "next-intl";
import { buildCheckInPath } from "@/lib/check-in";
import { useQrDataUrl } from "@/lib/use-qr-data-url";

export default function CheckInCodeCard({
  code,
  eventSegment,
  paymentMode = null,
}: {
  /** 6 位核销码（字符串，前导零有意义） */
  code: string;
  /** 核销 URL 路段：event slug（公开详情页）或 event id（报名卡只有 eventId） */
  eventSegment: string;
  /** 目标缴费模式（U3：deposit 时多一行「核销后押金原路退回」承诺句） */
  paymentMode?: string | null;
}) {
  const t = useTranslations("checkIn");
  const locale = useLocale();
  const path = buildCheckInPath(locale, eventSegment, code);
  // 生成失败返回 null：仍出示 6 位码（主理人可手输，KTD5「扫码失败补救」）
  const qrDataUrl = useQrDataUrl(path, 160);

  return (
    <div
      className="mt-3 rounded-large border border-line bg-soft-2 p-3"
      data-testid="check-in-code"
    >
      <p className="text-xs text-ink-3">{t("cardLabel")}</p>
      <div className="mt-2 flex flex-wrap items-center gap-4">
        <p
          className="text-2xl font-semibold tracking-[0.2em] text-ink"
          data-testid="check-in-code-value"
        >
          {code}
        </p>
        {qrDataUrl ? (
          // eslint-disable-next-line @next/next/no-img-element
          <img
            src={qrDataUrl}
            alt={t("qrAlt")}
            width={160}
            height={160}
            data-testid="check-in-qr"
            className="rounded-large border border-line bg-white p-1.5"
          />
        ) : (
          <div className="grid h-[160px] w-[160px] place-items-center rounded-large border border-line bg-card text-center text-xs text-ink-3">
            {t("qrGenerating")}
          </div>
        )}
      </div>
      {paymentMode === "deposit" ? (
        <p
          className="mt-2 text-[12px] leading-5 text-emerald-300"
          data-testid="check-in-deposit-hint"
        >
          {t("depositRefundHint")}
        </p>
      ) : null}
      <p className="mt-2 text-[12px] leading-5 text-ink-3">
        {t("keepPrivateHint")}
      </p>
    </div>
  );
}
