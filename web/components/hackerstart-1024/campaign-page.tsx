"use client";

import { useTranslations } from "next-intl";
import SiteHeader from "@/components/site-header";
import CampaignHero from "./hero";
import { FaqSection, JoinSection, WhyNowSection } from "./participant-sections";
import { TimelineSection, VolunteerSection } from "./volunteer-sections";
import { BrandSection, WhoWeAreSection } from "./brand-sections";
import "./hackerstart-1024.css";

/**
 * Hacker Start 1024 宣传页主体（R1-R7、R17、R18 的九段 IA）。
 *
 *   ① Hero（十周年封面 + 三入口 + 刻度条）→ ② 为什么是现在 → ③ 我要参加
 *   → ④ 参与者 FAQ → ⑤ 成为志愿者 → ⑥ 时间线 → ⑦ 我们是谁 → ⑧ 赞助合作
 *   → ⑨ 留存位（公众号）→ footer（含志愿者回链）
 *
 * 纯静态文案：不请求任何后端接口（R1），全部文案走 messages（zh-CN / en 同步）。
 * canonical/hreflang 与微信分享 meta 在 server wrapper（page.tsx）声明——"use client"
 * 文件无法导出 metadata（#239 契约）。
 *
 * 双语惯例：段头的「徽章（rose chip）+ 小标（letterspaced kicker）」在 zh 是中文名
 * + 英文名（如「为什么是现在 / Why Now」）；en 侧两个都成英文，故小标改写成不重复的
 * 定位语（"Why now / The moment"），避免同一行出现两遍同词。
 */
export default function HackerStart1024Page() {
	const t = useTranslations("hackerstart1024");

	return (
		<main className="hs24-root">
			<SiteHeader active="campaign" />

			<CampaignHero />
			<WhyNowSection />
			<JoinSection />
			<FaqSection />
			<VolunteerSection />
			<TimelineSection />
			<WhoWeAreSection />
			<BrandSection />

			{/* ⑨ 留存位：公众号关注 */}
			<section className="hs24-section" aria-label={t("follow.title")}>
				<div className="hs24-container">
					<div className="hs24-follow">
						<div className="hs24-follow__row">
							{/* 公众号二维码：素材已定稿（430px 源图，2x 显示 104px 框） */}
							<img
								className="hs24-follow__qr"
								src="/hackerstart-1024/cgc-wechat-qr-430.jpg"
								alt={t("follow.qr")}
								width={104}
								height={104}
							/>
							<div className="hs24-follow__copy">
								<div className="hs24-follow__t">{t("follow.title")}</div>
								<div className="hs24-follow__d">{t("follow.desc")}</div>
							</div>
						</div>
						<div className="hs24-follow__tag">{t("hashtag")}</div>
					</div>
				</div>
			</section>

			<footer className="hs24-footer">
				<div className="hs24-container hs24-footer__inner">
					<span>
						{t("footer.org")}
						<br />
						{/* 志愿者回链：页内锚点（F2 先读职位与流程，再由该段 CTA 进申请页） */}
						<a href="#hs24-volunteer">{t("footer.volunteer")}</a>
					</span>
					<b>{t("hashtag")}</b>
				</div>
			</footer>
		</main>
	);
}
