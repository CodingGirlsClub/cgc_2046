import type { NextConfig } from "next";

const BACKEND_URL = process.env.BACKEND_URL ?? "http://localhost:4000";

const DEV_SCRIPT_SRC =
	process.env.NODE_ENV === "production"
		? "'self' 'unsafe-inline'"
		: "'self' 'unsafe-inline' 'unsafe-eval'";

const CONTENT_SECURITY_POLICY = [
	"default-src 'self'",
	`script-src ${DEV_SCRIPT_SRC}`,
	"style-src 'self' 'unsafe-inline'",
	"img-src 'self' data: https: http:",
	"font-src 'self' data:",
	"connect-src 'self'",
	"frame-ancestors 'none'",
	"base-uri 'self'",
	"form-action 'self'",
].join("; ");

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
					{ key: "Content-Security-Policy", value: CONTENT_SECURITY_POLICY },
					{ key: "X-Content-Type-Options", value: "nosniff" },
					{ key: "Referrer-Policy", value: "strict-origin-when-cross-origin" },
					{ key: "X-Frame-Options", value: "DENY" },
				],
			},
		];
	},
};

export default nextConfig;
