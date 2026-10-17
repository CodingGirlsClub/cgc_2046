// main.ts — 入口：`serve` 子命令常驻（各系统的登录自启项以它启动 Host，U7）；`uninstall` 子命令卸载（install.sh 结束时打印这条命令）
import { homedir } from "node:os";
import { builtinAgents } from "./agents/builtin";
import { installCodexAcp } from "./agents/install";
import { createRegistry } from "./agents/registry";
import { findReuseCodexEngine } from "./agents/sources";
import { createChat } from "./acp/session";
import { API_BASE, HOST_VERSION, PORT } from "./config";
import { runPlatformDialog } from "./platform-dialog";
import { startServer } from "./server";
import { uninstall } from "./uninstall";

const home = homedir();

if (process.argv[2] === "uninstall") {
  await uninstall(home, API_BASE);
  process.exit(0);
}
if (process.argv[2] !== "serve") {
  console.error("用法：cgc-host serve | cgc-host uninstall");
  process.exit(2);
}

const agents = builtinAgents(home);
const registry = createRegistry(agents);
const chat = createChat({ home, apiBase: API_BASE, registry });

try {
  startServer({
    port: PORT,
    home,
    apiBase: API_BASE,
    runDialog: runPlatformDialog,
    agents: registry.status,
    capabilities: ["agent.install"],
    installable: ["codex"],
    install: async (kind, progress) => {
      if (kind !== "codex") throw new Error(`没有 ${kind} 的安装包`);
      // 有可复用的 Codex engine（ChatGPT App 内置 / PATH codex）就先试 reuse：只装约 2MB 适配器；
      // 探针失败时 installCodexAcp 内部回退 full，这里不用再判断。
      const reuse = await findReuseCodexEngine(home);
      return installCodexAcp({ home, onPhase: progress, reuseEngine: reuse?.path });
    },
    refresh: (kind) => registry.refresh(kind),
    chat: chat.handle,
    onConnections: chat.connections,
  });
  console.log(`cgc-host ${HOST_VERSION} 在 127.0.0.1:${PORT} 上监听`);
  for (const record of agents) void record.locator.locate(); // 先解析一次，present 在解析完成前为 false
} catch (e) {
  const errno = e as NodeJS.ErrnoException; // Bun.serve 端口被占时的错误形状（只读一个字段）
  if (errno.code !== "EADDRINUSE") throw e;
  // 端口被占即判定已有实例在跑。退出码 0：自启项的「异常才重启」不会反复拉起（launchd KeepAlive / systemd Restart=on-failure）
  console.error(`cgc-host: 127.0.0.1:${PORT} 已被占用，判定已有实例在运行，退出`);
  process.exit(0);
}
