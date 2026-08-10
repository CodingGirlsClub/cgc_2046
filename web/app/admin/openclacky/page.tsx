"use client";

/**
 * /admin/openclacky OpenClacky 企业版入口（Phase 9 / R11）。
 * is_platform_admin 守卫由 /admin layout 的 AdminGuard 承担（本页无需重复）。
 * 重定向链接到 oc.codingirlsclub.com + 描述（独立服务器、独立认证）。
 */
export default function AdminOpenClackyPage() {
	return (
		<section className="max-w-2xl">
			<h1 className="text-2xl font-semibold mb-2">OpenClacky</h1>
			<p className="text-neutral-600 mb-4">
				OpenClacky 是 Coding Girls Club 的 AI 协作平台企业版，面向团队深度研究协作。
				它运行在独立服务器（oc.codingirlsclub.com），拥有独立的认证体系——
				本平台的账号权限与 OpenClacky 互不影响。
			</p>
			<a
				href="https://oc.codingirlsclub.com"
				target="_blank"
				rel="noopener noreferrer"
				className="inline-block px-4 py-2 rounded-md bg-neutral-900 text-white text-sm hover:bg-neutral-700"
			>
				前往 OpenClacky（oc.codingirlsclub.com）
			</a>
		</section>
	);
}
