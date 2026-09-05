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

// #251：真机经 LAN IP 访问 dev server 时，Next 16 默认 block 非 localhost origin 的
// /_next/* 资源与 HMR，整页 JS 失效（表单退化浏览器原生 GET 提交，密码明文进 URL）。
// WEB_DEV_ORIGINS 逗号分隔放行来源（如 `192.168.3.100,dev.local`）；仅 dev server 生效，
// 改动后必须重启 `pnpm dev`。Next 16.3 按请求 hostname 全等/通配匹配（不解析条目），
// 故此处统一剥掉 scheme 与端口归一为 hostname；未设置时为空数组，保持默认拦截。
const WEB_DEV_ORIGINS = (process.env.WEB_DEV_ORIGINS ?? "")
	.split(",")
	.map((entry) =>
		entry
			.trim()
			.replace(/^https?:\/\//, "")
			.replace(/\/+$/, "")
			.replace(/:\d+$/, ""),
	)
	.filter(Boolean);

const nextConfig: NextConfig = {
	// standalone：Docker 镜像只打包运行时产物（web/Dockerfile 依赖此模式）
	output: "standalone",
	allowedDevOrigins: WEB_DEV_ORIGINS,
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
