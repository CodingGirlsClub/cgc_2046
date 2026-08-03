/**
 * 登录态确认 hook（#70 hydration-safe，#7 提到根 layout 共享）。
 *
 * 真实实现移至 auth-provider.tsx 的 AuthProvider（根 layout 单例 me 查询）。
 * 此文件保留导出以维持现有 `import { useAuthed } from "@/lib/use-authed"` 路径不变。
 * 新代码应直接从 auth-provider 导入。
 */
export { useAuthed, type AuthedState } from "./auth-provider";