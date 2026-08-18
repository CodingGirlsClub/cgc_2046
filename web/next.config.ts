import createNextIntlPlugin from "next-intl/plugin";
import type { NextConfig } from "next";

const withNextIntl = createNextIntlPlugin("./i18n/request.ts");

const BACKEND_URL = process.env.BACKEND_URL ?? "http://localhost:4000";

const nextConfig: NextConfig = {
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
