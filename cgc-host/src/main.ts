// main.ts — 入口：`serve` 子命令常驻（LaunchAgent 以它启动 Host，U7）
import { homedir } from "node:os";
import { API_BASE, HOST_VERSION, PORT } from "./config";
import { runOsascript } from "./pairing";
import { startServer } from "./server";

if (process.argv[2] !== "serve") {
  console.error("用法：cgc-host serve");
  process.exit(2);
}

try {
  startServer({
    port: PORT,
    home: homedir(),
    apiBase: API_BASE,
    runDialog: runOsascript,
    ompPresent: () => false, // U6 接上 omp 的解析
    // U6 接上 ACP 之前，对话方法一律答「暂不可用」
    chat: (_method, _params, ctx) => ctx.send({ method: "error", id: ctx.id, params: { code: "chat_unavailable" } }),
  });
  console.log(`cgc-host ${HOST_VERSION} 在 127.0.0.1:${PORT} 上监听`);
} catch (e) {
  if ((e as { code?: string }).code !== "EADDRINUSE") throw e;
  // 端口被占即判定已有实例在跑。退出码 0：LaunchAgent 的 KeepAlive（SuccessfulExit:false）不会反复拉起
  console.error(`cgc-host: 127.0.0.1:${PORT} 已被占用，判定已有实例在运行，退出`);
  process.exit(0);
}
