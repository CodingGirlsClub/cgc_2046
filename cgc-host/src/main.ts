// main.ts — 入口：`serve` 子命令常驻（各系统的登录自启项以它启动 Host，U7）；`uninstall` 子命令卸载（install.sh 结束时打印这条命令）
import { mkdirSync } from "node:fs";
import { homedir } from "node:os";
import { join } from "node:path";
import { type AgentRecord, createRegistry } from "./agents/registry";
import { ompLocator } from "./agents/omp";
import { spawnOmp } from "./acp/client";
import { createChat } from "./acp/session";
import { API_BASE, HOST_VERSION, PORT } from "./config";
import { runPlatformDialog } from "./platform-dialog";
import { startServer } from "./server";
import { WORKSPACE_DIR } from "./state";
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

const omp = ompLocator();
/** OMP 这条 agent 记录；加一种 agent 就是在注册表里加一条记录（KTD1） */
const ompRecord: AgentRecord = {
  kind: "omp",
  label: "OMP",
  locator: omp,
  async start(app, signal) {
    const found = await omp.locate();
    signal.throwIfAborted();
    if (!found.path) throw new Error("找不到 omp");
    const cwd = join(home, WORKSPACE_DIR); // agent 进程自己的目录（与终端插件同一处）；每个会话的 cwd 是各自课程的工作目录
    mkdirSync(cwd, { recursive: true });
    return spawnOmp({ ...found, path: found.path }, app, cwd, signal);
  },
};
const registry = createRegistry([ompRecord]);
const chat = createChat({ home, apiBase: API_BASE, registry });

try {
  startServer({
    port: PORT,
    home,
    apiBase: API_BASE,
    runDialog: runPlatformDialog,
    agents: registry.status,
    chat: chat.handle,
    onConnections: chat.connections,
  });
  console.log(`cgc-host ${HOST_VERSION} 在 127.0.0.1:${PORT} 上监听`);
  void omp.locate(); // 先解析一次登录 shell 环境；解析完成前这个 agent 的 present 为 false
} catch (e) {
  const errno = e as NodeJS.ErrnoException; // Bun.serve 端口被占时的错误形状（只读一个字段）
  if (errno.code !== "EADDRINUSE") throw e;
  // 端口被占即判定已有实例在跑。退出码 0：自启项的「异常才重启」不会反复拉起（launchd KeepAlive / systemd Restart=on-failure）
  console.error(`cgc-host: 127.0.0.1:${PORT} 已被占用，判定已有实例在运行，退出`);
  process.exit(0);
}
