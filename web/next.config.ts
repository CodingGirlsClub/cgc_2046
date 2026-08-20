import createNextIntlPlugin from "next-intl/plugin";
import type { NextConfig } from "next";

const withNextIntl = createNextIntlPlugin("./i18n/request.ts");

// #213 AC1：生产构建缺 BACKEND_URL 时显式失败，防静默把 API 指向 localhost（容器内自打 404）
const BACKEND_URL =
	process.env.BACKEND_URL ??
	(process.env.NODE_ENV === "production"
		? (() => {
				throw new Error(
					"BACKEND_URL must be set when building for production (rewrites destination)",
				);
			})()
		: "http://localhost:4000");

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
