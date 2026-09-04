import type { ReactNode } from "react";
import SiteHeader from "@/components/site-header";

/**
 * 站点级页面壳：统一 SiteHeader + 语义 main 锚点。
 *
 * 站点内不再复用 PublicCatalogShell 的内容页（法务 / 订单 / 参与 / 审批 /
 * 加入流程等）套此壳获得同一品牌导航，布局宽度由页面内容自持。
 */
export default function SitePage({ children }: { children: ReactNode }) {
	return (
		<div className="site-page">
			<SiteHeader />
			<main id="main-content" className="site-page__main">
				{children}
			</main>
		</div>
	);
}
