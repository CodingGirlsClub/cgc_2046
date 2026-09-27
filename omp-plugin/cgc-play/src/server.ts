// server.ts — 本地 Unix socket 服务端（NDJSON 分帧）。
// socket 放在 ~/.cgc2046/ 下（目录 0700、socket 0600），只有本用户可连；一次只允许一个游戏进程。

import { chmodSync, existsSync, mkdirSync, unlinkSync } from "fs";
import { dirname, join } from "path";
import type { Session } from "./engine";
import { handleLine } from "./protocol";

// 与 omp-plugin/cgc-2046/extensions/cgc-play.ts 的 SOCKET_PATH 保持一致（两个包独立分发，无法共享模块）
export const defaultSocketPath = () => join(process.env.HOME ?? "", ".cgc2046", "play.sock");

async function isLive(path: string): Promise<boolean> {
  try {
    const s = await Bun.connect({ unix: path, socket: { data() {} } });
    s.end();
    return true;
  } catch {
    return false;
  }
}

export async function serve(session: Session, path = defaultSocketPath(), onHandled?: (line: string) => void) {
  mkdirSync(dirname(path), { recursive: true, mode: 0o700 });
  if (existsSync(path)) {
    if (await isLive(path)) throw new Error(`已有一个 cgc-play 在运行（${path}）`);
    unlinkSync(path); // 上次异常退出留下的死 socket
  }

  const clients = new Set<any>();
  const buffers = new WeakMap<object, string>();
  const send = (s: any, obj: unknown) => s.write(JSON.stringify(obj) + "\n");

  const server = Bun.listen({
    unix: path,
    socket: {
      open(s) {
        clients.add(s);
        buffers.set(s, "");
      },
      close(s) {
        clients.delete(s);
      },
      data(s, chunk) {
        const lines = (buffers.get(s) + chunk.toString()).split("\n");
        buffers.set(s, lines.pop() ?? "");
        for (const line of lines) {
          if (!line.trim()) continue;
          send(s, handleLine(session, line));
          onHandled?.(line);
        }
      },
    },
  });
  chmodSync(path, 0o600);

  session.onEvent((e) => {
    for (const c of clients) send(c, e);
  });

  return {
    clientCount: () => clients.size,
    stop() {
      server.stop(true);
      try {
        unlinkSync(path);
      } catch {}
    },
  };
}
