// main.ts — 入口：`serve` 子命令常驻（LaunchAgent 以它启动 Host，U7）；`uninstall` 子命令卸载（install.sh 结束时打印这条命令）
import { mkdirSync } from "node:fs";
import { homedir } from "node:os";
import { join } from "node:path";
import { spawnOmp } from "./acp/client";
import { createChat } from "./acp/session";
import { API_BASE, HOST_VERSION, PORT } from "./config";
import { ompLocator } from "./omp";
import { runOsascript } from "./pairing";
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

const omp = ompLocator();
const chat = createChat({
  home,
  apiBase: API_BASE,
  async start(app) {
    const found = await omp.locate();
    if (!found.path) throw new Error("找不到 omp");
    const cwd = join(home, "CGC"); // OMP 进程自己的目录；每个会话的 cwd 是各自课程的工作目录
    mkdirSync(cwd, { recursive: true });
    return spawnOmp({ ...found, path: found.path }, app, cwd);
  },
});

try {
  startServer({
    port: PORT,
    home,
    apiBase: API_BASE,
    runDialog: runOsascript,
    ompPresent: omp.present,
    ompEnvError: omp.envError,
    chat: chat.handle,
    onConnections: chat.connections,
  });
  console.log(`cgc-host ${HOST_VERSION} 在 127.0.0.1:${PORT} 上监听`);
  void omp.locate(); // 先解析一次登录 shell 环境；解析完成前 ompPresent 为 false
} catch (e) {
  if ((e as { code?: string }).code !== "EADDRINUSE") throw e;
  // 端口被占即判定已有实例在跑。退出码 0：LaunchAgent 的 KeepAlive（SuccessfulExit:false）不会反复拉起
  console.error(`cgc-host: 127.0.0.1:${PORT} 已被占用，判定已有实例在运行，退出`);
  process.exit(0);
}
