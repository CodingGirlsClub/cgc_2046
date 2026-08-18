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
    // next-intl client navigation 以裸说明符 import "next/navigation"；
    // inline 让 vite 接管其解析，配合下方 resolve.alias 指向项目内 next 入口
    server: { deps: { inline: ["next-intl"] } },
  },
  resolve: {
    alias: {
      "@": import.meta.dirname,
      // next-intl client navigation 以裸说明符 import "next/navigation"，
      // vitest 无 Next 编译上下文时解析失败 → 固定映射到项目 next 的绝对入口
      "next/navigation": new URL("./node_modules/next/navigation.js", import.meta.url)
        .pathname,
    },
  },
});
