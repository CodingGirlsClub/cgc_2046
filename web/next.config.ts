import type { NextConfig } from "next";

const BACKEND_URL = process.env.BACKEND_URL ?? "http://localhost:4000";

const nextConfig: NextConfig = {
  async rewrites() {
    return [
      {
        source: "/api/graphql",
        destination: `${BACKEND_URL}/api/graphql`,
      },
      {
        source: "/api/playground",
        destination: `${BACKEND_URL}/api/playground`,
      },
    ];
  },
};

export default nextConfig;
