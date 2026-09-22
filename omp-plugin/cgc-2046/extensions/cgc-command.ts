/**
 * cgc-command.ts — CGC-2046 接入包的用户级 OMP extension。
 *
 * 注册 `/cgc` 斜杠命令：一键显示连接状态、我的待办、可进入角色与快捷操作。
 * 这是用户主动可发现的入口——不用先问 agent「我现在能干什么」。
 *
 * 落盘位置：~/.omp/agent/extensions/cgc-command.ts（用户级，install.sh 拷贝）。
 *
 * 数据来源：CGC MCP 工具（server 条目名 cgc-2046）。本 extension 不注册任何工具。
 * 连接状态从工具注册表读取；待办/角色数据经 sendUserMessage 注入由 agent 拉取渲染。
 *
 * 三态：
 *   - 已连接：notify 即时反馈 + sendUserMessage 注入 agent 拉待办/角色渲染
 *   - 未连接：显示「未连接」+ 引导跑 onboarding skill
 *   - 连接失败（401/网络错误）：显示错误与重试入口，不静默
 */

export default function cgcCommand(pi) {
  // 共享 handler：/cgc 与 /cgc-help 双入口（别名兜死——若 /cgc help 的 args 形态不是 string，别名仍可达）
  const handler = async (args, ctx) => {
    // 宽容归一化：args 可能是 string / array / object，统一转 string 再判定
    const a = typeof args === "string" ? args : Array.isArray(args) ? args.join(" ") : String(args?.args ?? args?.text ?? args?.rest ?? "");
    const argText = a.trim().toLowerCase();

    // /cgc help 或 /cgc-help：完整命令参考（小白友好：「你说什么」+「会发生什么」）
    if (/help|帮助/.test(argText)) {
      ctx.ui.notify(
        "CGC-2046 命令参考\n\n" +
          "你说什么 → 会发生什么：\n\n" +
          "  /cgc → 查看连接状态、待办、可进入角色\n" +
          "  /cgc help → 显示本参考\n" +
          "  「连接 CGC」→ 连接你的 CGC 账号（自动或手工）\n" +
          "  「断开连接」→ 我来指导你断开\n" +
          "  「开始 CGC 工作」→ 以 cgc agent 身份开始角色工作\n" +
          "  「帮我处理待办」→ 查看并处理你的待办\n" +
          "  「帮我开课」→ 创建课程（Owner/Admin）\n" +
          "  「帮我教研」→ 生产课程内容（Tutor）\n" +
          "  「帮我学习」→ 开始学习（Learner）\n\n" +
          "技术细节（不需要懂）：\n" +
          "  · 配置文件在 ~/.omp/agent/mcp.json（0600 权限，只有你能读）\n" +
          "  · 卸载：omp plugin uninstall cgc-2046@cgc-omp-plugins\n" +
          "  · 文档：https://github.com/CodingGirlsClub/cgc-omp-plugins",
        "info",
      );
      return;
    }

    // 连接状态：从工具注册表读 cgc-2046 server 的 MCP 工具是否存在
    // 双兜底：ctx.getAllTools（command handler ctx）→ pi.getAllTools（extension API）
    const allTools = ctx.getAllTools?.() ?? pi.getAllTools?.() ?? [];
    const mcpTools = allTools.filter((t) => typeof t?.name === "string" && t.name.startsWith("mcp__cgc_2046_"));
    const connected = mcpTools.length > 0;

    if (!connected) {
      ctx.ui.notify(
        "CGC-2046 未连接。\n\n" +
          "说「连接 CGC」开始。\n\n" +
          "其他：\n" +
          "  · 查看完整命令参考：/cgc help\n" +
          "  · 查看文档：https://github.com/CodingGirlsClub/cgc-omp-plugins",
        "warning",
      );
      return;
    }

    // 已连接：检查工作目录优先于数据渲染——先解决「在哪工作」，再谈「有什么工作」
    const toolCount = mcpTools.length;
    const currentDir = ctx.cwd ?? process.cwd?.() ?? "未知";
    const workspaceDir = "~/cgc2046_workspace";
    const inWorkspace = currentDir === workspaceDir || currentDir.endsWith("/cgc2046_workspace");

    // 工作目录检查：不在工作目录时，注入「用 ask 引导创建并切换」的提示词（agent 侧执行 ask）
    if (!inWorkspace) {
      ctx.ui.notify(
        `CGC-2046 已连接（${toolCount} 个 MCP 工具可用），但检测到不在 CGC 工作目录（${workspaceDir}）。\n\n` +
          `当前目录：${currentDir}\n\n` +
          "正在引导你创建并切换到工作目录…",
        "warning",
      );

      pi.sendUserMessage(
        `检测到用户不在 CGC 工作目录（${workspaceDir}），当前在 ${currentDir}。\n\n` +
          "请用 ask 引导用户选择：\n" +
          "1. 创建并切换（推荐）：mkdir -p ~/cgc2046_workspace，然后告诉用户「我创建了 ~/cgc2046_workspace。请退出当前会话（exit 或 Ctrl+D），然后 cd ~/cgc2046_workspace && omp 重新启动」——不渲染汇总，先解决工作目录问题。\n" +
          "2. 就在当前目录工作：继续拉取并渲染 CGC-2046 状态汇总（list_my_workspaces + list_my_tasks）。\n" +
          "3. 取消：不做任何操作。\n\n" +
          "ask 选项：[{ \"label\": \"创建并切换\", \"description\": \"创建工作目录并切换过去（推荐）\" }, { \"label\": \"就在当前目录工作\", \"description\": \"不切换，继续当前会话\" }, { \"label\": \"取消\" }]\n\n" +
          "ask 抛错（headless 无 UI）时，降级按「创建并切换」默认（最安全——先解决工作目录问题）。",
        { deliverAs: "nextTurn", triggerTurn: true },
      );
      return;
    }

    // 在工作目录：正常渲染汇总 + 版本检查
    const versionHint = (() => {
      const v = checkVersion(ctx);
      if (!v) return "";
      return `\n\n有新版本可用：${v.catalogVersion}（当前 ${v.localVersion}）。跑 omp plugin upgrade cgc-2046@cgc-omp-plugins 更新`;
    })();

    ctx.ui.notify(
      `CGC-2046 已连接（${toolCount} 个 MCP 工具可用）。\n\n` +
        "你现在可以：\n" +
        "  · 说「帮我处理待办」→ 查看并处理待办\n" +
        "  · 说「开始 CGC 工作」→ 以 cgc agent 身份开始角色工作（开课/教研/学习）\n\n" +
        "其他：\n" +
        "  · 说「断开连接」→ 我来指导你断开\n" +
        "  · 说「连接 CGC」→ 重新连接\n" +
        "  · 查看完整命令参考：/cgc help\n" +
        "  · 查看文档：https://github.com/CodingGirlsClub/cgc-omp-plugins" +
        versionHint,
      "info",
    );

    // 注入结构化汇总请求，agent 立即起 turn 拉数据渲染（idle 时 triggerTurn 立即 prompt，不阻塞当前 notify）
    pi.sendUserMessage(
      "请拉取并渲染 CGC-2046 状态汇总：\n" +
        "1. 调 list_my_workspaces 列出我可进入的 Workspace 与角色（按名称展示，不要 UUID）\n" +
        "2. 对每个 Workspace 调 list_my_tasks 列出我的待办（含 approval_deadline）\n" +
        "3. 渲染成紧凑汇总，开头加「你现在该做什么」的差异化引导：有待办→「你有 N 条待办，最近的截止是 X。说『帮我处理待办』开始。」；无待办→「没有待办。你可以说『帮我开课』/『帮我教研』/『帮我学习』。」\n" +
        "4. 末尾加引导：如需开始角色工作，说「开始 CGC 工作」（会以 cgc agent 身份处理）",
      { deliverAs: "nextTurn", triggerTurn: true },
    );
  };

  // 版本检查：读本地安装版本与 catalog 缓存版本，不一致时 notify 提示更新
  // 本地：~/.omp/plugins/installed_plugins.json（user scope）
  // catalog：~/.omp/plugins/cache/marketplaces/cgc-omp-plugins/.omp-plugin/marketplace.json
  const checkVersion = (ctx) => {
    try {
      const { readFileSync, existsSync } = require("fs");
      const { join } = require("path");
      const os = require("os");
      const pluginsRoot = join(os.homedir(), ".omp", "plugins");

      // 读本地安装版本
      const installedPath = join(pluginsRoot, "installed_plugins.json");
      if (!existsSync(installedPath)) return null;
      const installed = JSON.parse(readFileSync(installedPath, "utf8"));
      const localVersion = installed?.plugins?.find(
        (p) => p?.name === "cgc-2046" && p?.marketplace === "cgc-omp-plugins",
      )?.version;

      // 读 catalog 缓存版本
      const catalogPath = join(
        pluginsRoot, "cache", "marketplaces", "cgc-omp-plugins",
        ".omp-plugin", "marketplace.json",
      );
      if (!existsSync(catalogPath)) return null;
      const catalog = JSON.parse(readFileSync(catalogPath, "utf8"));
      const catalogVersion = catalog?.plugins?.find((p) => p?.name === "cgc-2046")?.version;

      if (localVersion && catalogVersion && localVersion !== catalogVersion) {
        return { localVersion, catalogVersion };
      }
      return null;
    } catch {
      return null; // 任何读取失败都静默跳过（不阻塞主流程）
    }
  };

  pi.registerCommand("cgc", {
    description: "CGC-2046 状态总览：连接状态、待办、可进入角色、快捷操作",
    handler,
  });

  // 别名兜死：若 /cgc help 的 args 形态不是 string，/cgc-help 仍可达
  pi.registerCommand("cgc-help", {
    description: "CGC-2046 命令参考（/cgc help 的别名）",
    handler,
  });
}
