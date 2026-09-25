"use client";

import { useTranslations } from "next-intl";
import { BrandLockup } from "@/components/brand";
import { Link } from "@/i18n/navigation";

/**
 * 站点级页脚（全站唯一实现，与 SiteHeader 同源零跳变原则）。
 *
 * 视觉审计（2026-09）前：页脚只存在于首页（.ld-footer），公开目录/详情/法务页
 * 全部裸奔——法务链接（隐私/条款）与 ICP 备案从站内多数页面不可达。
 * 本组件补齐全站覆盖：首页改用本组件替换原最小页脚，
 * PublicCatalogShell / SitePage 统一挂载。
 *
 * 内容收敛（同日 user review）：页脚只放【顶导没有的东西】——
 * 品牌 + 法务链接（隐私政策/服务条款）+ 版权与 ICP 备案。
 * 站点导航（活动/课程/…）与语言切换已常驻顶导横排与窄屏抽屉，
 * 页脚不再重复承载。
 */
export default function SiteFooter() {
	const t = useTranslations("landing.footer");

	return (
		<footer aria-label={t("ariaLabel")} className="site-footer">
			<div className="site-footer__inner">
				<div className="site-footer__brandrow">
					<BrandLockup />
					<p className="site-footer__tagline">{t("tagline")}</p>
				</div>
				<div className="site-footer__meta">
					<nav aria-label={t("ariaLabel")} className="site-footer__links">
						<Link href="/privacy">{t("privacy")}</Link>
						<Link href="/terms">{t("terms")}</Link>
					</nav>
					<p>© CodingGirlsClub</p>
					<a
						href="https://beian.miit.gov.cn"
						target="_blank"
						rel="noopener noreferrer"
					>
						{t("icp")}
					</a>
				</div>
			</div>
		</footer>
	);
}
