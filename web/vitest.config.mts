import { defineConfig } from "vitest/config";
import react from "@vitejs/plugin-react";

export default defineConfig({
  plugins: [react()],
  test: {
    // happy-dom 替代 jsdom：实例化快数倍，84 个测试文件的环境开销（vitest 分解
    // 中 environment 累计 55s、占 47%）是 CI test 58s 的近半；行为差异由全量回归兜底
    environment: "happy-dom",
    globals: true,
    setupFiles: ["./vitest.setup.ts"],
  },
  resolve: {
    alias: {
      "@": import.meta.dirname,
    },
  },
});
