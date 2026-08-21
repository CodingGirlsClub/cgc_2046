import createNextIntlPlugin from "next-intl/plugin";
import type { NextConfig } from "next";

const withNextIntl = createNextIntlPlugin("./i18n/request.ts");

// #213 AC1：生产构建缺 BACKEND_URL 时显式失败，防静默把 API 指向 localhost（容器内自打 404）
// 必须挡空串而非只挡 undefined：空 build-arg 会让 destination 退化成相对路径
// 自引用（/api/graphql → /api/graphql），生产 404——2026-08-21 实证
const rawBackendUrl = process.env.BACKEND_URL?.trim();
if (process.env.NODE_ENV === "production" && !rawBackendUrl) {
	throw new Error(
		"BACKEND_URL must be set and non-empty when building for production (rewrites destination)",
	);
}
const BACKEND_URL = rawBackendUrl || "http://localhost:4000";

const nextConfig: NextConfig = {
	// standalone：Docker 镜像只打包运行时产物（web/Dockerfile 依赖此模式）
	output: "standalone",
	async rewrites() {
		const rules = [
			{
				source: "/api/graphql",
				destination: `${BACKEND_URL}/api/graphql`,
			},
		];
		if (process.env.NODE_ENV !== "production") {
			rules.push({
				source: "/api/playground",
				destination: `${BACKEND_URL}/api/playground`,
			});
		}
		return rules;
	},
	async headers() {
		return [
			{
				source: "/:path*",
				headers: [
					{ key: "X-Content-Type-Options", value: "nosniff" },
					{ key: "Referrer-Policy", value: "strict-origin-when-cross-origin" },
					{ key: "X-Frame-Options", value: "DENY" },
				],
			},
		];
	},
};

export default withNextIntl(nextConfig);
