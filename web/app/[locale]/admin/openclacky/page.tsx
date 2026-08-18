"use client";

/**
 * /admin/openclacky OpenClacky 企业版入口（Phase 9 / R11）。
 * is_platform_admin 守卫由 /admin layout 的 AdminGuard 承担（本页无需重复）。
 * 重定向链接到 oc.codingirlsclub.com + 描述（独立服务器、独立认证）。
 */
import { useTranslations } from "next-intl";

export default function AdminOpenClackyPage() {
	const t = useTranslations("admin");
	return (
		<section>
			<div className="admin-page__head">
				<h1>OpenClacky</h1>
			</div>
			<div className="admin-card admin-card__body admin-card--narrow">
				<p className="admin-muted">
					{t("openclackyDesc")}
				</p>
				<p>
					<a
						href="https://oc.codingirlsclub.com"
						target="_blank"
						rel="noopener noreferrer"
						className="l-btn-primary"
					>
						{t("goOpenclacky")}
					</a>
				</p>
			</div>
		</section>
	);
}
