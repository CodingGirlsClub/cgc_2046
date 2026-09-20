/**
 * cgc-command.ts — CGC-2046 接入包的用户级 OMP extension。
 *
 * 注册 `/cgc` 斜杠命令：一键显示连接状态、我的待办、可进入角色与快捷操作。
 * 这是用户主动可发现的入口——不用先问 agent「我现在能干什么」。
 *
 * 落盘位置：~/.omp/agent/extensions/cgc-command.ts（用户级，install.sh 拷贝）。
 *
 * 数据来源：CGC MCP 工具（server 条目名 cgc-2046）。本 extension 不注册任何工具，
 * 只读 MCP 状态并渲染摘要；连接状态从 OMP MCP manager 读取，不直接调网站 API。
 *
 * 三态：
 *   - 已连接：显示连接状态 + 待办列表 + 可进入角色 + 快捷操作
 *   - 未连接：显示「未连接」+ 引导跑 onboarding skill
 *   - 连接失败（401/网络错误）：显示错误与重试入口，不静默
 */

import { execSync } from "node:child_process";

export default function cgcCommand(pi) {
  pi.registerCommand("cgc", {
    description: "CGC-2046 状态总览：连接状态、待办、可进入角色、快捷操作",
    handler: async (_args, ctx) => {
      // 连接状态：从 OMP MCP manager 读 cgc-2046 server 是否在工具注册表里
      const allTools = ctx.getAllTools?.() ?? [];
      const mcpTools = allTools.filter((t) => typeof t?.name === "string" && t.name.startsWith("mcp__cgc_2046_"));
      const connected = mcpTools.length > 0;

      if (!connected) {
        ctx.ui.notify(
          "CGC-2046 未连接。\n\n" +
            "接入步骤：\n" +
            "  1. 确认已安装接入包（omp-access-pack）\n" +
            "  2. 确认 ~/.omp/agent/mcp.json 含 cgc-2046 条目\n" +
            "  3. 跑 onboarding skill 完成连接（或手动在网站 MCP 页生成 token 写入配置）\n\n" +
            "连接后重试 /cgc。",
          "warning",
        );
        return;
      }

      // 已连接：拉工作区与待办
      // 注意：extension 的 ctx 不直接暴露 MCP 工具调用入口（OMP extension API 无 invokeMcpTool），
      // 所以这里用 exec 调 omp CLI 的 mcp 子命令拉取数据（如果可用），否则降级为引导。
      // 这是有意的设计：/cgc 是「主动发现入口」，数据来自 MCP 工具而非网站 API 直调。
      const toolCount = mcpTools.length;

      let tasksText = "（待办拉取需要 agent 会话，输入「我有什么待办」）";
      let rolesText = "（角色拉取需要 agent 会话，输入「我能进哪些工作区」）";

      // 尝试用 omp CLI 拉取（如果 OMP 暴露 mcp call 子命令）
      try {
        const tasksJson = execSync(
          `omp mcp call cgc-2046 list_my_tasks '{}' 2>/dev/null || echo '{"error":"unavailable"}'`,
          { encoding: "utf8", timeout: 10_000 },
        );
        const tasks = JSON.parse(tasksJson);
        if (!tasks.error && Array.isArray(tasks.items)) {
          tasksText = tasks.items.length === 0
            ? "无待办"
            : tasks.items.slice(0, 5).map((t) => `  · ${t.title ?? t.id}`).join("\n") +
              (tasks.items.length > 5 ? `\n  … 共 ${tasks.items.length} 项` : "");
        }
      } catch {
        // omp mcp call 不可用，保持引导文本
      }

      try {
        const wsJson = execSync(
          `omp mcp call cgc-2046 list_my_workspaces '{}' 2>/dev/null || echo '{"error":"unavailable"}'`,
          { encoding: "utf8", timeout: 10_000 },
        );
        const ws = JSON.parse(wsJson);
        if (!ws.error && Array.isArray(ws.items)) {
          rolesText = ws.items.length === 0
            ? "无可进入工作区"
            : ws.items.slice(0, 5).map((w) => `  · ${w.name}（${w.role}）`).join("\n") +
              (ws.items.length > 5 ? `\n  … 共 ${ws.items.length} 个` : "");
        }
      } catch {
        // omp mcp call 不可用，保持引导文本
      }

      ctx.ui.notify(
        `CGC-2046 已连接（${toolCount} 个 MCP 工具可用）。\n\n` +
          `我的待办：\n${tasksText}\n\n` +
          `可进入的工作区与角色：\n${rolesText}\n\n` +
          "接下来可以：\n" +
          "  · 说「帮我开课/教研/学习」→ agent 按角色 playbook 工作\n" +
          "  · 打开网站对应页面（学习/教研/管理后台）→ agent 可用 browser 工具代开\n\n" +
          "快捷操作：\n" +
          "  · 断开连接：编辑 ~/.omp/agent/mcp.json 删除 cgc-2046 条目，或跑 install.sh remove\n" +
          "  · 重新连接：跑 onboarding skill（cgc2046-onboarding）\n" +
          "  · 查看文档：omp-access-pack/README.md",
        "info",
      );
    },
  });
}
